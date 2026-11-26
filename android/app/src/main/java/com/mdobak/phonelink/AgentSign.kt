package com.mdobak.phonelink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * An ongoing notification while an agent on the Mac uses this phone ("agent.presence" from the Mac).
 * Its Stop action turns off the agents on the Mac ("agent.stop").
 */
object AgentSign {
    private const val CHANNEL = "agent.active"
    private const val ID = 9
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var appCtx: Context? = null
    /** The Mac refreshes the sign while the agent works. Remove a sign that the Mac did not remove, for example after a disconnect. */
    private val expire = Runnable { appCtx?.let { hide(it) } }

    fun update(ctx: Context, on: Boolean, client: String) {
        if (on) show(ctx, client) else hide(ctx)
    }

    private fun show(ctx: Context, client: String) {
        val c = ctx.applicationContext
        appCtx = c
        val nm = c.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Agent activity", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows when an agent on your Mac uses this phone."
            })
        }
        val stop = PendingIntent.getBroadcast(c, 9, Intent(c, AgentStopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        val name = client.trim().take(60).ifEmpty { "An agent" }
        val n = Notification.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle("$name is using this phone")
            .setContentText("An agent on your Mac uses Phone Link. Tap Stop to turn off agents.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        nm.notify(ID, n)
        main.removeCallbacks(expire)
        main.postDelayed(expire, 5 * 60_000L)
    }

    fun hide(ctx: Context) {
        main.removeCallbacks(expire)
        ctx.applicationContext.getSystemService(NotificationManager::class.java).cancel(ID)
    }
}

class AgentStopReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Hub.send(json("t" to "agent.stop"))
        AgentSign.hide(ctx)
    }
}
