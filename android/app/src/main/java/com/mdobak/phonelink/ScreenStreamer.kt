package com.mdobak.phonelink

import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Surface
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.roundToInt

/** Mirrors the default display into an H.264 encoder and sends each encoded frame to the Mac. */
class ScreenStreamer(
    private val svc: LinkService,
    private val projection: MediaProjection,
    private val maxSize: Int,
    private val bitrate: Int,
    private val fps: Int,
) {
    private val dm = svc.getSystemService(DisplayManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var display: VirtualDisplay? = null
    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    @Volatile private var running = false

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (id != Display.DEFAULT_DISPLAY || !running) return
            val (w, h, _) = size()
            if (w != width || h != height) restartEncoder()
        }
    }

    @Suppress("DEPRECATION")
    private fun size(): Triple<Int, Int, Int> {
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY)
        val m = DisplayMetrics()
        d.getRealMetrics(m)
        val scale = minOf(1.0, maxSize.toDouble() / max(m.widthPixels, m.heightPixels))
        fun even8(v: Double) = max(8, (v / 8).roundToInt() * 8)
        return Triple(even8(m.widthPixels * scale), even8(m.heightPixels * scale), max(120, (m.densityDpi * scale).toInt()))
    }

    /** On failure, releases everything it made and throws. */
    fun start() {
        running = true
        val (w, h, dpi) = size()
        val c = newEncoder(w, h)
        val surface = try { c.createInputSurface() } catch (e: Exception) { stop(); c.release(); throw e }
        try {
            display = projection.createVirtualDisplay(
                "phonelink", w, h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
            )
            c.start()
        } catch (e: Exception) {
            stop()
            surface.release()
            c.release()
            throw e
        }
        drain(c, surface)
        dm.registerDisplayListener(displayListener, main)
    }

    /**
     * Rotation: builds a new encoder. The virtual display stays (Android 14+ allows only one).
     * The old encoder's drain thread releases it and its surface.
     */
    private fun restartEncoder() {
        val old = codec
        var c: MediaCodec? = null
        try {
            val (w, h, dpi) = size()
            c = newEncoder(w, h)
            val surface = c.createInputSurface()
            display?.resize(w, h, dpi)
            display?.setSurface(surface)
            try { old?.signalEndOfInputStream() } catch (_: Exception) {}
            c.start()
            drain(c, surface)
        } catch (e: Exception) {
            Log.w("PhoneLink", "encoder restart failed", e)
            // The drain thread did not start, so nothing else releases the new encoder.
            c?.release()
            svc.stopScreen()
        }
    }

    private fun newEncoder(w: Int, h: Int): MediaCodec {
        width = w
        height = h
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
        try { c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) } catch (e: Exception) { c.release(); throw e }
        codec = c
        sendInfo()
        return c
    }

    fun sendInfo() {
        Hub.send(json("t" to "screen.state", "state" to "streaming", "width" to width, "height" to height))
    }

    private fun drain(c: MediaCodec, surface: Surface) = thread(name = "phonelink-enc") {
        val info = MediaCodec.BufferInfo()
        var buf = ByteArray(256 * 1024)
        try {
            while (running) {
                val i = c.dequeueOutputBuffer(info, 100_000)
                if (i < 0) {
                    if (codec !== c && i == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    continue
                }
                if (info.size > 0) {
                    val out = c.getOutputBuffer(i)!!
                    if (buf.size < info.size) buf = ByteArray(info.size * 2)
                    out.position(info.offset)
                    out.get(buf, 0, info.size)
                    var flags = 0
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or VIDEO_CONFIG
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or VIDEO_KEY
                    Hub.session?.sendVideo(flags, info.presentationTimeUs, buf, 0, info.size)
                }
                c.releaseOutputBuffer(i, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (e: Exception) {
            if (running) Log.w("PhoneLink", "encoder: $e")
        } finally {
            try { c.stop() } catch (_: Exception) {}
            c.release()
            surface.release()
        }
    }

    fun requestKeyFrame() {
        try {
            codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: Exception) {}
    }

    fun stop() {
        running = false
        dm.unregisterDisplayListener(displayListener)
        display?.release()
        display = null
        codec = null
    }
}
