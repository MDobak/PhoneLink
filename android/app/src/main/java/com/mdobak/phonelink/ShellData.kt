package com.mdobak.phonelink

import android.app.Notification
import android.content.ContentResolver
import android.content.ContentUris
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Data features of ShellAgent. They use only the shell user, so they work without the app installed. Same JSON as Session.kt. */
object ShellData {
    @Volatile var push: (JSONObject) -> Unit = {}

    private val ctx get() = Shell.context
    private val cr: ContentResolver get() = ShellContent.resolver
    private val photoPool = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()

    // Arguments do not go through a shell. Killed after 10 s so a request thread never hangs.
    fun run(vararg cmd: String): String {
        val p = ProcessBuilder(*cmd).redirectErrorStream(true).start()
        val kill = timer.schedule({ p.destroyForcibly() }, 10, TimeUnit.SECONDS)
        try {
            val out = p.inputStream.bufferedReader().readText()
            p.waitFor()
            return out
        } finally {
            kill.cancel(false)
        }
    }

    private fun setting(table: String, name: String): String? = try {
        cr.query(Uri.parse("content://settings/$table"), arrayOf("value"), "name=?", arrayOf(name), null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (_: Exception) { null }

    // Same fields as LinkService.status(). "perms" lists what the shell user can do.
    fun status(): JSONObject {
        val b = try { run("dumpsys", "battery") } catch (_: Exception) { "" }
        fun v(k: String) = Regex("^\\s*" + Regex.escape(k) + ":\\s*(.+)$", RegexOption.MULTILINE).find(b)?.groupValues?.get(1)?.trim()
        val scale = v("scale")?.toIntOrNull()?.takeIf { it > 0 } ?: 100
        val level = v("level")?.toIntOrNull()?.let { it * 100 / scale }
        val plugged = listOf("AC powered", "USB powered", "Wireless powered", "Dock powered").any { v(it) == "true" }
        val notifs = try { active(); true } catch (_: Throwable) { false }
        return json(
            "t" to "status",
            "name" to (setting("global", "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL),
            "model" to Build.MODEL,
            "battery" to level,
            "charging" to plugged,
            "shell" to true,
            "perms" to json(
                "sms" to true, // Read only.
                "contacts" to true,
                "phone" to true,
                "notifications" to notifs,
                "control" to false,
                "files" to false,
                "photos" to true,
                "audio" to false,
                "postNotifications" to true,
                "callLog" to true,
                "background" to true,
            ),
        )
    }

    fun smsThreads() = Mms.threads(ctx)
    fun smsMessages(thread: Long, limit: Int) = Mms.messages(ctx, thread, limit)
    fun mmsPart(id: Long) = Mms.part(ctx, id)
    fun contacts() = Contacts.all(ctx)
    fun callsLog(limit: Int) = Calls.log(ctx, limit)

    private val IMAGES: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    fun photosList(limit: Int, reply: (JSONObject) -> Unit) = photoPool.execute {
        val items = JSONArray()
        try {
            val args = Bundle().apply {
                putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media.DATE_ADDED))
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit.coerceIn(1, 500))
            }
            val cols = arrayOf(
                MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.SIZE, MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.MIME_TYPE,
            )
            cr.query(IMAGES, cols, args, null)?.use { c ->
                while (c.moveToNext()) {
                    val taken = c.getLong(2)
                    items.put(json(
                        "id" to c.getLong(0), "name" to c.getString(1),
                        "date" to (if (taken > 0) taken else c.getLong(3) * 1000),
                        "size" to c.getLong(4), "width" to c.getInt(5), "height" to c.getInt(6), "mime" to c.getString(7),
                    ))
                }
            }
            reply(json("t" to "photos.list", "items" to items))
        } catch (e: Exception) {
            reply(json("t" to "photos.list", "items" to items, "error" to "The phone does not give access to photos."))
        }
    }

    fun photosThumbs(ids: JSONArray, reply: (JSONObject) -> Unit) = photoPool.execute {
        for (i in 0 until ids.length()) {
            val id = ids.optLong(i)
            val data = try {
                val bmp = cr.loadThumbnail(ContentUris.withAppendedId(IMAGES, id), Size(360, 360), null)
                val out = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
                bmp.recycle()
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            } catch (_: Exception) { null }
            reply(json("t" to "photos.thumb", "id" to id, "data" to data))
        }
    }

    // Trash on Android 11+ (restorable for 30 days), else delete. Uses the "content" command because ShellContent
    // is read-only. Returns the ids that the default query does not find after the change.
    fun photosDelete(ids: JSONArray): JSONObject {
        val trash = Build.VERSION.SDK_INT >= 30
        val gone = JSONArray()
        var failed = 0
        for (i in 0 until ids.length()) {
            val id = ids.optLong(i, -1L)
            if (id <= 0) { failed++; continue }
            val uri = ContentUris.withAppendedId(IMAGES, id).toString()
            try {
                if (trash) run("content", "update", "--uri", uri, "--bind", "is_trashed:i:1")
                else run("content", "delete", "--uri", uri)
            } catch (_: Exception) {}
            // A query for one item also finds trashed items, so check is_trashed (Android 11+).
            val done = try {
                val args = Bundle().apply { if (trash) putInt("android:query-arg-match-trashed", 1) } // MATCH_INCLUDE
                val cols = if (trash) arrayOf(MediaStore.Images.Media._ID, "is_trashed") else arrayOf(MediaStore.Images.Media._ID)
                cr.query(ContentUris.withAppendedId(IMAGES, id), cols, args, null)?.use { c ->
                    !c.moveToFirst() || (trash && c.getInt(1) == 1)
                } ?: true
            } catch (_: Exception) { false }
            if (done) gone.put(id) else failed++
        }
        return json("t" to "photos.delete", "ids" to gone, "trashed" to trash, "failed" to failed)
    }

    private val nm: Any by lazy { Shell.asInterface("android.app.INotificationManager", Shell.service("notification")) }
    private val sentIcons = HashSet<String>()

    private class Notif(
        val key: String, val pkg: String, val title: String?, val text: String?, val sub: String?,
        val time: Long, val ongoing: Boolean, val summary: Boolean, val foreground: Boolean, val silent: Boolean,
        val actions: List<Pair<String?, Boolean>>, // title, reply
        val placeholder: Boolean = false,
    )

    // INotificationManager needs ACCESS_NOTIFICATIONS, which the shell lacks on some builds.
    // Then parse the dump of the notification service (the shell has DUMP).
    @Suppress("UNCHECKED_CAST")
    private fun active(): List<Notif> {
        val list = try {
            (try { Shell.call(nm, "getActiveNotificationsWithAttribution") } catch (_: Throwable) { Shell.call(nm, "getActiveNotifications") })
                as Array<StatusBarNotification>?
        } catch (_: Throwable) { return dumpNotifs() }
        return list.orEmpty().mapNotNull { s -> try { fromSbn(s) } catch (_: Throwable) { null } }
    }

    private fun fromSbn(sbn: StatusBarNotification): Notif {
        val n = sbn.notification
        val e = n.extras
        return Notif(
            key = sbn.key, pkg = sbn.packageName,
            title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            text = (e.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT))?.toString(),
            sub = e.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
            time = sbn.postTime, ongoing = sbn.isOngoing,
            summary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            foreground = n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0,
            silent = n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0,
            actions = n.actions?.map { a -> a.title?.toString() to (a.remoteInputs?.any { it.allowFreeFormInput } == true) }.orEmpty(),
            placeholder = NotifListener.isPlaceholder(e.keySet(), e.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                e.getCharSequence(Notification.EXTRA_TEXT)?.toString(), n.channelId),
        )
    }

    // Parses "Notification List" in "dumpsys notification --noredact". Values can span lines, so a line
    // that does not start a new value goes into the current one.
    private fun dumpNotifs(): List<Notif> {
        val lines = run("dumpsys", "notification", "--noredact").lines()
        val first = lines.indexOfFirst { it.trim() == "Notification List:" }
        if (first < 0) throw IllegalStateException("No notification list in the dump.")
        val result = ArrayList<Notif>()
        var pkg: String? = null
        var key: String? = null
        var flags = ""
        var update = 0L
        var created = 0L
        var channel: String? = null
        val extras = HashMap<String, String?>()
        val actions = ArrayList<Pair<String?, Boolean>>()
        var inExtras = false
        var inActions = false
        var exKey: String? = null
        val exVal = StringBuilder()
        var exNull = false
        val valueStart = Regex("^ {16}([\\w.]+)=(\\w+)(?: \\((.*))?$")
        val actionLine = Regex("^\\s+\\[(\\d+)\\] (?:\"(.*)\"|null) -> ")
        fun flushValue() {
            val k = exKey ?: return
            var v = exVal.toString()
            if (v.endsWith(")")) v = v.dropLast(1)
            extras[k] = if (exNull) null else v
            exKey = null
        }
        fun finish() {
            flushValue()
            val p = pkg
            val k = key
            if (p != null && k != null) {
                val f = flags.split('|').toSet()
                result.add(Notif(
                    key = k, pkg = p, title = extras["android.title"],
                    text = extras["android.bigText"] ?: extras["android.text"], sub = extras["android.subText"],
                    time = if (update > 0) update else created,
                    ongoing = "ONGOING_EVENT" in f, summary = "GROUP_SUMMARY" in f,
                    foreground = "FOREGROUND_SERVICE" in f, silent = "ONLY_ALERT_ONCE" in f,
                    actions = actions.toList(),
                    placeholder = NotifListener.isPlaceholder(extras.keys, extras["android.title"], extras["android.text"], channel),
                ))
            }
            pkg = null; key = null; flags = ""; update = 0; created = 0; channel = null
            extras.clear(); actions.clear(); inExtras = false; inActions = false
        }
        for (j in first + 1 until lines.size) {
            val l = lines[j]
            if (inExtras) {
                if (l == "            }") { flushValue(); inExtras = false; continue }
                val m = valueStart.find(l)
                if (m != null) {
                    flushValue()
                    exKey = m.groupValues[1]
                    exNull = m.groupValues[2] == "null"
                    exVal.setLength(0)
                    exVal.append(m.groupValues[3])
                } else if (exKey != null) {
                    exVal.append('\n').append(l)
                }
                continue
            }
            if (inActions) {
                if (l.trim() == "}") inActions = false
                else actionLine.find(l)?.let { actions.add(it.groups[2]?.value to false) }
                continue
            }
            if (l.startsWith("  ") && !l.startsWith("   ")) break // Next section.
            when {
                l.startsWith("    NotificationRecord(") -> {
                    finish()
                    pkg = Regex(" pkg=(\\S+)").find(l)?.groupValues?.get(1)
                }
                l.startsWith("      key=") -> key = l.substringAfter("key=").trim()
                l.startsWith("      flags=") -> flags = l.substringAfter("flags=").trim()
                l.startsWith("      mUpdateTimeMs=") -> update = l.substringAfter('=').takeWhile { it.isDigit() }.toLongOrNull() ?: 0
                l.startsWith("      mCreationTimeMs=") -> created = l.substringAfter('=').takeWhile { it.isDigit() }.toLongOrNull() ?: 0
                l.startsWith("            extras={") -> inExtras = true
                l.startsWith("            actions={") -> inActions = true
                l.startsWith("      effectiveNotificationChannel=") ->
                    channel = Regex("mId='([^']*)'").find(l)?.groupValues?.get(1)
            }
        }
        finish()
        return result
    }

    private fun wanted(n: Notif): Boolean {
        if (n.pkg == "com.mdobak.phonelink") return false
        if (n.ongoing || n.summary || n.foreground || n.placeholder) return false
        return !n.title.isNullOrBlank() || !n.text.isNullOrBlank()
    }

    private fun appName(pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun iconPng(pkg: String): String? = try { Shell.iconPng(pkg, 96) } catch (_: Exception) { null }

    private fun firstIcon(pkg: String) = synchronized(sentIcons) { sentIcons.add(pkg) }

    private fun toJson(n: Notif): JSONObject {
        val actions = JSONArray()
        n.actions.forEachIndexed { i, (title, reply) -> actions.put(json("index" to i, "title" to title, "reply" to reply)) }
        return json(
            "key" to n.key,
            "pkg" to n.pkg,
            "app" to appName(n.pkg),
            "title" to n.title,
            "text" to n.text,
            "sub" to n.sub,
            "time" to n.time,
            "silent" to n.silent,
            "actions" to actions,
            "icon" to if (firstIcon(n.pkg)) iconPng(n.pkg) else null,
        )
    }

    fun notifList(): JSONObject {
        val items = JSONArray()
        return try {
            active().filter { wanted(it) }.sortedBy { it.time }.forEach { items.put(toJson(it)) }
            json("t" to "notif.list", "items" to items)
        } catch (e: Throwable) {
            json("t" to "notif.list", "items" to items, "error" to "The phone does not give the notifications to the shell user.")
        }
    }

    // The shell can cancel only its own notifications, so others are snoozed for a year with
    // "cmd notification snooze". Key: "user|package|id|tag|uid". The tag may contain "|".
    fun notifDismiss(key: String) {
        val p = key.split('|')
        require(p.size >= 5) { "The key is not correct." }
        val tag = p.subList(3, p.size - 1).joinToString("|").takeIf { it != "null" }
        try {
            Shell.call(nm, "cancelNotificationWithTag", p[1], Shell.PACKAGE, tag, p[2].toInt(), p[0].toInt())
            if (p[1] == Shell.PACKAGE) return
        } catch (_: Throwable) {}
        val out = run("cmd", "notification", "snooze", "--for", (365L * 24 * 3600 * 1000).toString(), key)
        if (out.contains("Exception") || out.contains("rror")) throw IllegalStateException("The phone did not remove the notification.")
    }

    @Volatile private var notifWatch = false
    @Volatile private var smsWatch = false
    private var watcher: Thread? = null

    fun watch(notifs: Boolean? = null, sms: Boolean? = null) = synchronized(this) {
        if (notifs != null) notifWatch = notifs
        if (sms != null) smsWatch = sms
        if ((notifWatch || smsWatch) && watcher == null) {
            watcher = Thread({ watchLoop() }, "watch").apply { isDaemon = true; start() }
        }
    }

    private fun watchLoop() {
        var known: HashMap<String, Long>? = null
        var lastSms = -1L
        var lastMms = -1L
        val waitingMms = HashSet<Long>()
        var tick = 0
        while (true) {
            try {
                if (notifWatch) known = pollNotifs(known) else known = null
                if (smsWatch && tick % 3 == 0) {
                    if (lastSms < 0) { lastSms = maxId(SMS); lastMms = maxId(MMS) }
                    else { lastSms = pollSms(lastSms); lastMms = pollMms(lastMms, waitingMms) }
                } else if (!smsWatch) { lastSms = -1; lastMms = -1; waitingMms.clear() }
            } catch (e: Throwable) { System.err.println("watch: " + e.javaClass.name) } // The message can contain private data.
            tick++
            Thread.sleep(1000)
        }
    }

    private var notifTick = 0

    // The first poll only records the current set; the Mac gets those with notif.list. Runs every 2 s.
    private fun pollNotifs(old: HashMap<String, Long>?): HashMap<String, Long> {
        if (old != null && notifTick++ % 2 != 0) return old
        val now = HashMap<String, Long>()
        for (s in active()) {
            if (!wanted(s)) continue
            now[s.key] = s.time
            if (old != null && old[s.key] != s.time) {
                try { push(json("t" to "notif.posted", "n" to toJson(s))) } catch (_: Throwable) {}
            }
        }
        old?.keys?.filter { it !in now }?.forEach { push(json("t" to "notif.removed", "key" to it)) }
        return now
    }

    private val SMS = Uri.parse("content://sms")
    private val MMS = Uri.parse("content://mms")

    private fun maxId(uri: Uri): Long = try {
        cr.query(uri, arrayOf("_id"), null, null, "_id DESC LIMIT 1")?.use { c -> if (c.moveToFirst()) c.getLong(0) else 0L } ?: 0L
    } catch (_: Exception) { 0L }

    private fun pollSms(last: Long): Long {
        var id = last
        cr.query(SMS, Sms.COLS, "_id > ?", arrayOf(last.toString()), "_id ASC")?.use { c ->
            while (c.moveToNext()) {
                id = maxOf(id, c.getLong(0))
                push(json("t" to "sms.new", "message" to Sms.row(c, ctx)))
            }
        }
        return id
    }

    // An MMS arrives in steps, so push it only on the second poll that sees it.
    private fun pollMms(last: Long, waiting: HashSet<Long>): Long {
        var id = last
        cr.query(MMS, arrayOf("_id", "thread_id"), "_id > ? AND m_type IN (128, 132)", arrayOf(last.toString()), "_id ASC")?.use { c ->
            while (c.moveToNext()) {
                val mid = c.getLong(0)
                if (waiting.add(mid)) break
                waiting.remove(mid)
                id = mid
                val list = Mms.messages(ctx, c.getLong(1), 30).getJSONArray("messages")
                for (i in 0 until list.length()) {
                    val m = list.getJSONObject(i)
                    if (m.optLong("id") == -mid) { push(json("t" to "sms.new", "message" to m)); break }
                }
            }
        }
        return id
    }

    fun openUrl(url: String) {
        val u = Uri.parse(url)
        require(u.scheme == "http" || u.scheme == "https") { "Only web links can open." }
        run("am", "start", "-a", "android.intent.action.VIEW", "-d", url)
    }

    fun dial(number: String) {
        require(number.isNotBlank() && number.all { it.isDigit() || it in "+*#,;()- " }) { "The number is not correct." }
        run("am", "start", "-a", "android.intent.action.CALL", "-d", Uri.fromParts("tel", number, null).toString())
    }

    fun mediaCommand(action: String) {
        val key = when (action) {
            "play" -> 126; "pause" -> 127; "toggle" -> 85; "next" -> 87; "previous" -> 88
            else -> return // The shell cannot seek.
        }
        run("input", "keyevent", key.toString())
    }

    private val audio: Any by lazy { Shell.asInterface("android.media.IAudioService", Shell.service("audio")) }
    private var player: MediaPlayer? = null
    private var oldVolume = -1
    private var autoStop: ScheduledFuture<*>? = null

    private fun setAlarmVolume(v: Int) {
        try { Shell.call(audio, "setStreamVolume", AudioManager.STREAM_ALARM, v, 0) }
        catch (_: Throwable) { Shell.call(audio, "setStreamVolumeWithAttribution", AudioManager.STREAM_ALARM, v, 0) }
    }

    private fun source(p: MediaPlayer) {
        val uri = setting("system", "ringtone")?.takeIf { it.startsWith("content://") }
        if (uri != null) {
            try {
                cr.openAssetFileDescriptor(Uri.parse(uri), "r")?.use { afd ->
                    p.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                    return
                }
            } catch (e: Exception) { System.err.println("ringtone: $e") }
        }
        val name = try { run("getprop", "ro.config.ringtone").trim() } catch (_: Exception) { "" }
        val dirs = listOf("/product/media/audio/ringtones", "/system/media/audio/ringtones", "/system/media/audio/alarms")
        val f = dirs.map { File(it, name) }.firstOrNull { name.isNotEmpty() && it.isFile }
            ?: dirs.flatMap { File(it).listFiles()?.filter { f -> f.isFile }?.sortedBy { f -> f.name }.orEmpty() }.firstOrNull()
            ?: throw IllegalStateException("No ringtone found.")
        p.setDataSource(f.path)
    }

    fun ringStart() = synchronized(this) {
        if (player != null) return
        oldVolume = try { Shell.call(audio, "getStreamVolume", AudioManager.STREAM_ALARM) as Int } catch (_: Throwable) { -1 }
        try {
            val max = Shell.call(audio, "getStreamMaxVolume", AudioManager.STREAM_ALARM) as Int
            setAlarmVolume(max)
        } catch (e: Throwable) { System.err.println("volume: $e") }
        val p = MediaPlayer()
        try {
            p.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            source(p)
            p.isLooping = true
            p.prepare()
            p.start()
        } catch (e: Throwable) {
            p.release()
            restoreVolume()
            throw e
        }
        player = p
        try { run("input", "keyevent", "KEYCODE_WAKEUP") } catch (_: Exception) {}
        autoStop = timer.schedule({ ringStop() }, 60, TimeUnit.SECONDS)
        push(json("t" to "ring.state", "ringing" to true))
    }

    private fun restoreVolume() {
        if (oldVolume >= 0) try { setAlarmVolume(oldVolume) } catch (_: Throwable) {}
        oldVolume = -1
    }

    fun ringStop() = synchronized(this) {
        autoStop?.cancel(false)
        autoStop = null
        val p = player ?: return
        player = null
        try { p.stop() } catch (_: Exception) {}
        p.release()
        restoreVolume()
        push(json("t" to "ring.state", "ringing" to false))
    }
}
