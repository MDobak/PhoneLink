package com.mdobak.phonelink

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log

/** Find my phone: rings at full alarm volume, also in silent mode, until the user stops it or for 60 seconds. */
object Ringer {
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var oldVolume = -1
    private var appCtx: Context? = null
    private val autoStop = Runnable { appCtx?.let { stop(it) } }

    /** True until stop, also when no sound plays and the phone only vibrates. */
    @Volatile var ringing = false
        private set

    fun start(ctx: Context) { main.post(fun() {
        if (ringing) return
        ringing = true
        val c = ctx.applicationContext
        appCtx = c
        val am = c.getSystemService(AudioManager::class.java)
        oldVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        try { am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) } catch (_: Exception) {}
        val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        val sources = listOfNotNull(
            RingtoneManager.getActualDefaultRingtoneUri(c, RingtoneManager.TYPE_RINGTONE),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
        )
        for (uri in sources) {
            try {
                player = MediaPlayer().apply {
                    setAudioAttributes(attrs)
                    setDataSource(c, uri)
                    isLooping = true
                    prepare()
                    start()
                }
                break
            } catch (e: Exception) {
                Log.w("PhoneLink", "ring source failed: $uri", e)
                player?.release()
                player = null
            }
        }
        try {
            c.getSystemService(VibratorManager::class.java).defaultVibrator
                .vibrate(VibrationEffect.createWaveform(longArrayOf(0, 900, 600), 0), attrs)
        } catch (_: Exception) {}
        Hub.service?.wakeScreen()

        val stop = PendingIntent.getBroadcast(c, 6, Intent(c, RingStopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(c, "prompt")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle("Your Mac is looking for this phone")
            .setContentText("Tap to stop")
            .setContentIntent(stop)
            .setDeleteIntent(stop)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .setCategory(Notification.CATEGORY_ALARM)
            .build()
        c.getSystemService(NotificationManager::class.java).notify(4, n)
        main.removeCallbacks(autoStop)
        main.postDelayed(autoStop, 60_000)
        Hub.send(json("t" to "ring.state", "ringing" to true))
    }) }

    fun stop(ctx: Context) { main.post(fun() {
        val c = ctx.applicationContext
        main.removeCallbacks(autoStop)
        if (!ringing) return
        ringing = false
        player?.let { p ->
            player = null
            try { p.stop() } catch (_: Exception) {}
            p.release()
        }
        val am = c.getSystemService(AudioManager::class.java)
        if (oldVolume >= 0) try { am.setStreamVolume(AudioManager.STREAM_ALARM, oldVolume, 0) } catch (_: Exception) {}
        try { c.getSystemService(VibratorManager::class.java).defaultVibrator.cancel() } catch (_: Exception) {}
        c.getSystemService(NotificationManager::class.java).cancel(4)
        Hub.send(json("t" to "ring.state", "ringing" to false))
    }) }
}

class RingStopReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) { Ringer.stop(ctx) }
}
