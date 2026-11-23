package com.mdobak.phonelink

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.util.Log
import kotlin.concurrent.thread

/**
 * The phone sound during screen sharing: 48 kHz, stereo, 16-bit PCM in 20 ms chunks.
 * Android captures only apps that allow it (most media apps and games). Calls are never captured.
 */
class AudioCapture(private val ctx: Context, private val projection: MediaProjection) {
    @Volatile private var running = false

    fun start(): Boolean {
        if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return false
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            @Suppress("MissingPermission")
            AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(maxOf(min, CHUNK * 8))
                .setAudioPlaybackCaptureConfig(config).build()
        } catch (e: Exception) {
            Log.w("PhoneLink", "audio capture failed", e)
            return false
        }
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return false }
        try {
            r.startRecording()
        } catch (e: Exception) {
            Log.w("PhoneLink", "audio capture did not start: $e")
            r.release()
            return false
        }
        running = true
        thread(name = "phonelink-audio") {
            val buf = ByteArray(CHUNK)
            try {
                while (running) {
                    var n = 0
                    while (n < CHUNK && running) {
                        val k = r.read(buf, n, CHUNK - n)
                        if (k < 0) throw IllegalStateException("read $k")
                        n += k
                    }
                    if (n == CHUNK) Hub.session?.sendAudio(buf, n)
                }
            } catch (e: Exception) {
                if (running) Log.w("PhoneLink", "audio: $e")
            } finally {
                try { r.stop() } catch (_: Exception) {}
                r.release()
            }
        }
        return true
    }

    /** The capture thread releases the recorder within 20 ms. */
    fun stop() {
        running = false
    }

    companion object {
        const val RATE = 48_000
        const val CHUNK = 3840 // 20 ms of 48 kHz stereo 16-bit
    }
}
