package com.mdobak.phonelink

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Looper
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import kotlin.concurrent.thread
import kotlin.system.exitProcess

/**
 * Call audio helper, started by the Mac as the shell user:
 * CLASSPATH=/data/local/tmp/phonelink.apk app_process / com.mdobak.phonelink.ShellCallAudio [socket]
 * Serves one Mac on the local socket "phonelink-call" (via adb forward), then exits.
 *
 * Uses the AudioManager call audio interception system API: a downlink record for the remote side and an
 * uplink track into the call. Both work only in MODE_IN_CALL or MODE_IN_COMMUNICATION.
 *
 * Frames as in ShellServer: 4-byte big-endian length, type byte, body.
 * Type 1 is UTF-8 JSON. Type 3 is PCM 16 kHz mono s16le, 320 samples (20 ms) per frame.
 * - To Mac: hello {sdk, interceptable}; call.state {active, ringing, mode, voip, audio, muteMic, micMuted, error?}
 *   on each change; call.stats every 5 s while audio is on; downlink frames while "audio" is true.
 * - From Mac: call.audio {on, muteMic}, call.state, ping, stop, and uplink frames.
 * Audio stops when the call ends. The Mac must send call.audio again for the next call.
 *
 * Privacy: never store audio. Logcat (tag PhoneLinkCall) gets only counts and levels.
 */
object ShellCallAudio {
    private const val TAG = "PhoneLinkCall"
    private const val RATE = 16_000
    private const val FRAME = 320 // 20 ms at 16 kHz
    // The Mac sends mic audio in ~100 ms bursts, so the queue must hold a full burst.
    private const val MAX_QUEUE = 15
    // Drop a frame if the queue stays above this for 1 s, to keep latency low.
    private const val TARGET_MIN = 3
    // Frames to buffer after an underrun before playing again.
    private const val PRIME = 4

    private lateinit var am: AudioManager
    private var tm: TelephonyManager? = null
    private var out: DataOutputStream? = null
    private val outLock = Object()
    private val ctl = Object()

    // Guarded by ctl.
    private var connected = false
    private var wanted = false
    private var muteMic = false
    private var audioOn = false
    private var error: String? = null
    private var mutedByUs = false
    private var oldMute = false
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var session = 0
    private var lastState = ""

    private val queue = ArrayDeque<ShortArray>()

    @Volatile private var downFrames = 0
    @Volatile private var upFrames = 0
    @Volatile private var upDropped = 0
    @Volatile private var upUnderruns = 0
    @Volatile private var downSq = 0.0
    @Volatile private var upSq = 0.0

    @JvmStatic
    fun main(args: Array<String>) {
        Shell.guardThreads()
        try { Looper.prepareMainLooper() } catch (_: Exception) {}
        Shell.context // First use needs the Looper of this thread.
        am = Shell.context.getSystemService(AudioManager::class.java)
        tm = try { Shell.context.getSystemService(TelephonyManager::class.java) } catch (_: Throwable) { null }
        val server = try { LocalServerSocket(args.firstOrNull() ?: "phonelink-call") } catch (e: Exception) {
            System.err.println("socket: $e"); exitProcess(2)
        }
        // Restore the mic mute state if the process dies.
        Runtime.getRuntime().addShutdownHook(Thread { synchronized(ctl) { audioOn = false; applyMute() } })
        println("ready")
        System.out.flush()
        Log.i(TAG, "ready, interceptable=" + interceptable())
        // Exit if no Mac connects soon, so no helper is left behind.
        val idle = thread(isDaemon = true) { try { Thread.sleep(20_000); exitProcess(3) } catch (_: InterruptedException) {} }
        thread(isDaemon = true, name = "call-watch") { watch() }
        val client: LocalSocket = server.accept()
        idle.interrupt()
        // Free the socket name now so a new helper can bind it (see ShellAgent).
        try { server.close() } catch (_: Exception) {}
        val o = DataOutputStream(BufferedOutputStream(client.outputStream, 1 shl 14))
        synchronized(outLock) { out = o }
        synchronized(ctl) { connected = true }
        sendJson(JSONObject().put("t", "hello").put("sdk", android.os.Build.VERSION.SDK_INT).put("interceptable", interceptable()))
        synchronized(ctl) { sendState(force = true) }
        try {
            val input = DataInputStream(BufferedInputStream(client.inputStream, 1 shl 14))
            while (true) {
                val n = input.readInt()
                if (n !in 1..(1 shl 20)) break
                val type = input.readUnsignedByte()
                val body = ByteArray(n - 1).also { input.readFully(it) }
                when (type) {
                    1 -> if (!handle(JSONObject(String(body)))) break
                    3 -> pushUplink(body)
                }
            }
        } catch (_: Exception) {}
        Log.i(TAG, "mac disconnected")
        synchronized(ctl) { connected = false; wanted = false; update() }
        try { client.close() } catch (_: Exception) {}
        System.exit(0)
    }

    private fun handle(m: JSONObject): Boolean {
        when (m.optString("t")) {
            "stop" -> return false
            "ping" -> sendJson(JSONObject().put("t", "pong"))
            "call.state" -> synchronized(ctl) { sendState(force = true) }
            "call.dtmf" -> {
                // Inject DTMF tones only while audio is on.
                val digits = m.optString("digits").filter { it in KEYS }
                if (audioOn && digits.isNotEmpty()) synchronized(tones) { digits.forEach { tones.addLast(it) } }
            }
            "call.audio" -> synchronized(ctl) {
                val on = m.optBoolean("on")
                muteMic = m.optBoolean("muteMic", false)
                error = null
                if (on && !inCall()) {
                    wanted = false
                    error = "No call is active."
                } else {
                    wanted = on
                }
                update()
                sendState(force = true)
            }
        }
        return true
    }

    private fun interceptable(): Boolean = try {
        AudioManager::class.java.getMethod("isPstnCallAudioInterceptable").invoke(am) as Boolean
    } catch (_: Throwable) { false }

    private var telephonyFailed = false

    private fun telephonyState(): Int {
        if (telephonyFailed) return -1
        return try { tm?.callState ?: -1 } catch (_: Throwable) { telephonyFailed = true; -1 }
    }

    private fun inCall(): Boolean = mobileCall() || internetCall()

    private fun mobileCall(): Boolean {
        val tel = telephonyState()
        val mode = am.mode
        return if (tel >= 0) tel == TelephonyManager.CALL_STATE_OFFHOOK
        else mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION
    }

    private var commSince = 0L

    // Internet call (Meet, WhatsApp): MODE_IN_COMMUNICATION with no mobile call, held for 1.5 s
    // because some apps set it only briefly.
    private fun internetCall(): Boolean {
        if (telephonyState() < 0) return false // mobileCall() falls back to the mode.
        val comm = am.mode == AudioManager.MODE_IN_COMMUNICATION && telephonyState() == TelephonyManager.CALL_STATE_IDLE
        val now = System.currentTimeMillis()
        if (!comm) { commSince = 0L; return false }
        if (commSince == 0L) commSince = now
        return now - commSince >= 1_500
    }

    private fun audioMode(): Boolean = am.mode.let { it == AudioManager.MODE_IN_CALL || it == AudioManager.MODE_IN_COMMUNICATION }

    private var retryAt = 0L
    private var attempts = 0

    private fun watch() {
        while (true) {
            try { synchronized(ctl) { update(); sendState() } } catch (e: Throwable) { Log.w(TAG, "watch: " + e.javaClass.simpleName) }
            Thread.sleep(200)
        }
    }

    // Syncs audio with the call state and the Mac request. Caller holds ctl.
    private fun update() {
        val active = inCall()
        if (!active && wanted) { wanted = false; attempts = 0; Log.i(TAG, "call ended, audio stops") }
        if (wanted && active && connected && !audioOn && audioMode() && System.currentTimeMillis() >= retryAt) startAudio()
        if (audioOn && (!wanted || !active || !connected)) stopAudio()
        applyMute()
    }

    private fun sendState(force: Boolean = false) {
        val mode = am.mode
        val tel = telephonyState()
        val j = JSONObject().put("t", "call.state")
            .put("active", inCall())
            .put("ringing", mode == AudioManager.MODE_RINGTONE || tel == TelephonyManager.CALL_STATE_RINGING)
            .put("mode", mode)
            .put("telephony", tel)
            .put("voip", !mobileCall() && internetCall())
            .put("audio", audioOn)
            .put("muteMic", muteMic)
            .put("micMuted", try { am.isMicrophoneMute } catch (_: Throwable) { false })
        error?.let { j.put("error", it) }
        val s = j.toString()
        if (!force && s == lastState) return
        lastState = s
        Log.i(TAG, "state $s")
        sendJson(j)
    }

    private fun applyMute() {
        try {
            if (audioOn && muteMic && !mutedByUs) {
                oldMute = am.isMicrophoneMute
                am.setMicrophoneMute(true)
                mutedByUs = true
                Log.i(TAG, "phone mic muted (was " + oldMute + ", now " + am.isMicrophoneMute + ")")
            } else if (mutedByUs && (!audioOn || !muteMic)) {
                am.setMicrophoneMute(oldMute)
                mutedByUs = false
                Log.i(TAG, "phone mic mute restored to $oldMute")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "mic mute: " + e.javaClass.simpleName + ": " + e.message)
        }
    }

    private fun format(mask: Int) =
        AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(RATE).setChannelMask(mask).build()

    private fun system(name: String, f: AudioFormat): Any? = try {
        AudioManager::class.java.getMethod(name, AudioFormat::class.java).invoke(am, f)
    } catch (e: Throwable) {
        val c = (e as? java.lang.reflect.InvocationTargetException)?.targetException ?: e
        throw IllegalStateException(c.message ?: c.javaClass.simpleName)
    }

    // Caller holds ctl.
    private fun startAudio() {
        try {
            val r = system("getCallDownlinkExtractionAudioRecord", format(AudioFormat.CHANNEL_IN_MONO)) as AudioRecord
            if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); error("The call audio is not available.") }
            val t = try {
                system("getCallUplinkInjectionAudioTrack", format(AudioFormat.CHANNEL_OUT_MONO)) as AudioTrack
            } catch (e: Throwable) { r.release(); throw e }
            // Small buffer for low latency. Android may allocate more.
            val asked = FRAME * 3
            val got = try { t.setBufferSizeInFrames(asked) } catch (_: Throwable) { -1 }
            Log.i(TAG, "uplink track buffer: asked $asked, got $got, capacity " + (try { t.bufferCapacityInFrames } catch (_: Throwable) { -1 }))
            record = r
            track = t
            synchronized(queue) { queue.clear() }
            downFrames = 0; upFrames = 0; upDropped = 0; upUnderruns = 0; downSq = 0.0; upSq = 0.0
            audioOn = true
            error = null
            session++
            val s = session
            thread(isDaemon = true, name = "call-down") { downlink(r, s) }
            thread(isDaemon = true, name = "call-up") { uplink(t, s) }
            thread(isDaemon = true, name = "call-stats") { stats(s) }
            attempts = 0
            Log.i(TAG, "audio started")
        } catch (e: Throwable) {
            audioOn = false
            // The mode can change while the call starts. Retry for about 10 s.
            attempts++
            if (attempts >= 20) { wanted = false; attempts = 0 } else retryAt = System.currentTimeMillis() + 500
            error = "The phone did not give the call audio: " + (e.message ?: e.javaClass.simpleName)
            Log.w(TAG, "audio start failed: " + e.javaClass.simpleName + ": " + e.message)
        }
    }

    // Caller holds ctl.
    private fun stopAudio() {
        synchronized(tones) { tones.clear() }
        toneKey = -1
        audioOn = false
        session++
        record?.let { r -> try { r.stop() } catch (_: Throwable) {}; try { r.release() } catch (_: Throwable) {} }
        track?.let { t -> try { t.pause(); t.flush() } catch (_: Throwable) {}; try { t.release() } catch (_: Throwable) {} }
        record = null
        track = null
        synchronized(queue) { queue.clear() }
        Log.i(TAG, "audio stopped: down $downFrames frames, up $upFrames frames, dropped $upDropped, underruns $upUnderruns")
    }

    private fun live(s: Int) = audioOn && session == s

    @Volatile private var downQuiet = 0

    private fun downlink(r: AudioRecord, s: Int) {
        try {
            r.startRecording()
            val buf = ShortArray(FRAME)
            val bytes = ByteArray(FRAME * 2)
            while (live(s)) {
                var n = 0
                while (n < FRAME) {
                    val k = r.read(buf, n, FRAME - n)
                    if (k <= 0) { if (!live(s)) return; Thread.sleep(5); continue }
                    n += k
                }
                var sq = 0.0
                for (i in 0 until FRAME) {
                    val v = buf[i].toInt()
                    sq += (v * v).toDouble()
                    bytes[2 * i] = v.toByte()
                    bytes[2 * i + 1] = (v shr 8).toByte()
                }
                downSq += sq / FRAME
                if (sq / FRAME < 400.0) downQuiet++
                downFrames++
                send(3, bytes)
            }
        } catch (e: Throwable) {
            if (live(s)) Log.w(TAG, "downlink: " + e.javaClass.simpleName)
        }
    }

    private fun pushUplink(body: ByteArray) {
        if (!audioOn) return
        val n = body.size / 2
        if (n == 0) return
        val f = ShortArray(n) { i -> ((body[2 * i].toInt() and 0xff) or (body[2 * i + 1].toInt() shl 8)).toShort() }
        synchronized(queue) {
            queue.addLast(f)
            while (queue.size > MAX_QUEUE) { queue.removeFirst(); upDropped++ }
        }
    }

    private const val KEYS = "123456789*0#ABCD"
    private val LOW = intArrayOf(697, 697, 697, 770, 770, 770, 852, 852, 852, 941, 941, 941, 697, 770, 852, 941)
    private val HIGH = intArrayOf(1209, 1336, 1477, 1209, 1336, 1477, 1209, 1336, 1477, 1209, 1336, 1477, 1633, 1633, 1633, 1633)
    // 160 ms tone, then 80 ms silence.
    private const val TONE_FRAMES = 8
    private const val GAP_FRAMES = 4
    private val tones = ArrayDeque<Char>()
    private var toneKey = -1
    private var toneFrame = 0

    private fun nextToneFrame(): ShortArray? {
        if (toneKey < 0) {
            val c = synchronized(tones) { tones.removeFirstOrNull() } ?: return null
            toneKey = KEYS.indexOf(c)
            toneFrame = 0
            if (toneKey < 0) return null
        }
        val out = ShortArray(FRAME)
        if (toneFrame < TONE_FRAMES) {
            val lo = 2 * Math.PI * LOW[toneKey] / RATE
            val hi = 2 * Math.PI * HIGH[toneKey] / RATE
            for (i in 0 until FRAME) {
                val n = toneFrame * FRAME + i
                out[i] = ((Math.sin(lo * n) * 0.3 + Math.sin(hi * n) * 0.35) * 32767).toInt().toShort()
            }
        }
        if (++toneFrame >= TONE_FRAMES + GAP_FRAMES) toneKey = -1
        return out
    }

    private var windowMin = Int.MAX_VALUE
    private var windowCount = 0
    @Volatile private var upTrimmed = 0

    // The blocking track write is the clock. Write silence when no Mac audio is queued so latency does not grow.
    private fun uplink(t: AudioTrack, s: Int) {
        try {
            t.play()
            val silence = ShortArray(FRAME)
            var priming = true
            while (live(s)) {
                // A tone frame replaces a mic frame so latency does not grow.
                val tone = nextToneFrame()
                if (tone != null) {
                    synchronized(queue) { queue.removeFirstOrNull() }
                    t.write(tone, 0, tone.size)
                    continue
                }
                val f = synchronized(queue) {
                    if (priming && queue.size < PRIME) null
                    else {
                        if (queue.size < windowMin) windowMin = queue.size
                        if (++windowCount >= 50) {
                            if (windowMin > TARGET_MIN && queue.size > TARGET_MIN) { queue.removeFirst(); upTrimmed++ }
                            windowCount = 0; windowMin = Int.MAX_VALUE
                        }
                        queue.removeFirstOrNull().also { priming = it == null }
                    }
                }
                if (f == null) {
                    upUnderruns++
                    t.write(silence, 0, silence.size)
                } else {
                    var sq = 0.0
                    for (v in f) sq += (v * v).toDouble()
                    upSq += sq / f.size
                    upFrames++
                    val t0 = System.nanoTime()
                    t.write(f, 0, f.size)
                    val ms = (System.nanoTime() - t0) / 1_000_000
                    if (ms > writeMsMax) writeMsMax = ms
                }
            }
        } catch (e: Throwable) {
            if (live(s)) Log.w(TAG, "uplink: " + e.javaClass.simpleName)
        }
    }

    private var lastHead = 0
    @Volatile private var writeMsMax = 0L

    // Counts and RMS levels only, never audio.
    private fun stats(s: Int) {
        lastHead = 0
        var lastDown = 0
        var lastUp = 0
        while (true) {
            try { Thread.sleep(5000) } catch (_: InterruptedException) { return }
            if (!live(s)) return
            val d = downFrames - lastDown
            val u = upFrames - lastUp
            lastDown = downFrames
            lastUp = upFrames
            val downRms = if (d > 0) Math.sqrt(downSq / d).toInt() else 0
            val upRms = if (u > 0) Math.sqrt(upSq / u).toInt() else 0
            downSq = 0.0
            upSq = 0.0
            val q = synchronized(queue) { queue.size }
            val tr = track
            val head = try { tr?.playbackHeadPosition ?: 0 } catch (_: Throwable) { 0 }
            val headDelta = head - lastHead
            lastHead = head
            val dev = try { tr?.routedDevice } catch (_: Throwable) { null }
            val j = JSONObject().put("t", "call.stats").put("downFrames", d).put("upFrames", u)
                .put("downRms", downRms).put("upRms", upRms).put("upDropped", upDropped).put("upTrimmed", upTrimmed).put("downQuiet", downQuiet.also { downQuiet = 0 }).put("upUnderruns", upUnderruns)
                .put("upQueueMs", q * 20).put("micMuted", try { am.isMicrophoneMute } catch (_: Throwable) { false })
                .put("trackPlayed", headDelta).put("trackRate", tr?.sampleRate ?: 0).put("trackPlaybackRate", try { tr?.playbackRate ?: 0 } catch (_: Throwable) { 0 })
                .put("devType", dev?.type ?: -1).put("devRates", dev?.sampleRates?.joinToString(",") ?: "")
                .put("writeMsMax", writeMsMax)
            writeMsMax = 0
            Log.i(TAG, "stats $j")
            sendJson(j)
        }
    }

    private fun sendJson(j: JSONObject) = send(1, j.toString().toByteArray())

    private fun send(type: Int, body: ByteArray) = synchronized(outLock) {
        val o = out ?: return
        try {
            o.writeInt(1 + body.size)
            o.write(type)
            o.write(body)
            o.flush()
        } catch (_: Exception) {}
    }
}
