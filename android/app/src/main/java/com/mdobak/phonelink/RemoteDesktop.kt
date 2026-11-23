package com.mdobak.phonelink

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.SparseIntArray
import android.view.KeyEvent
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Remote Desktop state, H.264 decoding and input messages. The UI is RemoteDesktopActivity. */
object RemoteDesktop {
    private const val TAG = "RemoteDesktop"
    const val FLAG_CONFIG = 1
    const val FLAG_KEY = 2

    class Display(val id: Long, val name: String, val width: Int, val height: Int, val main: Boolean)

    /** All calls come on the main thread. */
    interface Listener {
        fun onRemoteState()
        fun onCursor()
        fun onVideoSize(width: Int, height: Int)
    }

    /** idle, connecting, streaming, stopped, disabled, needsPermission or offline. */
    @Volatile var state = "idle"; private set
    @Volatile var missing: List<String> = emptyList(); private set
    @Volatile var message = ""; private set
    @Volatile var width = 0; private set
    @Volatile var height = 0; private set
    @Volatile var display: Long? = null; private set
    @Volatile var displays: List<Display> = emptyList(); private set
    @Volatile var cursorX = 0.5f; private set
    @Volatile var cursorY = 0.5f; private set
    @Volatile var cursorVisible = false; private set

    @Volatile var listener: Listener? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var decoder: Decoder? = null
    @Volatile private var lastKeyRequest = 0L

    /** Called on the session read thread: do not block. */
    fun handle(m: JSONObject) {
        when (m.optString("t")) {
            "rd.state" -> {
                state = m.optString("state", "stopped")
                missing = m.optJSONArray("missing")?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
                message = m.optString("message", "")
                if (m.has("width")) width = m.optInt("width")
                if (m.has("height")) height = m.optInt("height")
                if (m.has("display") && !m.isNull("display")) display = m.optLong("display")
                m.optJSONArray("displays")?.let { a ->
                    displays = (0 until a.length()).mapNotNull { a.optJSONObject(it) }.map {
                        Display(it.optLong("id"), it.optString("name", "Display"), it.optInt("width"), it.optInt("height"), it.optBoolean("main"))
                    }
                }
                main.post { listener?.onRemoteState() }
            }
            "rd.cursor" -> {
                cursorX = m.optDouble("x", 0.5).toFloat()
                cursorY = m.optDouble("y", 0.5).toFloat()
                cursorVisible = m.optBoolean("visible", true)
                main.post { listener?.onCursor() }
            }
        }
    }

    /** Called on the session read thread: do not block. */
    fun onVideo(flags: Int, ptsUs: Long, data: ByteArray, off: Int, len: Int) {
        val d = decoder ?: return
        d.offer(Frame(flags, ptsUs, data.copyOfRange(off, off + len)))
    }

    fun linkClosed() {
        state = "offline"
        decoder?.resync()
        main.post { listener?.onRemoteState() }
    }

    fun start(displayId: Long?, quality: String, maxWidth: Int, maxHeight: Int, fps: Int) {
        val s = Hub.session
        if (s == null) { state = "offline"; main.post { listener?.onRemoteState() }; return }
        state = "connecting"
        decoder?.resync()
        val m = json("t" to "rd.start", "maxWidth" to maxWidth, "maxHeight" to maxHeight, "fps" to fps, "quality" to quality)
        if (displayId != null) m.put("display", displayId)
        s.send(m)
        main.post { listener?.onRemoteState() }
    }

    fun stop() {
        Hub.session?.send(json("t" to "rd.stop"))
        if (state != "offline") state = "idle"
    }

    fun setQuality(quality: String, maxWidth: Int, maxHeight: Int, fps: Int) =
        send("t" to "rd.quality", "quality" to quality, "maxWidth" to maxWidth, "maxHeight" to maxHeight, "fps" to fps)

    /** At most one request per 500 ms. */
    fun requestKeyFrame() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKeyRequest < 500) return
        lastKeyRequest = now
        send("t" to "rd.keyframe")
    }

    fun attach(surface: Surface) {
        detach()
        decoder = Decoder(surface).also { it.start() }
        if (state == "streaming") requestKeyFrame()
    }

    fun detach() {
        val d = decoder ?: return
        decoder = null
        d.finish()
    }

    private fun send(vararg pairs: Pair<String, Any?>) { Hub.session?.send(json(*pairs)) }

    fun pointer(x: Float, y: Float, action: String, button: String = "left", clicks: Int = 1) =
        send("t" to "rd.pointer", "x" to x.coerceIn(0f, 1f).toDouble(), "y" to y.coerceIn(0f, 1f).toDouble(),
            "action" to action, "button" to button, "clicks" to clicks)

    fun moveBy(dx: Float, dy: Float) = send("t" to "rd.moveBy", "dx" to dx.toDouble(), "dy" to dy.toDouble())

    fun button(action: String, button: String = "left", clicks: Int = 1) =
        send("t" to "rd.button", "action" to action, "button" to button, "clicks" to clicks)

    fun scroll(dx: Float, dy: Float, phase: String) =
        send("t" to "rd.scroll", "dx" to dx.toDouble(), "dy" to dy.toDouble(), "phase" to phase)

    fun key(code: Int, down: Boolean, mods: Collection<String>) =
        send("t" to "rd.key", "code" to code, "down" to down, "mods" to JSONArray(mods.toList()))

    fun press(code: Int, mods: Collection<String>) { key(code, true, mods); key(code, false, mods) }

    fun text(s: String) { if (s.isNotEmpty()) send("t" to "rd.text", "text" to s) }

    fun system(action: String) = send("t" to "rd.system", "action" to action)

    private class Frame(val flags: Int, val pts: Long, val data: ByteArray)

    /** Decodes on its own thread and drops late frames. */
    private class Decoder(val surface: Surface) : Thread("rd-decode") {
        private val queue = LinkedBlockingQueue<Frame>()
        private val needSync = AtomicBoolean(true)
        @Volatile private var running = true
        private var codec: MediaCodec? = null
        private var sps: ByteArray? = null
        private var pps: ByteArray? = null
        private var waitKey = true
        private val info = MediaCodec.BufferInfo()
        private val decoded = AtomicInteger()
        private val dropped = AtomicInteger()
        private var statsAt = SystemClock.elapsedRealtime()
        private var outW = 0
        private var outH = 0
        private var announce = true

        fun offer(f: Frame) {
            if (queue.size > 90) {
                // Far behind: drop the queue and resume at the next key frame.
                dropped.addAndGet(queue.size)
                queue.clear()
                needSync.set(true)
                requestKeyFrame()
            }
            queue.add(f)
        }

        fun resync() { queue.clear(); needSync.set(true) }

        fun finish() {
            running = false
            try { join(500) } catch (_: InterruptedException) {}
        }

        override fun run() {
            try {
                while (running) {
                    val f = queue.poll(10, TimeUnit.MILLISECONDS)
                    if (f != null) feed(f)
                    drain()
                    stats()
                }
            } catch (e: Exception) {
                Log.w(TAG, "decoder stopped", e)
            } finally {
                release()
            }
        }

        private fun stats() {
            val now = SystemClock.elapsedRealtime()
            if (now - statsAt < 2000) return
            val secs = (now - statsAt) / 1000.0
            statsAt = now
            if (RemoteDesktop.state != "streaming") { decoded.set(0); dropped.set(0); return }
            val fps = decoded.getAndSet(0) / secs
            Hub.session?.send(json("t" to "rd.stats", "rttMs" to 0, "decodedFps" to Math.round(fps * 10) / 10.0,
                "dropped" to dropped.getAndSet(0)))
        }

        private fun feed(f: Frame) {
            if (needSync.getAndSet(false)) { waitKey = true; announce = true }
            val config = f.flags and FLAG_CONFIG != 0
            var key = f.flags and FLAG_KEY != 0
            if (config) {
                val (s, p, hasIdr) = splitConfig(f.data)
                if (s != null && p != null && (codec == null || !s.contentEquals(sps) || !p.contentEquals(pps))) {
                    if (!configure(s, p)) return
                }
                if (hasIdr) key = true
                if (!key) return
            }
            val c = codec
            if (c == null) { if (key) requestKeyFrame(); return }
            if (waitKey && !key) return
            try {
                var idx = -1
                val until = SystemClock.elapsedRealtime() + 100
                while (running) {
                    idx = c.dequeueInputBuffer(5_000)
                    if (idx >= 0) break
                    drain()
                    if (codec !== c) return
                    if (SystemClock.elapsedRealtime() > until) throw IllegalStateException("no input buffer")
                }
                if (idx < 0) return
                val buf = c.getInputBuffer(idx) ?: throw IllegalStateException("no buffer")
                buf.clear()
                if (f.data.size > buf.capacity()) {
                    c.queueInputBuffer(idx, 0, 0, f.pts, 0)
                    throw IllegalStateException("frame too large: " + f.data.size)
                }
                buf.put(f.data)
                c.queueInputBuffer(idx, 0, f.data.size, f.pts, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                if (key) waitKey = false
            } catch (e: Exception) {
                fail(e)
            }
        }

        private fun drain() {
            val c = codec ?: return
            try {
                while (true) {
                    val idx = c.dequeueOutputBuffer(info, 0)
                    when {
                        idx >= 0 -> {
                            // More frames are queued, so this one is stale.
                            val late = queue.size > 2
                            c.releaseOutputBuffer(idx, !late)
                            decoded.incrementAndGet()
                            if (late) dropped.incrementAndGet()
                            if (!late && announce && outW > 0) {
                                // Tell the UI a picture is visible again after a restart.
                                announce = false
                                val w = outW; val h = outH
                                main.post { listener?.onVideoSize(w, h) }
                            }
                        }
                        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val fmt = c.outputFormat
                            var w = fmt.getInteger(MediaFormat.KEY_WIDTH)
                            var h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                            if (fmt.containsKey("crop-right") && fmt.containsKey("crop-left")) w = fmt.getInteger("crop-right") - fmt.getInteger("crop-left") + 1
                            if (fmt.containsKey("crop-bottom") && fmt.containsKey("crop-top")) h = fmt.getInteger("crop-bottom") - fmt.getInteger("crop-top") + 1
                            outW = w; outH = h
                        }
                        idx == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                    }
                }
            } catch (e: Exception) {
                fail(e)
            }
        }

        private fun configure(s: ByteArray, p: ByteArray): Boolean {
            release()
            return try {
                val w = if (RemoteDesktop.width > 0) RemoteDesktop.width else 1920
                val h = if (RemoteDesktop.height > 0) RemoteDesktop.height else 1080
                val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
                fmt.setByteBuffer("csd-0", ByteBuffer.wrap(s))
                fmt.setByteBuffer("csd-1", ByteBuffer.wrap(p))
                fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 shl 20)
                fmt.setInteger(MediaFormat.KEY_PRIORITY, 0)
                val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                val caps = c.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                if (caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                if (c.name.contains("qti", ignoreCase = true)) fmt.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                c.configure(fmt, surface, null, 0)
                c.start()
                codec = c; sps = s; pps = p
                waitKey = true
                true
            } catch (e: Exception) {
                Log.w(TAG, "configure failed", e)
                release()
                requestKeyFrame()
                false
            }
        }

        private fun fail(e: Exception) {
            Log.w(TAG, "decode error: $e")
            release()
            waitKey = true
            requestKeyFrame()
        }

        private fun release() {
            val c = codec ?: return
            codec = null; sps = null; pps = null
            try { c.stop() } catch (_: Exception) {}
            try { c.release() } catch (_: Exception) {}
        }

        /** Finds SPS and PPS (with start codes) in an Annex B buffer, and whether it has an IDR slice. */
        private fun splitConfig(b: ByteArray): Triple<ByteArray?, ByteArray?, Boolean> {
            val starts = ArrayList<Int>()   // index of the first byte of each start code
            val heads = ArrayList<Int>()    // index of the NAL header byte
            var i = 0
            while (i + 3 <= b.size) {
                if (b[i].toInt() == 0 && b[i + 1].toInt() == 0 && b[i + 2].toInt() == 1) {
                    starts.add(if (i > 0 && b[i - 1].toInt() == 0) i - 1 else i)
                    heads.add(i + 3)
                    i += 3
                } else i++
            }
            var s: ByteArray? = null; var p: ByteArray? = null; var idr = false
            for (n in heads.indices) {
                if (heads[n] >= b.size) continue
                val end = if (n + 1 < starts.size) starts[n + 1] else b.size
                when (b[heads[n]].toInt() and 0x1f) {
                    7 -> s = b.copyOfRange(starts[n], end)
                    8 -> p = b.copyOfRange(starts[n], end)
                    5 -> idr = true
                }
            }
            return Triple(s, p, idr)
        }
    }
}

/** Maps Android key codes and US layout characters to macOS virtual key codes. */
object MacKeys {
    const val RETURN = 36; const val TAB = 48; const val SPACE = 49; const val DELETE = 51; const val ESCAPE = 53
    const val FORWARD_DELETE = 117; const val HOME = 115; const val END = 119; const val PAGE_UP = 116; const val PAGE_DOWN = 121
    const val LEFT = 123; const val RIGHT = 124; const val DOWN = 125; const val UP = 126
    const val COMMAND = 55
    val F = intArrayOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111)   // F1..F12

    private val android = SparseIntArray().apply {
        val letters = intArrayOf(0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6)
        for (n in 0 until 26) put(KeyEvent.KEYCODE_A + n, letters[n])
        val digits = intArrayOf(29, 18, 19, 20, 21, 23, 22, 26, 28, 25)
        for (n in 0..9) put(KeyEvent.KEYCODE_0 + n, digits[n])
        for (n in 0 until 12) put(KeyEvent.KEYCODE_F1 + n, F[n])
        val pad = intArrayOf(82, 83, 84, 85, 86, 87, 88, 89, 91, 92)
        for (n in 0..9) put(KeyEvent.KEYCODE_NUMPAD_0 + n, pad[n])
        put(KeyEvent.KEYCODE_MINUS, 27); put(KeyEvent.KEYCODE_EQUALS, 24)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 33); put(KeyEvent.KEYCODE_RIGHT_BRACKET, 30)
        put(KeyEvent.KEYCODE_BACKSLASH, 42); put(KeyEvent.KEYCODE_SEMICOLON, 41); put(KeyEvent.KEYCODE_APOSTROPHE, 39)
        put(KeyEvent.KEYCODE_GRAVE, 50); put(KeyEvent.KEYCODE_COMMA, 43); put(KeyEvent.KEYCODE_PERIOD, 47); put(KeyEvent.KEYCODE_SLASH, 44)
        put(KeyEvent.KEYCODE_SPACE, SPACE); put(KeyEvent.KEYCODE_TAB, TAB); put(KeyEvent.KEYCODE_ENTER, RETURN)
        put(KeyEvent.KEYCODE_DEL, DELETE); put(KeyEvent.KEYCODE_FORWARD_DEL, FORWARD_DELETE); put(KeyEvent.KEYCODE_ESCAPE, ESCAPE)
        put(KeyEvent.KEYCODE_MOVE_HOME, HOME); put(KeyEvent.KEYCODE_MOVE_END, END)
        put(KeyEvent.KEYCODE_PAGE_UP, PAGE_UP); put(KeyEvent.KEYCODE_PAGE_DOWN, PAGE_DOWN)
        put(KeyEvent.KEYCODE_DPAD_LEFT, LEFT); put(KeyEvent.KEYCODE_DPAD_RIGHT, RIGHT)
        put(KeyEvent.KEYCODE_DPAD_DOWN, DOWN); put(KeyEvent.KEYCODE_DPAD_UP, UP)
        put(KeyEvent.KEYCODE_META_LEFT, 55); put(KeyEvent.KEYCODE_META_RIGHT, 54)
        put(KeyEvent.KEYCODE_SHIFT_LEFT, 56); put(KeyEvent.KEYCODE_SHIFT_RIGHT, 60)
        put(KeyEvent.KEYCODE_ALT_LEFT, 58); put(KeyEvent.KEYCODE_ALT_RIGHT, 61)
        put(KeyEvent.KEYCODE_CTRL_LEFT, 59); put(KeyEvent.KEYCODE_CTRL_RIGHT, 62)
        put(KeyEvent.KEYCODE_CAPS_LOCK, 57); put(KeyEvent.KEYCODE_FUNCTION, 63)
        put(KeyEvent.KEYCODE_NUMPAD_DOT, 65); put(KeyEvent.KEYCODE_NUMPAD_MULTIPLY, 67); put(KeyEvent.KEYCODE_NUMPAD_ADD, 69)
        put(KeyEvent.KEYCODE_NUMPAD_SUBTRACT, 78); put(KeyEvent.KEYCODE_NUMPAD_DIVIDE, 75); put(KeyEvent.KEYCODE_NUMPAD_ENTER, 76)
        put(KeyEvent.KEYCODE_NUMPAD_EQUALS, 81); put(KeyEvent.KEYCODE_NUM_LOCK, 71)
        put(KeyEvent.KEYCODE_NUMPAD_COMMA, 43); put(KeyEvent.KEYCODE_NUMPAD_LEFT_PAREN, 25); put(KeyEvent.KEYCODE_NUMPAD_RIGHT_PAREN, 29)
        put(KeyEvent.KEYCODE_INSERT, 114); put(KeyEvent.KEYCODE_HELP, 114)
        put(KeyEvent.KEYCODE_SYSRQ, 105); put(KeyEvent.KEYCODE_SCROLL_LOCK, 107); put(KeyEvent.KEYCODE_BREAK, 113)
        put(KeyEvent.KEYCODE_VOLUME_MUTE, 74)
    }

    /** Android key codes that need Shift on a US layout. */
    private val androidShifted = SparseIntArray().apply {
        put(KeyEvent.KEYCODE_AT, 19); put(KeyEvent.KEYCODE_POUND, 20); put(KeyEvent.KEYCODE_STAR, 28); put(KeyEvent.KEYCODE_PLUS, 24)
    }

    fun forKeyCode(keyCode: Int): Int = android.get(keyCode, androidShifted.get(keyCode, -1))

    fun needsShift(keyCode: Int) = androidShifted.indexOfKey(keyCode) >= 0

    fun mods(meta: Int): MutableSet<String> {
        val m = LinkedHashSet<String>()
        if (meta and KeyEvent.META_META_ON != 0) m.add("cmd")
        if (meta and KeyEvent.META_ALT_ON != 0) m.add("opt")
        if (meta and KeyEvent.META_CTRL_ON != 0) m.add("ctrl")
        if (meta and KeyEvent.META_SHIFT_ON != 0) m.add("shift")
        if (meta and KeyEvent.META_FUNCTION_ON != 0) m.add("fn")
        return m
    }

    // The character at index n is on macOS key code n. "¤" marks a key without a character.
    private const val PLAIN = "asdfhgzxcv¤bqweryt123465=97-80]ou[ip¤lj'k;\\,/nm.¤ ` "
    private const val SHIFTED = "ASDFHGZXCV¤BQWERYT!@#$^%+(&_*)}OU{IP¤LJ\"K:|<?NM>¤ ~ "

    fun forChar(c: Char): Pair<Int, Boolean>? {
        when (c) {
            '\n' -> return RETURN to false
            '\t' -> return TAB to false
            ' ' -> return SPACE to false
            '¤' -> return null
        }
        val p = PLAIN.indexOf(c)
        if (p in 0..50) return p to false
        val s = SHIFTED.indexOf(c)
        if (s in 0..50) return s to true
        return null
    }
}
