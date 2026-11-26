package com.mdobak.phonelink

import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private const val TAG = "PhoneLink"
private const val MAX_FRAME = 16 shl 20
const val MSG_JSON: Byte = 1
const val MSG_VIDEO: Byte = 2
const val MSG_AUDIO: Byte = 4
/** Mac to phone: the Mac screen for Remote Desktop: [flags][pts µs u64 BE][H.264 Annex B]. Flags as VIDEO_*. */
const val MSG_RD_VIDEO: Byte = 5
/** Both directions: terminal data: [tab id u32 BE][bytes]. Mac to phone is output, phone to Mac is input. */
const val MSG_TERM: Byte = 6
const val VIDEO_CONFIG = 1
const val VIDEO_KEY = 2

/**
 * One connection from a Mac. Wire format: 4-byte big-endian length + body.
 * The hello and confirm frames are plain JSON. After them, each body is AES-GCM sealed and
 * its plain text starts with a type byte: MSG_JSON, MSG_VIDEO (flags, pts, H.264 Annex B),
 * MSG_FILE (Transfers.kt), MSG_AUDIO (PCM), MSG_RD_VIDEO or MSG_TERM.
 */
class Session(private val svc: LinkService, private val link: Link) {
    private val watched = WatchedInput(link.input)
    private val input = DataInputStream(BufferedInputStream(watched, 1 shl 16))
    private val output = DataOutputStream(BufferedOutputStream(link.output, 1 shl 16))
    private lateinit var tx: FrameCipher
    private lateinit var rx: FrameCipher

    /** counter: the queued byte count that this frame adds to. */
    private class Out(val data: ByteArray, val counter: AtomicLong? = null)
    private val queue = LinkedBlockingQueue<Out>()
    private val queuedVideo = AtomicLong()
    private val queuedFile = AtomicLong()
    private val queuedAudio = AtomicLong()
    private val fileLock = Object()
    @Volatile private var waitForKey = false
    private val closing = AtomicBoolean(false)
    @Volatile var closed = false
        private set

    var macName = ""
        private set
    var macId = ""
        private set
    /** The Mac is on the hotspot of this phone. */
    val viaHotspot: Boolean get() = link.localAddress?.let { Hotspot.isTethered(svc, it) } ?: false
    val kind: LinkKind get() = link.kind
    private val io = Executors.newSingleThreadExecutor()
    private val sentIcons = HashSet<String>()

    fun run() {
        try {
            thread(name = "phonelink-watch") { watch() }
            handshake()
            // The Mac pings every 10 s. 45 s with no data means the connection is dead.
            watched.limitMs = 45_000
            // A new connection replaces the previous one (e.g. after the Mac lost the connection).
            synchronized(Hub) {
                Hub.session?.takeIf { it !== this }?.close()
                Hub.session = this
            }
            Hub.changed()
            svc.onSessionChanged()
            thread(name = "phonelink-tx") { writeLoop() }
            onConnected()
            readLoop()
        } catch (e: Exception) {
            if (!closed) Log.i(TAG, "session ended: $e")
        } finally {
            close()
        }
    }

    private fun watch() {
        while (!closed) {
            try { Thread.sleep(5_000) } catch (_: InterruptedException) { return }
            if (watched.stalled()) {
                Log.i(TAG, "no data from the Mac")
                close()
            }
        }
    }

    private fun readPlain(): JSONObject = JSONObject(String(readFrame(), Charsets.UTF_8))

    private fun writePlain(o: JSONObject) {
        val b = o.toString().toByteArray()
        output.writeInt(b.size)
        output.write(b)
        output.flush()
    }

    private fun readFrame(): ByteArray {
        val n = input.readInt()
        require(n in 0..MAX_FRAME) { "bad frame size $n" }
        return ByteArray(n).also { input.readFully(it) }
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun unb64(s: String) = Base64.decode(s, Base64.NO_WRAP)

    private fun handshake() {
        val hello = readPlain()
        require(hello.optString("t") == "hello" && hello.optInt("v") == 1) { "bad hello" }
        macId = hello.getString("id")
        macName = hello.optString("name", "Mac")
        val nonceM = unb64(hello.getString("nonce"))
        require(nonceM.size == 32)
        val nonceP = Crypto.random(32)
        val salt = nonceM + nonceP
        val phoneName = phoneName(svc)
        val key: ByteArray

        val pubM = hello.optString("pub")
        if (pubM.isNotEmpty()) {
            if (!Hub.isPairing()) {
                writePlain(json("t" to "hello", "v" to 1, "status" to "denied"))
                throw IllegalStateException("pairing not enabled on phone")
            }
            val kp = Crypto.newKeyPair()
            val shared = Crypto.ecdh(kp.private, unb64(pubM))
            val pairKey = Crypto.hkdf(shared, salt, "phonelink pair v1", 32)
            val sas = Crypto.sas(shared, salt)
            writePlain(json("t" to "hello", "v" to 1, "status" to "pair", "name" to phoneName,
                "nonce" to b64(nonceP), "pub" to b64(kp.public.encoded)))

            // Only one pairing request at a time: a new request rejects the previous one.
            val req = Hub.PairRequest(macName, sas)
            synchronized(Hub) {
                Hub.pairRequest?.resolve(false)
                Hub.pairRequest = req
            }
            Hub.changed()
            val ok = try { req.await() } finally {
                synchronized(Hub) { if (Hub.pairRequest === req) Hub.pairRequest = null }
                Hub.changed()
            }
            if (!ok) {
                writePlain(json("t" to "confirm", "ok" to false))
                throw IllegalStateException("pairing rejected on phone")
            }
            writePlain(json("t" to "confirm", "ok" to true, "mac" to b64(Crypto.hmac(pairKey, "p-confirm".toByteArray()))))
            val c = readPlain()
            val expect = Crypto.hmac(pairKey, "m-confirm".toByteArray())
            require(c.optBoolean("ok") && MessageDigest.isEqual(unb64(c.optString("mac")), expect)) { "pairing rejected on Mac" }
            Pairings.save(svc, macId, macName, pairKey)
            Hub.pairingUntil = 0
            svc.pairingChanged()
            key = pairKey
        } else {
            val k = Pairings.key(svc, macId)
            if (k == null) {
                writePlain(json("t" to "hello", "v" to 1, "status" to "unknown"))
                throw IllegalStateException("unknown Mac $macId")
            }
            writePlain(json("t" to "hello", "v" to 1, "status" to "ok", "name" to phoneName, "nonce" to b64(nonceP)))
            key = k
        }
        tx = FrameCipher(Crypto.hkdf(key, salt, "p2m", 32))
        rx = FrameCipher(Crypto.hkdf(key, salt, "m2p", 32))
    }

    fun send(msg: JSONObject) {
        if (closed) return
        val b = msg.toString().toByteArray()
        val d = ByteArray(b.size + 1)
        d[0] = MSG_JSON
        System.arraycopy(b, 0, d, 1, b.size)
        queue.add(Out(d))
    }

    // When the network falls behind, drop delta frames until the next key frame.
    fun sendVideo(flags: Int, ptsUs: Long, data: ByteArray, off: Int, len: Int) {
        if (closed) return
        val important = flags and (VIDEO_CONFIG or VIDEO_KEY) != 0
        if (!important) {
            if (waitForKey) return
            if (queuedVideo.get() > 1_500_000) {
                waitForKey = true
                svc.requestKeyFrame()
                return
            }
        } else if (flags and VIDEO_KEY != 0) {
            waitForKey = false
        }
        val d = ByteArray(len + 10)
        d[0] = MSG_VIDEO
        d[1] = flags.toByte()
        var p = ptsUs
        for (i in 9 downTo 2) { d[i] = (p and 0xff).toByte(); p = p shr 8 }
        System.arraycopy(data, off, d, 10, len)
        enqueue(d, queuedVideo)
    }

    // Drops audio when over ~300 ms is queued, to keep latency low.
    fun sendAudio(data: ByteArray, len: Int) {
        if (closed || queuedAudio.get() > 64_000) return
        val d = ByteArray(len + 1)
        d[0] = MSG_AUDIO
        System.arraycopy(data, 0, d, 1, len)
        enqueue(d, queuedAudio)
    }

    fun sendTerminal(id: Int, data: ByteArray, off: Int = 0, len: Int = data.size) {
        if (closed) return
        queue.add(Out(idFrame(MSG_TERM, id, data, off, len)))
    }

    // Blocks while more than 4 MB of file data is queued.
    fun sendChunk(id: Int, data: ByteArray, len: Int) {
        synchronized(fileLock) {
            while (!closed && queuedFile.get() > 4 shl 20) fileLock.wait(200)
        }
        if (closed) throw java.io.IOException("The Mac disconnected.")
        enqueue(idFrame(MSG_FILE, id, data, 0, len), queuedFile)
    }

    private fun enqueue(d: ByteArray, counter: AtomicLong) {
        counter.addAndGet(d.size.toLong())
        queue.add(Out(d, counter))
    }

    /** [type][id u32 BE][data] */
    private fun idFrame(type: Byte, id: Int, data: ByteArray, off: Int, len: Int): ByteArray {
        val d = ByteArray(len + 5)
        d[0] = type
        d[1] = (id ushr 24).toByte(); d[2] = (id ushr 16).toByte(); d[3] = (id ushr 8).toByte(); d[4] = id.toByte()
        System.arraycopy(data, off, d, 5, len)
        return d
    }

    private fun frameId(f: ByteArray): Int =
        ((f[1].toInt() and 0xff) shl 24) or ((f[2].toInt() and 0xff) shl 16) or
            ((f[3].toInt() and 0xff) shl 8) or (f[4].toInt() and 0xff)

    private fun writeLoop() {
        try {
            while (!closed) {
                val o = queue.poll(5, TimeUnit.SECONDS) ?: continue
                val c = tx.seal(o.data)
                output.writeInt(c.size)
                output.write(c)
                o.counter?.addAndGet(-o.data.size.toLong())
                if (o.counter === queuedFile) synchronized(fileLock) { fileLock.notifyAll() }
                if (queue.isEmpty()) output.flush()
            }
        } catch (e: Exception) {
            if (!closed) Log.i(TAG, "write failed: $e")
            close()
        }
    }

    private fun readLoop() {
        while (!closed) {
            val f = rx.open(readFrame())
            if (f.size > 5 && f[0] == MSG_FILE) {
                Transfers.onChunk(this, frameId(f), f, 5, f.size - 5)
                continue
            }
            if (f.size > 10 && f[0] == MSG_RD_VIDEO) {
                var pts = 0L
                for (i in 2..9) pts = (pts shl 8) or (f[i].toLong() and 0xff)
                RemoteDesktop.onVideo(f[1].toInt() and 0xff, pts, f, 10, f.size - 10)
                continue
            }
            if (f.size >= 5 && f[0] == MSG_TERM) {
                TerminalHub.onOutput(frameId(f), f, 5, f.size - 5)
                continue
            }
            if (f.isEmpty() || f[0] != MSG_JSON) continue
            val m = JSONObject(String(f, 1, f.size - 1, Charsets.UTF_8))
            try {
                handle(m)
            } catch (e: Exception) {
                Log.w(TAG, "handle ${m.optString("t")}", e)
                send(json("t" to "error", "req" to m.optString("t"), "msg" to (e.message ?: e.toString())))
            }
        }
    }

    private fun onConnected() {
        Sms.resetCursor(svc)
        Mms.resetCursor(svc)
        send(svc.status())
        send(svc.links())
        Calls.current?.let { send(it) }
        Media.sessionStarted()
        if (Ringer.ringing) send(json("t" to "ring.state", "ringing" to true))
        Controls.start(svc, this)
    }

    // On failure, sends "error" with the request type so the Mac can try another path.
    private fun bg(req: String, block: () -> Unit) = io.execute {
        try { block() } catch (e: Exception) {
            Log.w(TAG, "request $req failed: ${e.javaClass.simpleName}")
            send(json("t" to "error", "req" to req, "msg" to (e.message ?: e.toString())))
        }
    }

    private fun handle(m: JSONObject) {
        val type = m.optString("t")
        // Remote Desktop and Terminal. These handlers run on the read thread and must not block it.
        if (type.startsWith("rd.")) { RemoteDesktop.handle(m); return }
        if (type.startsWith("term.")) { TerminalHub.handle(m); return }
        when (type) {
            "ping" -> send(json("t" to "pong"))
            "agent" -> Agent.handle(svc, this, m)
            "agent.presence" -> AgentSign.update(svc, m.optBoolean("on"), m.optString("client"))
            "agent.config" -> NotifHistory.setOn(svc, m.optBoolean("history"))
            "status" -> send(svc.status())
            "lohs.start" -> PrivateWifi.start(svc) { send(it) }
            "lohs.stop" -> PrivateWifi.stop()
            "adb.token" -> svc.adbToken = m.optString("token").takeIf { it.length in 16..64 }
            "adb.wifi" -> send(AdbWifi.enable(svc))

            "sms.threads" -> bg(type) { send(Mms.threads(svc)) }
            "sms.messages" -> bg(type) { send(Mms.messages(svc, m.getLong("thread"), m.optInt("limit", 300))) }
            "mms.part" -> bg(type) { send(Mms.part(svc, m.getLong("id"))) }
            "mms.send" -> bg(type) {
                val ref = m.optString("ref")
                val to = m.getJSONArray("addresses").let { a -> (0 until a.length()).map { a.getString(it) } }
                val image = if (m.isNull("image")) null else m.optString("image", null)
                Mms.send(svc, to, m.optString("body"), image) { ok, err ->
                    send(json("t" to "sms.sent", "ref" to ref, "ok" to ok, "error" to err))
                }
            }
            "sms.send" -> bg(type) {
                val ref = m.optString("ref")
                Sms.send(svc, m.getString("address"), m.getString("body")) { ok, err ->
                    send(json("t" to "sms.sent", "ref" to ref, "ok" to ok, "error" to err))
                }
            }
            "contacts" -> bg(type) { send(Contacts.all(svc)) }

            "call.dial" -> Calls.dial(svc, m.getString("number"))
            "call.answer" -> Calls.answer(svc)
            "call.end" -> Calls.end(svc)
            "calls.log" -> bg(type) { send(Calls.log(svc, m.optInt("limit", 100))) }

            "clip" -> Clip.apply(svc, m)
            // The phone is locked, so the shell helper could not read a new clipboard (ShellAgent.readClip).
            "clip.selection" -> InputService.instance?.recentSelection()?.let { send(json("t" to "clip", "text" to it)) }
            "url.open" -> svc.openUrl(m.getString("url"))
            "ring" -> Ringer.start(svc)
            "ring.stop" -> Ringer.stop(svc)
            "media.cmd" -> Media.command(m)
            "media.get" -> Media.sessionStarted()
            "photos.list" -> Photos.list(svc, this, m.optInt("limit", 60))
            "photos.thumb" -> Photos.thumbs(svc, this, m.getJSONArray("ids"))
            "dnd" -> NotifListener.setDnd(m.optBoolean("on"))
            "controls.get" -> bg(type) { send(Controls.state(svc)) }
            "controls.set", "volume.set" -> bg(type) { send(Controls.set(svc, m)) }

            "notif.list" -> bg(type) { send(json("t" to "notif.list", "items" to NotifListener.activeJson(this))) }
            "notif.dismiss" -> NotifListener.instance?.dismiss(m.getString("key"))
            "notif.action" -> NotifListener.instance?.action(m.getString("key"), m.getInt("action"), m.optString("text", null))
            "notif.open" -> NotifListener.instance?.open(m.getString("key"), m.getInt("display"))

            "screen.start" -> svc.startScreen(m.optInt("maxSize", 1920), m.optInt("bitrate", 8_000_000), m.optInt("fps", 60), m.optBoolean("audio"))
            "screen.audio" -> svc.setScreenAudio(m.optBoolean("on"))
            "screen.stop" -> svc.stopScreen()
            "screen.keyframe" -> svc.requestKeyFrame()

            "input.gesture" -> InputService.require().gesture(m.getJSONArray("points"))
            "input.touch" -> InputService.require().touch(m.optString("action"), m.optDouble("x", 0.0), m.optDouble("y", 0.0))
            "input.scroll" -> InputService.require().scroll(m.optDouble("x", 0.0), m.optDouble("y", 0.0), m.optDouble("dx", 0.0), m.optDouble("dy", 0.0), m.optBoolean("lines"))
            "input.text" -> InputService.require().typeText(m.getString("text"))
            "input.key" -> InputService.require().key(m.getString("key"))
            "input.global" -> InputService.require().global(m.getString("action"))
            "input.wake" -> svc.wakeScreen()

            "unpair" -> {
                // The Mac forgot this phone, so forget the Mac too.
                Pairings.remove(svc, macId)
                Bluetooth.refresh(svc)
                Hub.changed()
                close()
            }

            else -> if (type.startsWith("fs.")) Transfers.handle(svc, this, m)
                    else Log.i(TAG, "unknown message $type")
        }
    }

    fun firstIcon(pkg: String): Boolean = synchronized(sentIcons) { sentIcons.add(pkg) }

    // Safe to call more than once and from any thread.
    fun close() {
        if (!closing.compareAndSet(false, true)) return
        closed = true
        link.close()
        io.shutdownNow()
        Controls.stop(this)
        synchronized(fileLock) { fileLock.notifyAll() }
        // Check and clear in one step, or a new session set by run() at this moment could be cleared.
        val wasCurrent = synchronized(Hub) {
            (Hub.session === this).also { if (it) Hub.session = null }
        }
        if (wasCurrent) {
            RemoteDesktop.linkClosed()
            TerminalHub.linkClosed()
            AgentSign.hide(svc)
            Transfers.sessionClosed()
            svc.adbToken = null
            svc.onSessionChanged()
            Hub.changed()
        }
    }
}
