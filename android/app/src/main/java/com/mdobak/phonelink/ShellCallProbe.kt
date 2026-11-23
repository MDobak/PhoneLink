package com.mdobak.phonelink

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Looper

/**
 * Test probe: checks if the shell user can get and send mobile call audio. Keeps no audio; prints only RMS levels.
 * Run: CLASSPATH=<apk> app_process / com.mdobak.phonelink.ShellCallProbe [wait]
 */
object ShellCallProbe {
    private lateinit var am: AudioManager

    private fun call(name: String, vararg a: Any): Any? = try {
        AudioManager::class.java.methods.first { it.name == name && it.parameterCount == a.size }.invoke(am, *a)
    } catch (e: Throwable) {
        val c = (e as? java.lang.reflect.InvocationTargetException)?.targetException ?: e
        "ERR " + c.javaClass.simpleName + ": " + c.message
    }

    private fun fmt(rate: Int, mask: Int) =
        AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(mask).build()

    private fun measure(label: String, r: Any?, rate: Int) {
        if (r !is AudioRecord || r.state != AudioRecord.STATE_INITIALIZED) { println("$label: not available: $r"); return }
        try {
            r.startRecording()
            val buf = ShortArray(rate / 2)
            val out = StringBuilder()
            repeat(4) {
                val n = r.read(buf, 0, buf.size)
                var s = 0.0
                for (i in 0 until maxOf(n, 0)) s += buf[i].toDouble() * buf[i]
                out.append(if (n > 0) Math.sqrt(s / n).toInt() else n).append(' ')
            }
            println("$label: rms $out")
            r.stop()
        } catch (e: Throwable) {
            println("$label: ERR " + e.message)
        } finally {
            r.release()
        }
    }

    private fun source(src: Int, rate: Int): Any? = try {
        AudioRecord.Builder().setAudioSource(src).setAudioFormat(fmt(rate, AudioFormat.CHANNEL_IN_MONO)).build()
    } catch (e: Throwable) { "ERR " + e.message }

    @JvmStatic
    fun main(args: Array<String>) {
        if (Looper.myLooper() == null) Looper.prepare()
        am = Shell.context.getSystemService(AudioManager::class.java)
        println("interceptable=" + call("isPstnCallAudioInterceptable"))
        if (args.contains("wait")) {
            val end = System.currentTimeMillis() + 180_000
            while (am.mode != AudioManager.MODE_IN_CALL && System.currentTimeMillis() < end) Thread.sleep(250)
            println("mode after wait=" + am.mode)
            if (am.mode != AudioManager.MODE_IN_CALL) { System.exit(0) }
            Thread.sleep(3000)
        }
        measure("intercept16k", call("getCallDownlinkExtractionAudioRecord", fmt(16000, AudioFormat.CHANNEL_IN_MONO)), 16000)
        measure("intercept48k", call("getCallDownlinkExtractionAudioRecord", fmt(48000, AudioFormat.CHANNEL_IN_MONO)), 48000)
        val tx = call("getCallUplinkInjectionAudioTrack", fmt(16000, AudioFormat.CHANNEL_OUT_MONO)) as? AudioTrack
        val feeder = Thread {
            tx?.play()
            val z = ShortArray(1600)
            while (tx?.playState == AudioTrack.PLAYSTATE_PLAYING) { if (tx.write(z, 0, z.size) <= 0) break }
        }
        feeder.isDaemon = true
        feeder.start()
        Thread.sleep(300)
        measure("intercept16k+tx", call("getCallDownlinkExtractionAudioRecord", fmt(16000, AudioFormat.CHANNEL_IN_MONO)), 16000)
        try { tx?.stop(); tx?.release() } catch (_: Throwable) {}
        // These sources need CAPTURE_AUDIO_OUTPUT.
        measure("VOICE_DOWNLINK", source(MediaRecorder.AudioSource.VOICE_DOWNLINK, 16000), 16000)
        measure("VOICE_CALL", source(MediaRecorder.AudioSource.VOICE_CALL, 16000), 16000)
        measure("VOICE_UPLINK", source(MediaRecorder.AudioSource.VOICE_UPLINK, 16000), 16000)
        System.exit(0)
    }
}
