package com.mdobak.phonelink

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.concurrent.Executors
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.system.exitProcess

/**
 * Screen mirroring over adb with no consent prompt. Runs via app_process as the shell user, which may mirror
 * the display. Serves one client on the local socket "phonelink-screen", then exits.
 * Frames: 4-byte big-endian length, then a type byte: 1 = JSON, 2 = video (flags, pts, H.264 Annex B),
 * 3 = PCM 48 kHz stereo 16-bit.
 * Input is injected as the shell user, so control works on the lock screen and with the screen off.
 */
object ShellServer {
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var resize = false
    private lateinit var out: DataOutputStream

    @JvmStatic
    fun main(args: Array<String>) {
        val maxSize = args.getOrNull(0)?.toIntOrNull() ?: 1920
        val bitrate = args.getOrNull(1)?.toIntOrNull() ?: 8_000_000
        val fps = args.getOrNull(2)?.toIntOrNull() ?: 60
        val sound = args.getOrNull(3) == "1"
        // Args: app=<package> (one app on its own display), socket=<name>, off=1 (phone screen off).
        val opts = args.drop(4).mapNotNull { a -> a.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }.toMap()
        appPackage = opts["app"]
        Shell.guardThreads()
        try { Looper.prepareMainLooper() } catch (_: Exception) {}
        // Turn the panel back on when the process ends. No reply: the Mac is gone, and a write can block the exit.
        Runtime.getRuntime().addShutdownHook(Thread { if (screenOff) setScreenPower(true, notify = false) })
        val server = try { LocalServerSocket(opts["socket"] ?: "phonelink-screen") } catch (e: Exception) {
            System.err.println("socket: $e"); exitProcess(2)
        }
        println("ready")
        System.out.flush()
        val timeout = thread(isDaemon = true) { try { Thread.sleep(15_000); exitProcess(3) } catch (_: InterruptedException) {} }
        val client: LocalSocket = server.accept()
        timeout.interrupt()
        // Free the socket name now so a new helper can bind it (see ShellAgent).
        try { server.close() } catch (_: Exception) {}
        out = DataOutputStream(BufferedOutputStream(client.outputStream, 1 shl 16))
        thread(isDaemon = true, name = "control") { control(DataInputStream(BufferedInputStream(client.inputStream))) }
        if (appPackage != null) {
            // Android turns off app displays while the phone sleeps. Keep the phone awake while the window is open.
            keepAwake()
            wakeForApp()
        } else {
            thread(isDaemon = true, name = "rotation") { watchSize() }
            // An off display mirrors as black. Wake it so the lock screen shows.
            wake()
            if (opts["off"] == "1") thread(isDaemon = true) { Thread.sleep(800); setScreenPower(false) }
        }
        if (sound) setAudio(true)
        // The power button sleeps the phone despite the wake lock. In app mode or with the panel off, wake it again
        // (the panel stays dark) so the video keeps running. The phone stays locked.
        thread(isDaemon = true, name = "awake") {
            while (true) {
                Thread.sleep(1000)
                try { if (appPackage != null || screenOff) wakeForApp() } catch (_: Throwable) {}
            }
        }
        try {
            while (true) encodeOnce(maxSize, bitrate, fps)
        } catch (e: Exception) {
            System.err.println("stream ended: $e")
        }
        exitProcess(0)
    }

    private fun control(input: DataInputStream) {
        try {
            while (true) {
                val n = input.readInt()
                if (n !in 0..65536) break
                val b = ByteArray(n).also { input.readFully(it) }
                val m = JSONObject(String(b))
                when (m.optString("t")) {
                    "keyframe" -> requestKeyFrame()
                    "stop" -> break
                    "audio" -> setAudio(m.optBoolean("on"))
                    "display.power" -> setScreenPower(m.optBoolean("on"))
                    "resize" -> if (appPackage != null) { appDp = m.optInt("w") to m.optInt("h"); resize = true }
                    "app.launch" -> {
                        val pkg = m.optString("pkg")
                        val fresh = m.optBoolean("fresh")
                        val id = appVirtualDisplay?.display?.displayId
                        if (id != null && pkg.matches(Regex("[A-Za-z0-9_.]+"))) inputs.execute { wakeForApp(); launchOn(id, pkg, fresh) }
                    }
                    else -> inputs.execute {
                        try {
                            // Wake the app display only on gesture start. Checking on every move adds latency.
                            val t = m.optString("t")
                            val start = t != "input.scroll" && (t != "input.touch" || m.optString("action") == "down")
                            if (appPackage != null && start) wakeForApp()
                            input(m)
                        } catch (e: Exception) { System.err.println("input: " + e) }
                    }
                }
            }
        } catch (_: Exception) {}
        exitProcess(0)
    }

    // The encoder can stop at any time (e.g. on rotation). Then this has no effect.
    private fun requestKeyFrame() {
        try {
            codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: IllegalStateException) {
            System.err.println("keyframe: encoder not running")
        }
    }

    @Volatile private var audioOn = false
    private var audioThread: Thread? = null

    // The phone speaker is silent while this runs. Needs Android 12+.
    @Synchronized private fun setAudio(on: Boolean) {
        audioOn = on
        if (on && audioThread == null) audioThread = thread(isDaemon = true, name = "audio") { captureAudio() }
    }

    private fun captureAudio() {
        try {
            // ActivityThread (in Shell.context) needs a Looper on this thread.
            if (Looper.myLooper() == null) Looper.prepare()
            val rec = audioRecord()
            try {
                rec.startRecording()
                val buf = ByteArray(48_000 * 4 / 50) // 20 ms
                while (audioOn) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n > 0) send(3, buf, 0, n) else if (n < 0) error("read error $n")
                }
                rec.stop()
            } finally {
                rec.release()
            }
        } catch (e: Throwable) {
            System.err.println("audio: $e " + (e.cause ?: ""))
            audioOn = false
            try { send(1, JSONObject().put("t", "screen.audio.unavailable").toString().toByteArray()) } catch (_: Exception) {}
        } finally {
            synchronized(this) {
                audioThread = null
                // The Mac turned sound back on while this thread was stopping.
                if (audioOn) setAudio(true)
            }
        }
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun audioRecord(): AudioRecord {
        if (Build.VERSION.SDK_INT < 31) error("Android 12 or later is necessary")
        val fmt = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(48_000)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()
        val min = AudioRecord.getMinBufferSize(48_000, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioRecord.Builder().setContext(Shell.context).setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
            .setAudioFormat(fmt).setBufferSizeInBytes(max(min * 4, 48_000 * 4 / 5)).build()
    }

    private val inputs = Executors.newSingleThreadExecutor()

    private val injector: (InputEvent) -> Unit by lazy {
        // Android 14 moved injectInputEvent to InputManagerGlobal.
        val (obj, cls) = try {
            val c = Class.forName("android.hardware.input.InputManagerGlobal")
            c.getMethod("getInstance").invoke(null)!! to c
        } catch (_: Exception) {
            val c = Class.forName("android.hardware.input.InputManager")
            c.getDeclaredMethod("getInstance").invoke(null)!! to c
        }
        val m = cls.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType)
        // Target the phone display, not the mirror.
        val setDisplay = try { InputEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType) } catch (_: Exception) { null }
        val f: (InputEvent) -> Unit = { e ->
            try { setDisplay?.invoke(e, targetDisplay) } catch (_: Exception) {}
            if (m.invoke(obj, e, 0) != true) System.err.println("inject failed: " + e)
        }
        f
    }

    private fun key(code: Int, meta: Int = 0, longPress: Boolean = false) {
        val t = SystemClock.uptimeMillis()
        injector(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
        if (longPress) {
            Thread.sleep(700)
            injector(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_DOWN, code, 1, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_LONG_PRESS, InputDevice.SOURCE_KEYBOARD))
        }
        injector(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD))
    }

    private fun touch(down: Long, action: Int, x: Float, y: Float) {
        val p = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
        val c = MotionEvent.PointerCoords().apply { this.x = x; this.y = y; pressure = 1f; size = 1f }
        val e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, arrayOf(p), arrayOf(c), 0, 0, 1f, 1f, 0, 0,
            InputDevice.SOURCE_TOUCHSCREEN, 0)
        injector(e)
        e.recycle()
    }

    // points: [[x, y, ms], ...] with x and y in 0..1.
    private fun gesture(points: JSONArray) {
        if (points.length() == 0) return
        val (w, h) = displaySize()
        fun pt(i: Int): Triple<Float, Float, Long> = points.getJSONArray(i).let {
            Triple((it.getDouble(0) * w).toFloat().coerceIn(0f, w - 1f), (it.getDouble(1) * h).toFloat().coerceIn(0f, h - 1f), it.optLong(2))
        }
        val first = pt(0)
        val down = SystemClock.uptimeMillis()
        touch(down, MotionEvent.ACTION_DOWN, first.first, first.second)
        var last = first
        for (i in 1 until points.length()) {
            val p = pt(i)
            val wait = (p.third - last.third).coerceIn(0, 2_000)
            if (wait > 0) Thread.sleep(wait)
            touch(down, MotionEvent.ACTION_MOVE, p.first, p.second)
            last = p
        }
        touch(down, MotionEvent.ACTION_UP, last.first, last.second)
    }

    // Live touches. Input thread only.
    private var liveDown = 0L
    private var liveSize = 0 to 0
    private var liveX = 0f
    private var liveY = 0f

    private fun liveTouch(action: String, nx: Double, ny: Double) {
        if (action == "down") {
            if (liveDown != 0L) touch(liveDown, MotionEvent.ACTION_CANCEL, liveX, liveY)
            liveSize = displaySize()
            liveDown = SystemClock.uptimeMillis()
        }
        if (liveDown == 0L) return
        val (w, h) = liveSize
        liveX = (nx * w).toFloat().coerceIn(0f, w - 1f)
        liveY = (ny * h).toFloat().coerceIn(0f, h - 1f)
        when (action) {
            "down" -> touch(liveDown, MotionEvent.ACTION_DOWN, liveX, liveY)
            "move" -> touch(liveDown, MotionEvent.ACTION_MOVE, liveX, liveY)
            "up" -> { touch(liveDown, MotionEvent.ACTION_UP, liveX, liveY); liveDown = 0L }
            else -> { touch(liveDown, MotionEvent.ACTION_CANCEL, liveX, liveY); liveDown = 0L }
        }
    }

    private fun targetDpi(): Int {
        if (appPackage != null) try {
            val m = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") appVirtualDisplay?.display?.getRealMetrics(m)
            if (m.densityDpi > 0) return m.densityDpi
        } catch (_: Exception) {}
        return mainDpi
    }

    private val mainDpi: Int by lazy { physicalDensity() }

    // With lines, dx/dy are wheel steps, else screen fractions. Positive dy moves content down, as on the Mac.
    private fun scroll(nx: Double, ny: Double, dx: Double, dy: Double, lines: Boolean) {
        val (w, h) = displaySize()
        // Android scrolls about 64 dp for each scroll unit.
        val unit = targetDpi() * 64 / 160.0
        val v = if (lines) dy else dy * h / unit
        val hs = -(if (lines) dx else dx * w / unit)
        val p = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
        val c = MotionEvent.PointerCoords().apply {
            x = (nx * w).toFloat().coerceIn(0f, w - 1f)
            y = (ny * h).toFloat().coerceIn(0f, h - 1f)
            setAxisValue(MotionEvent.AXIS_VSCROLL, v.toFloat())
            setAxisValue(MotionEvent.AXIS_HSCROLL, hs.toFloat())
        }
        val t = SystemClock.uptimeMillis()
        val e = MotionEvent.obtain(t, t, MotionEvent.ACTION_SCROLL, 1, arrayOf(p), arrayOf(c), 0, 0, 1f, 1f, 0, 0,
            InputDevice.SOURCE_MOUSE, 0)
        injector(e)
        e.recycle()
    }

    private fun wake() = shell("input", "keyevent", "KEYCODE_WAKEUP")

    private val power: Any? by lazy { try { Shell.asInterface("android.os.IPowerManager", Shell.service("power")) } catch (_: Exception) { null } }

    // App mode: wake the phone so the app display draws. The panel stays dark.
    @Synchronized private fun wakeForApp() {
        if (interactive() != false) return
        wake()
        Thread.sleep(300)
        setScreenPower(false)
    }

    private var wakeLock: android.os.IBinder? = null

    @Synchronized private fun keepAwake() {
        if (wakeLock != null) return
        try {
            val token = android.os.Binder()
            // SCREEN_DIM_WAKE_LOCK
            Shell.call(power!!, "acquireWakeLock", token, 0x6, "PhoneLink:screen", Shell.PACKAGE)
            wakeLock = token
        } catch (e: Throwable) { System.err.println("wake lock: $e") }
    }

    @Synchronized private fun releaseAwake() {
        val token = wakeLock ?: return
        wakeLock = null
        try { Shell.call(power!!, "releaseWakeLock", token, 0) } catch (e: Throwable) { System.err.println("wake lock: $e") }
    }

    private fun interactive(): Boolean? = try { power?.let { Shell.call(it, "isInteractive") as Boolean } } catch (_: Exception) { null }

    private fun shell(vararg cmd: String) { try { Runtime.getRuntime().exec(cmd).waitFor() } catch (_: Exception) {} }

    private fun input(m: JSONObject) {
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        when (m.optString("t")) {
            "input.gesture" -> gesture(m.getJSONArray("points"))
            "input.touch" -> liveTouch(m.optString("action"), m.optDouble("x", 0.0), m.optDouble("y", 0.0))
            "input.scroll" -> scroll(m.optDouble("x", 0.0), m.optDouble("y", 0.0), m.optDouble("dx", 0.0), m.optDouble("dy", 0.0), m.optBoolean("lines"))
            "input.wake" -> wake()
            "input.global" -> if (appPackage != null && !desktop) { if (m.optString("action") == "back") key(KeyEvent.KEYCODE_BACK) } else when (m.optString("action")) {
                "back" -> key(KeyEvent.KEYCODE_BACK)
                "home" -> key(KeyEvent.KEYCODE_HOME)
                "recents" -> key(KeyEvent.KEYCODE_APP_SWITCH)
                "notifications" -> shell("cmd", "statusbar", "expand-notifications")
                "quick_settings" -> shell("cmd", "statusbar", "expand-settings")
                "lock" -> key(KeyEvent.KEYCODE_SLEEP)
                "power" -> key(KeyEvent.KEYCODE_POWER, longPress = true)
                "screenshot" -> key(KeyEvent.KEYCODE_SYSRQ)
            }
            "input.key" -> when (m.optString("key")) {
                "escape" -> key(KeyEvent.KEYCODE_BACK)
                "backspace" -> key(KeyEvent.KEYCODE_DEL)
                "delete" -> key(KeyEvent.KEYCODE_FORWARD_DEL)
                "enter" -> key(KeyEvent.KEYCODE_ENTER)
                "left" -> key(KeyEvent.KEYCODE_DPAD_LEFT)
                "right" -> key(KeyEvent.KEYCODE_DPAD_RIGHT)
                "up" -> key(KeyEvent.KEYCODE_DPAD_UP)
                "down" -> key(KeyEvent.KEYCODE_DPAD_DOWN)
                "select_all" -> key(KeyEvent.KEYCODE_A, ctrl)
                "copy" -> key(KeyEvent.KEYCODE_C, ctrl)
                "paste" -> key(KeyEvent.KEYCODE_V, ctrl)
                "cut" -> key(KeyEvent.KEYCODE_X, ctrl)
            }
            "input.text" -> text(m.optString("text"))
        }
    }

    // Characters missing from the virtual key map go back to the Mac, which types them via accessibility.
    private fun text(s: String) {
        val map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
        val rest = StringBuilder()
        for (ch in s) {
            val events = map.getEvents(charArrayOf(ch))
            if (events == null) { rest.append(ch); continue }
            if (rest.isNotEmpty()) { fallback(rest.toString()); rest.clear() }
            for (e in events) injector(e)
        }
        if (rest.isNotEmpty()) fallback(rest.toString())
    }

    private fun fallback(s: String) =
        send(1, JSONObject().put("t", "input.fallback").put("text", s).toString().toByteArray())

    private fun displaySize(): Pair<Int, Int> = appDisplaySize ?: defaultDisplaySize()

    private fun watchSize() {
        var last = displaySize()
        var locked: Boolean? = null
        while (true) {
            Thread.sleep(300)
            try {
                val l = secureLocked()
                if (l != null && l != locked) {
                    locked = l
                    send(1, JSONObject().put("t", "screen.locked").put("locked", l).toString().toByteArray())
                }
                val now = displaySize()
                if (now != last) { last = now; resize = true }
            } catch (e: Throwable) { System.err.println("rotation: " + e.javaClass.name) }
        }
    }

    private val wm: Any? by lazy {
        try { Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null) } catch (_: Exception) { null }
    }

    // Android hides the lock screen keypad from mirror displays, so the Mac asks for the PIN. Null if unknown.
    private fun secureLocked(): Boolean? = try {
        val w = wm!!
        val locked = w.javaClass.getMethod("isKeyguardLocked").invoke(w) as Boolean
        locked && (w.javaClass.getMethod("isKeyguardSecure", Int::class.javaPrimitiveType).invoke(w, 0) as Boolean)
    } catch (_: Exception) { null }

    private fun send(type: Int, body: ByteArray, off: Int = 0, len: Int = body.size, header: ByteArray? = null) = synchronized(out) {
        val h = header?.size ?: 0
        out.writeInt(1 + h + len)
        out.write(type)
        if (header != null) out.write(header)
        out.write(body, off, len)
        out.flush()
    }

    private fun encodeOnce(maxSize: Int, bitrate: Int, fps: Int) {
        resize = false
        fun even8(v: Double) = max(8, (v / 8).roundToInt() * 8)
        val w: Int
        val h: Int
        var dpi = 0
        if (appPackage != null) {
            // App display: 1 Mac point = 1 dp. Large windows get a lower density so the video fits maxSize.
            val density = physicalDensity()
            val (dpW, dpH) = appDp ?: defaultDisplaySize().let { (pw, ph) -> (pw * 160 / density) to (ph * 160 / density) }
            val pw = dpW * density / 160.0
            val ph = dpH * density / 160.0
            val scale = minOf(1.0, maxSize.toDouble() / max(pw, ph))
            w = even8(pw * scale)
            h = even8(ph * scale)
            dpi = max(80, (density * scale).roundToInt())
            appDisplaySize = w to h
        } else {
            val (dw, dh) = displaySize()
            val scale = minOf(1.0, maxSize.toDouble() / max(dw, dh))
            w = even8(dw * scale)
            h = even8(dh * scale)
        }
        val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 10)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 1)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh)
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        var surface: Surface? = null
        var display: Mirror? = null
        try {
            c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val input = c.createInputSurface().also { surface = it }
            display = if (appPackage != null) appDisplay(w, h, dpi, input) else createMirror(w, h, input)
            codec = c
            c.start()
            val state = JSONObject().put("t", "screen.state").put("state", "streaming").put("width", w).put("height", h)
            // The width of the phone screen in dp, for the window scale on the Mac.
            if (appPackage == null) state.put("dpWidth", displaySize().first * 160 / physicalDensity())
            send(1, state.toString().toByteArray())
            val info = MediaCodec.BufferInfo()
            var buf = ByteArray(256 * 1024)
            val header = ByteArray(9)
            while (!resize) {
                val i = c.dequeueOutputBuffer(info, 100_000)
                if (i < 0) continue
                if (info.size > 0) {
                    val ob = c.getOutputBuffer(i)!!
                    if (buf.size < info.size) buf = ByteArray(info.size * 2)
                    ob.position(info.offset)
                    ob.get(buf, 0, info.size)
                    var flags = 0
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or 1
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or 2
                    header[0] = flags.toByte()
                    var p = info.presentationTimeUs
                    for (k in 8 downTo 1) { header[k] = (p and 0xff).toByte(); p = p shr 8 }
                    send(2, buf, 0, info.size, header)
                }
                c.releaseOutputBuffer(i, false)
            }
        } finally {
            codec = null
            try { display?.release() } catch (e: Exception) { System.err.println("display release: $e") }
            try { c.stop() } catch (_: Exception) {}
            c.release()
            surface?.release()
        }
    }

    @Volatile private var appPackage: String? = null
    // The phone desktop: a display with its own home screen instead of one app.
    private val desktop get() = appPackage == "@desktop"
    @Volatile private var appDp: Pair<Int, Int>? = null
    @Volatile private var appDisplaySize: Pair<Int, Int>? = null
    @Volatile private var targetDisplay = 0
    @Volatile private var appVirtualDisplay: android.hardware.display.VirtualDisplay? = null

    private fun defaultDisplayInfo(): Any {
        val g = Class.forName("android.hardware.display.DisplayManagerGlobal").getMethod("getInstance").invoke(null)!!
        return g.javaClass.getMethod("getDisplayInfo", Int::class.javaPrimitiveType).invoke(g, 0)!!
    }

    private fun defaultDisplaySize(): Pair<Int, Int> {
        val info = defaultDisplayInfo()
        return info.javaClass.getField("logicalWidth").getInt(info) to info.javaClass.getField("logicalHeight").getInt(info)
    }

    private fun physicalDensity(): Int = try {
        val info = defaultDisplayInfo()
        info.javaClass.getField("logicalDensityDpi").getInt(info)
    } catch (_: Exception) { 420 }

    // Survives video size changes. When it closes, Android closes the app's activities on it.
    private fun appDisplay(w: Int, h: Int, dpi: Int, surface: Surface): Mirror {
        appVirtualDisplay?.let { vd ->
            vd.resize(w, h, dpi)
            vd.surface = surface
            return detach(vd)
        }
        // public, presentation, own content, touch, rotates. Not destroy-content: on close the app returns to the phone screen.
        var flags = (1 shl 0) or (1 shl 1) or (1 shl 3) or (1 shl 6) or (1 shl 7)
        // Desktop: system decorations so Android shows a launcher here.
        if (desktop) flags = flags or (1 shl 9)
        if (Build.VERSION.SDK_INT >= 33) flags = flags or (1 shl 10) or (1 shl 11) or (1 shl 12) or (1 shl 13) // trusted, own group, always unlocked, no touch feedback
        if (Build.VERSION.SDK_INT >= 34) flags = flags or (1 shl 14) // own focus. Not the device display group, or the display turns off with the phone screen.
        val ctor = android.hardware.display.DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
        val dm = ctor.newInstance(Shell.context)
        val vd = dm.createVirtualDisplay("Phone Link", w, h, dpi, surface, flags)
        appVirtualDisplay = vd
        val id = vd.display.displayId
        targetDisplay = id
        // The Mac keyboard types into the app, so hide the phone keyboard here.
        try {
            val w = wm!!
            w.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(w, id, 2)
        } catch (e: Throwable) { System.err.println("ime policy: $e") }
        if (desktop) {
            thread(isDaemon = true) {
                Thread.sleep(1500)
                val home = secondaryHome()
                if (home != null) shell("am", "start", "--display", id.toString(), "-n", home)
            }
            sendDisplayId(id)
            return detach(vd)
        }
        val pkg = appPackage!!
        // Send the display id after the app starts (am start -W waits), so intents from the Mac open on top of it.
        thread(isDaemon = true) { launchOn(id, pkg); sendDisplayId(id) }
        return detach(vd)
    }

    // Releasing only detaches the encoder surface. The app display stays for the next encoder.
    private fun detach(vd: android.hardware.display.VirtualDisplay) = object : Mirror { override fun release() { vd.surface = null } }

    private fun sendDisplayId(id: Int) {
        try { send(1, JSONObject().put("t", "display.id").put("id", id).toString().toByteArray()) } catch (_: Exception) {}
    }

    // Use the activity name: a package-only start does not resolve on a virtual display.
    // fresh: show the start screen of the app. The first start moves a task of the app to this display.
    // Clearing the task works only after that: in the same start, Android hides the moved task.
    private fun launchOn(id: Int, pkg: String, fresh: Boolean = false) {
        val component = launchComponent(pkg)
        if (component != null) {
            shell("am", "start", "--display", id.toString(), "-W", "-n", component)
            if (fresh) shell("am", "start", "--display", id.toString(), "-W", "--activity-clear-task", "-n", component)
        } else shell("monkey", "--display", id.toString(), "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1")
    }

    // Skip System UI activities: they are for foldable cover screens.
    private fun secondaryHome(): String? = try {
        fun query(vararg a: String): List<String> {
            val p = Runtime.getRuntime().exec(arrayOf("cmd", "package", *a))
            val l = p.inputStream.bufferedReader().readLines().map { it.trim() }.filter { it.contains('/') && !it.contains(' ') }
            p.waitFor()
            return l
        }
        val main = query("resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME").lastOrNull()?.substringBefore('/')
        val all = query("query-activities", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.SECONDARY_HOME")
            .filter { !it.startsWith("com.android.systemui/") }
        all.firstOrNull { it.substringBefore('/') == main } ?: all.firstOrNull()
    } catch (_: Exception) { null }

    private fun launchComponent(pkg: String): String? {
        try {
            Shell.context.packageManager.getLaunchIntentForPackage(pkg)?.component?.let { return it.flattenToShortString() }
        } catch (e: Throwable) { System.err.println("launch intent: $e") }
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN",
                "-c", "android.intent.category.LAUNCHER", pkg))
            val last = p.inputStream.bufferedReader().readLines().lastOrNull()?.trim()
            p.waitFor()
            last?.takeIf { it.contains('/') }
        } catch (_: Exception) { null }
    }

    @Volatile private var screenOff = false

    // Looked up once: services.jar can load its native library only once.
    private val panelTokens: List<android.os.IBinder> by lazy {
        val sc = Class.forName("android.view.SurfaceControl")
        try {
            listOf(sc.getMethod("getInternalDisplayToken").invoke(null) as android.os.IBinder)
        } catch (_: Exception) {
            // Android 14 and later: DisplayControl in services.jar.
            val loader = dalvik.system.PathClassLoader("/system/framework/services.jar", ClassLoader.getSystemClassLoader())
            val dc = loader.loadClass("com.android.server.display.DisplayControl")
            Runtime::class.java.getDeclaredMethod("loadLibrary0", Class::class.java, String::class.java)
                .apply { isAccessible = true }.invoke(Runtime.getRuntime(), dc, "android_servers")
            val ids = dc.getMethod("getPhysicalDisplayIds").invoke(null) as LongArray
            ids.toList().mapNotNull { dc.getMethod("getPhysicalDisplayToken", Long::class.javaPrimitiveType).invoke(null, it) as android.os.IBinder? }
        }
    }

    // The mirror keeps showing the content. With notify, replies screen.power or screen.power.unavailable.
    @Synchronized private fun setScreenPower(on: Boolean, notify: Boolean = true) {
        try {
            val sc = Class.forName("android.view.SurfaceControl")
            val tokens = panelTokens
            val set = sc.getMethod("setDisplayPowerMode", android.os.IBinder::class.java, Int::class.javaPrimitiveType)
            if (!on) keepAwake()
            for (t in tokens) set.invoke(null, t, if (on) 2 else 0)
            screenOff = !on
            if (on && appPackage == null) releaseAwake()
        } catch (e: Throwable) {
            System.err.println("screen power: $e " + (e.cause ?: ""))
            if (notify) send(1, JSONObject().put("t", "screen.power.unavailable").toString().toByteArray())
            return
        }
        if (notify) send(1, JSONObject().put("t", "screen.power").put("on", on).toString().toByteArray())
    }

    private interface Mirror { fun release() }

    // Uses the hidden DisplayManager method, or SurfaceControl on old versions.
    private fun createMirror(w: Int, h: Int, surface: Surface): Mirror {
        try {
            val m = Class.forName("android.hardware.display.DisplayManager").getMethod(
                "createVirtualDisplay", String::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType, Surface::class.java,
            )
            val vd = m.invoke(null, "phonelink", w, h, 0, surface) as android.hardware.display.VirtualDisplay
            return object : Mirror { override fun release() = vd.release() }
        } catch (e: Exception) {
            System.err.println("DisplayManager mirror failed, using SurfaceControl: $e " + (e.cause ?: ""))
        }
        val sc = Class.forName("android.view.SurfaceControl")
        val token = sc.getMethod("createDisplay", String::class.java, Boolean::class.javaPrimitiveType).invoke(null, "phonelink", false)!!
        val (dw, dh) = displaySize()
        val ib = android.os.IBinder::class.java
        sc.getMethod("openTransaction").invoke(null)
        try {
            sc.getMethod("setDisplaySurface", ib, Surface::class.java).invoke(null, token, surface)
            sc.getMethod("setDisplayProjection", ib, Int::class.javaPrimitiveType, android.graphics.Rect::class.java, android.graphics.Rect::class.java)
                .invoke(null, token, 0, android.graphics.Rect(0, 0, dw, dh), android.graphics.Rect(0, 0, w, h))
            sc.getMethod("setDisplayLayerStack", ib, Int::class.javaPrimitiveType).invoke(null, token, 0)
        } finally {
            sc.getMethod("closeTransaction").invoke(null)
        }
        return object : Mirror { override fun release() { sc.getMethod("destroyDisplay", ib).invoke(null, token) } }
    }
}
