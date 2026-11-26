package com.mdobak.phonelink

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * A history of the notifications, for agents on the Mac (notifications_read with history).
 * Off by default. The Mac turns it on ("agent.config"). Keeps 7 days in the private files of the app.
 * Turning it off deletes the history.
 */
object NotifHistory {
    private const val PREFS = "agent"
    private const val KEY = "notifHistory"
    private const val FILE = "notif-history.jsonl"
    private const val KEEP_MS = 7L * 24 * 3600_000
    private const val MAX = 5000
    private val io = Executors.newSingleThreadExecutor()
    /** On io. Null until loaded. Oldest first. */
    private var list: ArrayList<JSONObject>? = null

    fun isOn(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)

    fun setOn(ctx: Context, on: Boolean) {
        val c = ctx.applicationContext
        if (isOn(c) == on) return
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
        if (!on) io.execute { list = null; File(c.filesDir, FILE).delete() }
    }

    /** n: a notification from NotifListener.toJson, with the time in milliseconds. */
    fun record(ctx: Context, n: JSONObject) {
        if (!isOn(ctx)) return
        val c = ctx.applicationContext
        io.execute {
            // setOn(false) can run between the check above and this task.
            if (!isOn(c)) return@execute
            try {
                val l = load(c)
                // Chat apps update one notification for each new message. Keep only the changes.
                val last = l.lastOrNull { it.optString("key") == n.optString("key") }
                if (last != null && last.optString("title") == n.optString("title") && last.optString("text") == n.optString("text")) return@execute
                l.add(n)
                val f = File(c.filesDir, FILE)
                val cut = System.currentTimeMillis() - KEEP_MS
                if (l.size > MAX || l.first().optLong("time") < cut - 3600_000) {
                    l.removeAll { it.optLong("time") < cut }
                    while (l.size > MAX) l.removeAt(0)
                    f.writeText(l.joinToString("") { it.toString() + "\n" })
                } else {
                    f.appendText(n.toString() + "\n")
                }
            } catch (e: Exception) {
                android.util.Log.w("PhoneLink", "notification history", e)
            }
        }
    }

    /** The newest first. app: a package or a part of the app name. */
    fun query(ctx: Context, app: String, since: Long?, limit: Int): List<JSONObject> {
        val c = ctx.applicationContext
        return io.submit<List<JSONObject>> {
            val out = ArrayList<JSONObject>()
            for (n in load(c).asReversed()) {
                if (since != null && n.optLong("time") < since) break
                if (!isFromApp(n, app)) continue
                out.add(JSONObject(n.toString()))
                if (out.size >= limit) break
            }
            out
        }.get()
    }

    /** app: lowercase package name or a part of the app name. An empty app matches all. */
    fun isFromApp(n: JSONObject, app: String): Boolean =
        app.isEmpty() || n.optString("pkg").lowercase() == app || n.optString("app").lowercase().contains(app)

    /** On io. */
    private fun load(c: Context): ArrayList<JSONObject> {
        list?.let { return it }
        val l = ArrayList<JSONObject>()
        val f = File(c.filesDir, FILE)
        if (f.exists()) f.forEachLine { line -> try { l.add(JSONObject(line)) } catch (_: Exception) {} }
        l.sortBy { it.optLong("time") }
        list = l
        return l
    }
}
