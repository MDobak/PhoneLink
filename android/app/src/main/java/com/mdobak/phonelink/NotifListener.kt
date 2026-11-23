package com.mdobak.phonelink

import android.app.ActivityOptions
import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Forwards phone notifications to the Mac, and does dismiss, action and reply requests from the Mac. */
class NotifListener : NotificationListenerService() {
    companion object {
        @Volatile var instance: NotifListener? = null

        // System notifications the phone does not list, e.g. the Samsung "ongoing activity" item (Now Bar):
        // it has a special extra, or its only text is its channel name.
        fun isPlaceholder(extraKeys: Set<String>, title: String?, text: String?, channelId: String?): Boolean {
            if (extraKeys.any { it.startsWith("android.ongoingActivityNoti") }) return true
            return text.isNullOrBlank() && title != null && title == channelId
        }

        fun activeJson(s: Session): JSONArray {
            val l = instance ?: return JSONArray()
            val a = JSONArray()
            l.activeNotifications.orEmpty().filter { l.wanted(it) }.sortedBy { it.postTime }.forEach { a.put(l.toJson(it, s)) }
            return a
        }

        // Android can leave the listener unbound after an app update or after the system stops it.
        fun rebind(ctx: Context) {
            if (instance != null) return
            val cn = ComponentName(ctx, NotifListener::class.java)
            val on = android.provider.Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
                ?.contains(cn.flattenToString()) == true
            if (!on) return
            try {
                requestRebind(cn)
            } catch (e: Exception) {
                android.util.Log.w("PhoneLink", "notification listener rebind", e)
            }
        }

        // Set when the Mac turned on Do Not Disturb, so only the Mac turns it off again.
        @Volatile private var macDnd = false

        // The user changed it, so Focus sync does not turn it off later. Returns false if the listener is not connected.
        fun setDndByUser(filter: Int): Boolean {
            val l = instance ?: return false
            l.requestInterruptionFilter(filter)
            macDnd = false
            return true
        }

        fun setDnd(on: Boolean) {
            val l = instance ?: return
            try {
                if (on) {
                    if (l.currentInterruptionFilter == INTERRUPTION_FILTER_ALL) {
                        l.requestInterruptionFilter(INTERRUPTION_FILTER_PRIORITY)
                        macDnd = true
                    }
                } else if (macDnd) {
                    l.requestInterruptionFilter(INTERRUPTION_FILTER_ALL)
                    macDnd = false
                }
            } catch (e: Exception) {
                android.util.Log.w("PhoneLink", "dnd", e)
            }
        }
    }

    override fun onListenerConnected() { instance = this; Media.start(this); Hub.changed() }
    override fun onListenerDisconnected() {
        instance = null
        Media.stop()
        Hub.changed()
        // Android can disconnect the listener (e.g. on low memory). Ask to connect again.
        rebind(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val s = Hub.session ?: return
        if (!wanted(sbn)) return
        s.send(json("t" to "notif.posted", "n" to toJson(sbn, s)))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        Hub.send(json("t" to "notif.removed", "key" to sbn.key))
    }

    fun wanted(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        if (sbn.packageName == packageName) return false
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        val e = n.extras
        val title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = e.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        if (isPlaceholder(e.keySet(), title, text, n.channelId)) return false
        return !title.isNullOrBlank() || !text.isNullOrBlank()
    }

    private fun appName(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun iconPng(pkg: String): String? = try {
        val d = packageManager.getApplicationIcon(pkg)
        val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, 96, 96)
        d.draw(Canvas(b))
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

    fun toJson(sbn: StatusBarNotification, s: Session): JSONObject {
        val n = sbn.notification
        val e = n.extras
        val big = e.getCharSequence(Notification.EXTRA_BIG_TEXT)
        val text = big ?: e.getCharSequence(Notification.EXTRA_TEXT)
        val actions = JSONArray()
        n.actions?.forEachIndexed { i, a ->
            actions.put(json("index" to i, "title" to a.title?.toString(), "reply" to (a.remoteInputs?.any { it.allowFreeFormInput } == true)))
        }
        return json(
            "key" to sbn.key,
            "pkg" to sbn.packageName,
            "app" to appName(sbn.packageName),
            "title" to e.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            "text" to text?.toString(),
            "sub" to e.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            "time" to sbn.postTime,
            "silent" to (n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0),
            "actions" to actions,
            "icon" to if (s.firstIcon(sbn.packageName)) iconPng(sbn.packageName) else null,
        )
    }

    fun dismiss(key: String) = cancelNotification(key)

    // Sends the tap intent to a display, e.g. the virtual display of an app window. If it cannot start, do
    // nothing: the Mac already started the app there.
    fun open(key: String, display: Int) {
        val sbn = activeNotifications.firstOrNull { it.key == key } ?: return
        val n = sbn.notification
        val pi = n.contentIntent ?: return
        try {
            val o = ActivityOptions.makeBasic().setLaunchDisplayId(display)
            if (Build.VERSION.SDK_INT >= 34) {
                o.setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            }
            pi.send(this, 0, null, null, null, null, o.toBundle())
            // Do the same as a tap on the phone: remove a notification that has "auto cancel".
            if (n.flags and Notification.FLAG_AUTO_CANCEL != 0) cancelNotification(key)
        } catch (e: Exception) {
            android.util.Log.w("PhoneLink", "notification open", e)
        }
    }

    fun action(key: String, index: Int, text: String?) {
        val sbn = activeNotifications.firstOrNull { it.key == key } ?: return
        val a = sbn.notification.actions?.getOrNull(index) ?: return
        val inputs = a.remoteInputs
        if (text != null && inputs != null && inputs.isNotEmpty()) {
            val intent = Intent()
            val results = Bundle()
            inputs.forEach { results.putCharSequence(it.resultKey, text) }
            RemoteInput.addResultsToIntent(inputs, intent, results)
            a.actionIntent.send(this, 0, intent)
        } else {
            a.actionIntent.send()
        }
    }
}
