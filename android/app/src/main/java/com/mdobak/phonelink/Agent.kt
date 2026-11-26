package com.mdobak.phonelink

import android.app.Activity
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.database.Cursor
import android.location.Location
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Base64
import android.util.Log
import android.view.Display
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Requests from agents on the Mac (the MCP tools of the Mac app).
 * Request: {"t": "agent", "rid", "op", "args"}. Reply: {"t": "agent.result", "rid", "ok", "data" or "error"}.
 * The Mac checks the agent settings. The phone checks its own permissions and the intent rules.
 */
object Agent {
    private const val TAG = "PhoneLink"
    private val pool = Executors.newCachedThreadPool()

    private class Fail(msg: String) : Exception(msg)

    fun handle(svc: LinkService, s: Session, m: JSONObject) {
        val rid = m.optString("rid")
        val op = m.optString("op")
        val a = m.optJSONObject("args") ?: JSONObject()
        pool.execute {
            val reply = try {
                json("t" to "agent.result", "rid" to rid, "ok" to true, "data" to run(svc, op, a))
            } catch (e: SecurityException) {
                Log.w(TAG, "agent $op: permission")
                json("t" to "agent.result", "rid" to rid, "ok" to false,
                    "error" to "Phone Link on the phone does not have the permission for this. Open Phone Link on the phone and allow access.")
            } catch (e: Throwable) {
                Log.w(TAG, "agent $op: ${e.javaClass.simpleName}")
                json("t" to "agent.result", "rid" to rid, "ok" to false, "error" to (e.message ?: e.javaClass.simpleName))
            }
            s.send(reply)
        }
    }

    private fun run(svc: LinkService, op: String, a: JSONObject): Any = when (op) {
        "status" -> status(svc)
        "sms.threads" -> threads(svc, a)
        "sms.read" -> readThread(svc, a)
        "sms.search" -> searchMessages(svc, a)
        "sms.attachment" -> Mms.part(svc, a.getLong("id")).let { json("mime" to "image/jpeg", "data" to it.opt("data")) }
        "sms.send" -> sendMessage(svc, a)
        "contacts.find" -> findContacts(svc, a)
        "contacts.get" -> contact(svc, a.getLong("id"))
        "contacts.edit" -> editContact(svc, a)
        "calendar.calendars" -> calendars(svc)
        "calendar.find" -> findEvents(svc, a)
        "calendar.edit" -> editEvent(svc, a)
        "calls.log" -> callLog(svc, a)
        "notif.list" -> notifications(svc, a)
        "notif.act" -> notificationAction(a)
        "apps.list" -> apps(svc, a)
        "apps.info" -> appInfo(svc, a.getString("package"))
        "intent.resolve" -> resolve(svc, a)
        "intent.start" -> startIntent(svc, a)
        "app.start" -> startApp(svc, a)
        "clip.get" -> readClipboard(svc)
        "clip.set" -> { Clip.apply(svc, json("text" to a.getString("text"))); json("done" to true) }
        "location.get" -> location(svc, a)
        "media.list" -> mediaList(svc, a)
        "cp.query" -> cpQuery(svc, a)
        "cp.modify" -> cpModify(svc, a)
        "screenshot" -> InputService.require().agentScreenshot(a.optInt("maxSize", 1280), a.optString("format", "jpeg") == "png", a.optInt("quality", 80), a.optInt("display", 0))
        "ui.tree" -> InputService.require().agentTree(a.optString("windows", "all"), a.optString("waitForText", ""), a.optLong("timeout", 0), a.optInt("maxNodes", 600), a.optInt("display", 0))
        "ui.act" -> InputService.require().agentAct(a)
        "notify.post" -> postNotification(svc, a)
        "settings.get" -> settings(svc)
        "settings.set" -> setSetting(svc, a)
        else -> throw Fail("Phone Link on the phone does not know the request \"$op\". Update Phone Link on the phone.")
    }

    // Time: ISO 8601 with the phone time zone out; ISO 8601 or milliseconds in.

    private fun iso(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

    private fun time(a: JSONObject, key: String): Long? {
        if (!a.has(key) || a.isNull(key)) return null
        val v = a.get(key)
        if (v is Number) return v.toLong()
        val s = v.toString().trim()
        if (s.isEmpty()) return null
        s.toLongOrNull()?.let { return it }
        return try { OffsetDateTime.parse(s).toInstant().toEpochMilli() } catch (_: Exception) {
            try { Instant.parse(s).toEpochMilli() } catch (_: Exception) {
                try { LocalDateTime.parse(s).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() } catch (_: Exception) {
                    try { LocalDate.parse(s).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli() } catch (_: Exception) {
                        throw Fail("\"$key\" is not a valid time. Use ISO 8601, for example 2026-01-31T14:00:00+01:00.")
                    }
                }
            }
        }
    }

    private fun strings(a: JSONArray?): List<String> = if (a == null) emptyList() else (0 until a.length()).map { a.optString(it) }

    private fun <T> latch(timeoutMs: Long, what: String, start: ((T) -> Unit) -> Unit): T {
        val l = CountDownLatch(1)
        var value: T? = null
        start { value = it; l.countDown() }
        if (!l.await(timeoutMs, TimeUnit.MILLISECONDS)) throw Fail("$what did not finish in ${timeoutMs / 1000} seconds.")
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    // Status

    private fun status(svc: LinkService): JSONObject {
        val o = svc.status()
        o.remove("t")
        val cm = svc.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        o.put("network", json(
            "type" to when {
                caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                else -> "other"
            },
            "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            "metered" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false),
        ))
        val tm = svc.getSystemService(TelephonyManager::class.java)
        try {
            o.put("cellular", json("carrier" to tm.networkOperatorName, "signal" to tm.signalStrength?.level, "roaming" to tm.isNetworkRoaming))
        } catch (_: Exception) {}
        try { o.put("sims", sims(svc)) } catch (_: Exception) {}
        val pm = svc.getSystemService(PowerManager::class.java)
        val km = svc.getSystemService(KeyguardManager::class.java)
        o.put("screen", json("on" to pm.isInteractive, "locked" to km.isKeyguardLocked, "powerSave" to pm.isPowerSaveMode))
        InputService.instance?.let { o.put("front", json("package" to it.frontPackage(), "activity" to it.frontClass)) }
        val st = StatFs(Environment.getDataDirectory().path)
        o.put("storage", json("total" to st.totalBytes, "free" to st.availableBytes))
        try {
            val c = Controls.state(svc)
            o.put("controls", c.optJSONObject("items"))
            o.put("volume", c.optJSONObject("volume"))
        } catch (_: Exception) {}
        o.put("media", Media.info())
        o.put("time", iso(System.currentTimeMillis()))
        o.put("timeZone", ZoneId.systemDefault().id)
        return o
    }

    private fun sims(svc: LinkService): JSONArray {
        val sm = svc.getSystemService(SubscriptionManager::class.java)
        val def = SubscriptionManager.getDefaultSmsSubscriptionId()
        return (sm.activeSubscriptionInfoList ?: emptyList()).toJsonArray {
            json("sim" to it.subscriptionId, "slot" to it.simSlotIndex + 1, "carrier" to it.carrierName?.toString(),
                "name" to it.displayName?.toString(), "defaultForSms" to (it.subscriptionId == def))
        }
    }

    // Messages

    private fun messageJson(m: JSONObject): JSONObject {
        val type = m.optInt("type")
        val out = type != 1
        val attachments = m.optJSONArray("attachments") ?: JSONArray()
        return json(
            "id" to m.getLong("id"),
            "thread" to m.optLong("thread"),
            "from" to if (out) "me" else (m.optString("name").takeIf { !m.isNull("name") && it.isNotEmpty() } ?: m.optString("address")),
            "address" to m.optString("address").ifEmpty { null },
            "text" to m.optString("body"),
            "time" to iso(m.getLong("date")),
            "status" to when (type) { 1 -> "received"; 2 -> "sent"; 4, 6 -> "sending"; 5 -> "failed"; else -> "other" },
            "read" to m.optBoolean("read", true),
            "attachments" to (0 until attachments.length()).map { attachments.getJSONObject(it) }.toJsonArray { json("id" to it.getLong("id"), "mime" to it.optString("ct")) },
        )
    }

    private fun threads(svc: LinkService, a: JSONObject): JSONArray {
        val limit = a.optInt("limit", 50).coerceIn(1, 1000)
        val unread = a.optBoolean("unreadOnly")
        val since = time(a, "since")
        val list = Mms.threads(svc).optJSONArray("threads") ?: JSONArray()
        val out = JSONArray()
        for (i in 0 until list.length()) {
            val t = list.getJSONObject(i)
            if (unread && t.optInt("unread") == 0) continue
            if (since != null && t.getLong("date") < since) continue
            val r = t.optJSONArray("recipients") ?: JSONArray()
            out.put(json(
                "id" to t.getLong("id"),
                "with" to (0 until r.length()).map { r.getJSONObject(it) }.toJsonArray { p ->
                    json("name" to if (p.isNull("name")) null else p.optString("name"), "address" to p.optString("address"))
                },
                "snippet" to t.optString("snippet"),
                "time" to iso(t.getLong("date")),
                "unread" to t.optInt("unread"),
            ))
            if (out.length() >= limit) break
        }
        return out
    }

    private fun readThread(svc: LinkService, a: JSONObject): JSONObject {
        val thread = if (a.has("thread")) a.getLong("thread") else {
            val address = a.optString("address")
            if (address.isEmpty()) throw Fail("Give \"thread\" or \"address\".")
            Telephony.Threads.getOrCreateThreadId(svc, address)
        }
        val limit = a.optInt("limit", 50).coerceIn(1, 5000)
        val before = time(a, "before")
        // Mms.messages returns the newest messages, so read more when older ones are needed.
        val list = Mms.messages(svc, thread, if (before != null) 5000 else limit).optJSONArray("messages") ?: JSONArray()
        val kept = (0 until list.length()).map { list.getJSONObject(it) }
            .filter { before == null || it.getLong("date") < before }
            .takeLast(limit)
        return json("thread" to thread, "messages" to kept.toJsonArray { messageJson(it) })
    }

    private fun searchMessages(svc: LinkService, a: JSONObject): JSONArray {
        val q = a.optString("query")
        val address = a.optString("address")
        val since = time(a, "since")
        val limit = a.optInt("limit", 50).coerceIn(1, 500)
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        if (q.isNotEmpty()) { where.add("body LIKE ?"); args.add("%$q%") }
        if (address.isNotEmpty()) {
            val digits = address.filter { it.isDigit() }.takeLast(9)
            if (digits.length >= 6) { where.add("REPLACE(REPLACE(REPLACE(address, ' ', ''), '-', ''), '+', '') LIKE ?"); args.add("%$digits") }
            else { where.add("address LIKE ?"); args.add("%$address%") }
        }
        if (since != null) { where.add("date >= ?"); args.add(since.toString()) }
        if (a.optBoolean("unreadOnly")) where.add("read = 0 AND type = 1")
        val out = ArrayList<JSONObject>()
        svc.contentResolver.query(Telephony.Sms.CONTENT_URI, Sms.COLS, where.joinToString(" AND ").ifEmpty { null },
            args.toTypedArray(), "date DESC LIMIT $limit")?.use { c ->
            while (c.moveToNext()) out.add(Sms.row(c, svc))
        }
        // MMS text is in the parts.
        if (q.isNotEmpty() && address.isEmpty()) try {
            val ids = LinkedHashSet<Long>()
            svc.contentResolver.query(Uri.parse("content://mms/part"), arrayOf("mid"), "ct = 'text/plain' AND text LIKE ?", arrayOf("%$q%"), null)?.use { c ->
                while (c.moveToNext() && ids.size < limit) ids.add(c.getLong(0))
            }
            for (id in ids) {
                svc.contentResolver.query(Uri.parse("content://mms/$id"), arrayOf("thread_id", "date"), null, null, null)?.use { c ->
                    if (c.moveToFirst() && (since == null || c.getLong(1) * 1000 >= since)) {
                        val all = Mms.messages(svc, c.getLong(0), 2000).optJSONArray("messages") ?: JSONArray()
                        for (i in 0 until all.length()) {
                            val j = all.getJSONObject(i)
                            if (j.getLong("id") == -id) out.add(j)
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        out.sortByDescending { it.getLong("date") }
        return out.take(limit).toJsonArray { messageJson(it) }
    }

    private fun sendMessage(svc: LinkService, a: JSONObject): JSONObject {
        val to = strings(a.optJSONArray("to")).filter { it.isNotBlank() }
        if (to.isEmpty()) throw Fail("Give at least one recipient in \"to\".")
        val text = a.optString("text")
        val image = if (a.isNull("image")) null else a.optString("image", "").takeIf { it.isNotEmpty() }
        if (text.isBlank() && image == null) throw Fail("Give \"text\" or an attachment.")
        val sim = if (a.has("sim") && !a.isNull("sim")) a.getInt("sim") else -1
        val r = latch<Pair<Boolean, String?>>(90_000, "Sending the message") { done ->
            if (to.size == 1 && image == null) Sms.send(svc, to[0], text, sim) { ok, err -> done(ok to err) }
            else Mms.send(svc, to, text, image, sim) { ok, err -> done(ok to err) }
        }
        if (!r.first) throw Fail(("The phone did not send the message. " + (r.second ?: "")).trim())
        return json("sent" to true, "to" to JSONArray(to), "mms" to (to.size > 1 || image != null))
    }

    // Contacts

    private val PHONE = ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE
    private val EMAIL = ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE

    private fun findContacts(svc: LinkService, a: JSONObject): JSONArray {
        val q = a.optString("query").trim()
        val limit = a.optInt("limit", 50).coerceIn(1, 2000)
        val ids = LinkedHashMap<Long, JSONObject>()
        val cr = svc.contentResolver
        val cols = arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY, ContactsContract.Contacts.STARRED)
        fun add(c: Cursor) {
            while (c.moveToNext() && ids.size < limit) {
                val id = c.getLong(0)
                if (!ids.containsKey(id)) ids[id] = json("id" to id, "name" to c.getString(1), "starred" to (c.getInt(2) != 0), "phones" to JSONArray(), "emails" to JSONArray())
            }
        }
        if (q.isEmpty()) {
            cr.query(ContactsContract.Contacts.CONTENT_URI, cols, null, null, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY + " ASC")?.use(::add)
        } else {
            cr.query(Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, Uri.encode(q)), cols, null, null, null)?.use(::add)
            if (q.count { it.isDigit() } >= 3) {
                cr.query(Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(q)),
                    arrayOf(ContactsContract.PhoneLookup.CONTACT_ID, ContactsContract.PhoneLookup.DISPLAY_NAME, ContactsContract.PhoneLookup.STARRED), null, null, null)?.use(::add)
            }
            if (q.contains('@')) {
                cr.query(Uri.withAppendedPath(ContactsContract.CommonDataKinds.Email.CONTENT_FILTER_URI, Uri.encode(q)),
                    arrayOf(ContactsContract.CommonDataKinds.Email.CONTACT_ID, ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY, ContactsContract.CommonDataKinds.Email.STARRED), null, null, null)?.use(::add)
            }
        }
        if (ids.isEmpty()) return JSONArray()
        cr.query(ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.Data.CONTACT_ID, ContactsContract.Data.MIMETYPE, ContactsContract.Data.DATA1, ContactsContract.Data.DATA2, ContactsContract.Data.DATA3),
            ContactsContract.Data.CONTACT_ID + " IN (" + ids.keys.joinToString(",") + ") AND " + ContactsContract.Data.MIMETYPE + " IN (?, ?)",
            arrayOf(PHONE, EMAIL), null)?.use { c ->
            while (c.moveToNext()) {
                val o = ids[c.getLong(0)] ?: continue
                val v = c.getString(2) ?: continue
                val phone = c.getString(1) == PHONE
                val label = if (phone) ContactsContract.CommonDataKinds.Phone.getTypeLabel(svc.resources, c.getInt(3), c.getString(4))
                            else ContactsContract.CommonDataKinds.Email.getTypeLabel(svc.resources, c.getInt(3), c.getString(4))
                val arr = o.getJSONArray(if (phone) "phones" else "emails")
                if ((0 until arr.length()).none { arr.getJSONObject(it).optString("value") == v }) arr.put(json("value" to v, "label" to label.toString()))
            }
        }
        return ids.values.toList().toJsonArray { it }
    }

    private fun contact(svc: LinkService, id: Long): JSONObject {
        val cr = svc.contentResolver
        val o = JSONObject()
        val found = cr.query(ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, id),
            arrayOf(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY, ContactsContract.Contacts.STARRED), null, null, null)?.use { c ->
            if (c.moveToFirst()) { o.put("id", id); o.put("name", c.getString(0)); o.put("starred", c.getInt(1) != 0); true } else false
        } ?: false
        if (!found) throw Fail("No contact has the id $id.")
        val lists = LinkedHashMap<String, JSONArray>()
        fun put(k: String, v: Any) { lists.getOrPut(k) { JSONArray() }.put(v) }
        val res = svc.resources
        cr.query(ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.Data.MIMETYPE, "data1", "data2", "data3", "data4"),
            ContactsContract.Data.CONTACT_ID + " = ?", arrayOf(id.toString()), null)?.use { c ->
            while (c.moveToNext()) {
                val d1 = c.getString(1)
                when (c.getString(0)) {
                    PHONE -> put("phones", json("value" to d1, "label" to ContactsContract.CommonDataKinds.Phone.getTypeLabel(res, c.getInt(2), c.getString(3)).toString()))
                    EMAIL -> put("emails", json("value" to d1, "label" to ContactsContract.CommonDataKinds.Email.getTypeLabel(res, c.getInt(2), c.getString(3)).toString()))
                    ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE -> o.put("given", c.getString(2)).put("family", c.getString(3))
                    ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE ->
                        put("addresses", json("value" to d1, "label" to ContactsContract.CommonDataKinds.StructuredPostal.getTypeLabel(res, c.getInt(2), c.getString(3)).toString()))
                    ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE -> o.put("organization", d1).put("title", c.getString(4))
                    ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE -> if (!d1.isNullOrEmpty()) o.put("note", d1)
                    ContactsContract.CommonDataKinds.Website.CONTENT_ITEM_TYPE -> put("websites", d1 ?: "")
                    ContactsContract.CommonDataKinds.Nickname.CONTENT_ITEM_TYPE -> o.put("nickname", d1)
                    ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE ->
                        put("dates", json("value" to d1, "label" to if (c.getInt(2) == ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY) "Birthday" else (c.getString(3) ?: "Date")))
                }
            }
        }
        lists.forEach { (k, v) -> o.put(k, v) }
        val accounts = JSONArray()
        cr.query(ContactsContract.RawContacts.CONTENT_URI, arrayOf(ContactsContract.RawContacts.ACCOUNT_TYPE, ContactsContract.RawContacts.ACCOUNT_NAME),
            ContactsContract.RawContacts.CONTACT_ID + " = ?", arrayOf(id.toString()), null)?.use { c ->
            while (c.moveToNext()) accounts.put(json("type" to c.getString(0), "name" to c.getString(1)))
        }
        o.put("accounts", accounts)
        return o
    }

    private fun phoneType(label: String) = when (label.lowercase()) {
        "mobile", "cell", "" -> ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE
        "home" -> ContactsContract.CommonDataKinds.Phone.TYPE_HOME
        "work" -> ContactsContract.CommonDataKinds.Phone.TYPE_WORK
        "main" -> ContactsContract.CommonDataKinds.Phone.TYPE_MAIN
        "other" -> ContactsContract.CommonDataKinds.Phone.TYPE_OTHER
        else -> ContactsContract.CommonDataKinds.Phone.TYPE_CUSTOM
    }

    private fun emailType(label: String) = when (label.lowercase()) {
        "home", "" -> ContactsContract.CommonDataKinds.Email.TYPE_HOME
        "work" -> ContactsContract.CommonDataKinds.Email.TYPE_WORK
        "mobile" -> ContactsContract.CommonDataKinds.Email.TYPE_MOBILE
        "other" -> ContactsContract.CommonDataKinds.Email.TYPE_OTHER
        else -> ContactsContract.CommonDataKinds.Email.TYPE_CUSTOM
    }

    /** Items are strings or {"value", "label"}. */
    private fun items(a: JSONArray?): List<Pair<String, String>> = if (a == null) emptyList() else (0 until a.length()).mapNotNull {
        when (val v = a.get(it)) {
            is JSONObject -> v.optString("value").takeIf { s -> s.isNotBlank() }?.let { s -> s to v.optString("label") }
            else -> v.toString().takeIf { s -> s.isNotBlank() }?.let { s -> s to "" }
        }
    }

    /** The cloud account with the most contacts (Google first), or null when all contacts are local. */
    private fun usualAccount(svc: LinkService): Pair<String?, String?>? {
        val counts = HashMap<Pair<String, String>, Int>()
        svc.contentResolver.query(ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(ContactsContract.RawContacts.ACCOUNT_TYPE, ContactsContract.RawContacts.ACCOUNT_NAME),
            ContactsContract.RawContacts.DELETED + " = 0", null, null)?.use { c ->
            while (c.moveToNext()) {
                val type = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                if (type.contains("sim", true) || type == "vnd.sec.contact.phone") continue
                counts.merge(type to name, 1, Int::plus)
            }
        }
        return counts.entries.sortedWith(compareByDescending<Map.Entry<Pair<String, String>, Int>> { it.key.first == "com.google" }
            .thenByDescending { it.value }).firstOrNull()?.key
    }

    private fun editContact(svc: LinkService, a: JSONObject): JSONObject {
        val cr = svc.contentResolver
        val action = a.optString("action")
        if (action == "delete") {
            val id = a.getLong("id")
            val n = cr.delete(ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, id), null, null)
            if (n == 0) throw Fail("No contact has the id $id.")
            return json("deleted" to id)
        }
        val ops = ArrayList<ContentProviderOperation>()
        var raw: Long = -1
        var account: Pair<String?, String?> = a.optString("accountType").ifEmpty { null } to a.optString("accountName").ifEmpty { null }
        if (action == "create") {
            // Android 16 can refuse new contacts in the local account when the default account is in the cloud.
            if (account.first == null) usualAccount(svc)?.let { account = it }
            ops.add(ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
                .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, account.first)
                .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, account.second).build())
        } else if (action == "update") {
            val id = a.getLong("id")
            cr.query(ContactsContract.RawContacts.CONTENT_URI, arrayOf(ContactsContract.RawContacts._ID),
                ContactsContract.RawContacts.CONTACT_ID + " = ?", arrayOf(id.toString()), null)?.use { c -> if (c.moveToFirst()) raw = c.getLong(0) }
            if (raw < 0) throw Fail("No contact has the id $id.")
        } else throw Fail("\"action\" must be create, update or delete.")

        fun insert(mime: String, vararg values: Pair<String, Any?>) {
            val b = ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
            if (raw < 0) b.withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0) else b.withValue(ContactsContract.Data.RAW_CONTACT_ID, raw)
            b.withValue(ContactsContract.Data.MIMETYPE, mime)
            values.forEach { (k, v) -> b.withValue(k, v) }
            ops.add(b.build())
        }
        fun clear(mime: String) {
            if (raw < 0) return
            ops.add(ContentProviderOperation.newDelete(ContactsContract.Data.CONTENT_URI)
                .withSelection(ContactsContract.Data.RAW_CONTACT_ID + " = ? AND " + ContactsContract.Data.MIMETYPE + " = ?", arrayOf(raw.toString(), mime)).build())
        }
        if (a.has("name") || a.has("given") || a.has("family")) {
            clear(ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
            insert(ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
                ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME to a.optString("name").ifEmpty { null },
                ContactsContract.CommonDataKinds.StructuredName.GIVEN_NAME to a.optString("given").ifEmpty { null },
                ContactsContract.CommonDataKinds.StructuredName.FAMILY_NAME to a.optString("family").ifEmpty { null })
        } else if (action == "create") throw Fail("Give \"name\" for the new contact.")
        if (a.has("phones")) {
            clear(PHONE)
            items(a.optJSONArray("phones")).forEach { (v, l) ->
                insert(PHONE, ContactsContract.CommonDataKinds.Phone.NUMBER to v, ContactsContract.CommonDataKinds.Phone.TYPE to phoneType(l),
                    ContactsContract.CommonDataKinds.Phone.LABEL to l.ifEmpty { null })
            }
        }
        if (a.has("emails")) {
            clear(EMAIL)
            items(a.optJSONArray("emails")).forEach { (v, l) ->
                insert(EMAIL, ContactsContract.CommonDataKinds.Email.ADDRESS to v, ContactsContract.CommonDataKinds.Email.TYPE to emailType(l),
                    ContactsContract.CommonDataKinds.Email.LABEL to l.ifEmpty { null })
            }
        }
        if (a.has("organization") || a.has("title")) {
            clear(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
            insert(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE,
                ContactsContract.CommonDataKinds.Organization.COMPANY to a.optString("organization").ifEmpty { null },
                ContactsContract.CommonDataKinds.Organization.TITLE to a.optString("title").ifEmpty { null })
        }
        if (a.has("note")) {
            clear(ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE)
            insert(ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE, ContactsContract.CommonDataKinds.Note.NOTE to a.optString("note"))
        }
        if (a.has("addresses")) {
            clear(ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE)
            items(a.optJSONArray("addresses")).forEach { (v, l) ->
                insert(ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_ITEM_TYPE,
                    ContactsContract.CommonDataKinds.StructuredPostal.FORMATTED_ADDRESS to v,
                    ContactsContract.CommonDataKinds.StructuredPostal.TYPE to if (l.lowercase() == "work") ContactsContract.CommonDataKinds.StructuredPostal.TYPE_WORK else ContactsContract.CommonDataKinds.StructuredPostal.TYPE_HOME)
            }
        }
        if (a.has("birthday")) {
            clear(ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE)
            a.optString("birthday").takeIf { it.isNotBlank() }?.let {
                insert(ContactsContract.CommonDataKinds.Event.CONTENT_ITEM_TYPE, ContactsContract.CommonDataKinds.Event.START_DATE to it,
                    ContactsContract.CommonDataKinds.Event.TYPE to ContactsContract.CommonDataKinds.Event.TYPE_BIRTHDAY)
            }
        }
        val results = cr.applyBatch(ContactsContract.AUTHORITY, ops)
        val rawId = if (raw >= 0) raw else ContentUris.parseId(results[0].uri!!)
        if (a.has("starred")) {
            cr.update(ContentUris.withAppendedId(ContactsContract.RawContacts.CONTENT_URI, rawId),
                ContentValues().apply { put(ContactsContract.RawContacts.STARRED, if (a.optBoolean("starred")) 1 else 0) }, null, null)
        }
        var contactId = -1L
        cr.query(ContentUris.withAppendedId(ContactsContract.RawContacts.CONTENT_URI, rawId), arrayOf(ContactsContract.RawContacts.CONTACT_ID), null, null, null)?.use { c ->
            if (c.moveToFirst()) contactId = c.getLong(0)
        }
        return if (contactId >= 0) contact(svc, contactId) else json("rawId" to rawId)
    }

    // Calendar

    private fun calendars(svc: LinkService): JSONArray {
        val out = JSONArray()
        svc.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, arrayOf(
            CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.VISIBLE, CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.CALENDAR_TIME_ZONE), null, null, null)?.use { c ->
            while (c.moveToNext()) out.put(json(
                "id" to c.getLong(0), "name" to c.getString(1), "account" to c.getString(2),
                "writable" to (c.getInt(3) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR), "visible" to (c.getInt(4) != 0),
                "primary" to (c.getInt(5) != 0), "timeZone" to c.getString(6),
            ))
        }
        return out
    }

    private fun day(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.of("UTC")).toLocalDate().toString()

    private fun findEvents(svc: LinkService, a: JSONObject): JSONArray {
        val now = System.currentTimeMillis()
        val from = time(a, "from") ?: (now - 86_400_000L)
        val to = time(a, "to") ?: (from + 14 * 86_400_000L)
        val q = a.optString("query")
        val limit = a.optInt("limit", 100).coerceIn(1, 2000)
        val uri = (if (q.isEmpty()) CalendarContract.Instances.CONTENT_URI else CalendarContract.Instances.CONTENT_SEARCH_URI).buildUpon().apply {
            ContentUris.appendId(this, from)
            ContentUris.appendId(this, to)
            if (q.isNotEmpty()) appendPath(q)
        }.build()
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        if (a.has("calendar")) { where.add(CalendarContract.Instances.CALENDAR_ID + " = ?"); args.add(a.getLong("calendar").toString()) }
        val out = JSONArray()
        svc.contentResolver.query(uri, arrayOf(
            CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME, CalendarContract.Instances.RRULE, CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.ORGANIZER),
            where.joinToString(" AND ").ifEmpty { null }, args.toTypedArray(), CalendarContract.Instances.BEGIN + " ASC")?.use { c ->
            while (c.moveToNext() && out.length() < limit) {
                // All-day events are stored at midnight UTC.
                val allDay = c.getInt(4) != 0
                out.put(json(
                    "id" to c.getLong(0), "title" to c.getString(1),
                    "start" to if (allDay) day(c.getLong(2)) else iso(c.getLong(2)),
                    "end" to if (allDay) day(c.getLong(3)) else iso(c.getLong(3)),
                    "allDay" to allDay, "location" to c.getString(5)?.ifEmpty { null },
                    "description" to c.getString(6)?.ifEmpty { null }?.take(2000),
                    "calendar" to c.getString(7), "calendarId" to c.getLong(9),
                    "repeats" to c.getString(8)?.ifEmpty { null }, "organizer" to c.getString(10),
                ))
            }
        }
        return out
    }

    private fun editEvent(svc: LinkService, a: JSONObject): JSONObject {
        val cr = svc.contentResolver
        when (val action = a.optString("action")) {
            "delete" -> {
                val id = a.getLong("id")
                if (cr.delete(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), null, null) == 0) throw Fail("No event has the id $id.")
                return json("deleted" to id)
            }
            "create", "update" -> {
                val v = ContentValues()
                val allDay = a.optBoolean("allDay")
                var start = time(a, "start")
                var end = time(a, "end")
                if (allDay) {
                    // All-day events start and end at midnight UTC.
                    fun utcDay(key: String): Long? = a.optString(key).takeIf { it.isNotEmpty() }?.let {
                        LocalDate.parse(it.take(10)).atStartOfDay(ZoneId.of("UTC")).toInstant().toEpochMilli()
                    }
                    start = utcDay("start")
                    end = utcDay("end") ?: start?.plus(86_400_000L)
                    v.put(CalendarContract.Events.ALL_DAY, 1)
                    v.put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
                } else if (a.has("allDay")) v.put(CalendarContract.Events.ALL_DAY, 0)
                if (start != null) v.put(CalendarContract.Events.DTSTART, start)
                if (a.has("title")) v.put(CalendarContract.Events.TITLE, a.optString("title"))
                if (a.has("location")) v.put(CalendarContract.Events.EVENT_LOCATION, a.optString("location"))
                if (a.has("description")) v.put(CalendarContract.Events.DESCRIPTION, a.optString("description"))
                val rrule = a.optString("repeat").ifEmpty { null }
                if (rrule != null) {
                    v.put(CalendarContract.Events.RRULE, rrule)
                    v.put(CalendarContract.Events.DURATION, repeatDuration(cr, action, a, start, end))
                    v.putNull(CalendarContract.Events.DTEND)
                } else if (end != null) v.put(CalendarContract.Events.DTEND, end)
                if (!allDay && (action == "create" || a.has("timeZone"))) v.put(CalendarContract.Events.EVENT_TIMEZONE, a.optString("timeZone").ifEmpty { ZoneId.systemDefault().id })
                val id: Long
                if (action == "create") {
                    if (start == null) throw Fail("Give \"start\" for the new event.")
                    if (rrule == null && end == null) v.put(CalendarContract.Events.DTEND, start + 3_600_000L)
                    v.put(CalendarContract.Events.CALENDAR_ID, if (a.has("calendar")) a.getLong("calendar") else defaultCalendar(svc))
                    id = ContentUris.parseId(cr.insert(CalendarContract.Events.CONTENT_URI, v) ?: throw Fail("The calendar did not save the event."))
                } else {
                    id = a.getLong("id")
                    if (cr.update(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), v, null, null) == 0) throw Fail("No event has the id $id.")
                }
                if (a.has("reminders")) {
                    cr.delete(CalendarContract.Reminders.CONTENT_URI, CalendarContract.Reminders.EVENT_ID + " = ?", arrayOf(id.toString()))
                    val r = a.optJSONArray("reminders") ?: JSONArray()
                    for (i in 0 until r.length()) cr.insert(CalendarContract.Reminders.CONTENT_URI, ContentValues().apply {
                        put(CalendarContract.Reminders.EVENT_ID, id)
                        put(CalendarContract.Reminders.MINUTES, r.getInt(i))
                        put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                    })
                }
                return json("id" to id, "saved" to true)
            }
            else -> throw Fail("\"action\" must be create, update or delete, not \"$action\".")
        }
    }

    /** A repeating event needs a DURATION. On update, missing times come from the saved event. */
    private fun repeatDuration(cr: ContentResolver, action: String, a: JSONObject, start: Long?, end: Long?): String {
        var oldStart: Long? = null
        var oldDuration: String? = null
        if (action == "update") {
            cr.query(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, a.getLong("id")),
                arrayOf(CalendarContract.Events.DTSTART, CalendarContract.Events.DTEND, CalendarContract.Events.DURATION), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    if (!c.isNull(0)) oldStart = c.getLong(0)
                    oldDuration = c.getString(2) ?: if (!c.isNull(0) && !c.isNull(1)) "P" + (c.getLong(1) - c.getLong(0)) / 1000 + "S" else null
                }
            }
        }
        val s = start ?: oldStart
        if (end != null && s != null) return "P" + (end - s) / 1000 + "S"
        return oldDuration ?: "PT1H"
    }

    private fun defaultCalendar(svc: LinkService): Long {
        var best = -1L
        svc.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY),
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL + " >= " + CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR + " AND " + CalendarContract.Calendars.VISIBLE + " = 1",
            null, CalendarContract.Calendars.IS_PRIMARY + " DESC")?.use { c -> if (c.moveToFirst()) best = c.getLong(0) }
        if (best < 0) throw Fail("The phone has no calendar that can be changed.")
        return best
    }

    // Calls

    private fun callLog(svc: LinkService, a: JSONObject): JSONArray {
        val limit = a.optInt("limit", 50).coerceIn(1, 1000)
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        when (a.optString("type")) {
            "incoming" -> where.add(CallLog.Calls.TYPE + " = " + CallLog.Calls.INCOMING_TYPE)
            "outgoing" -> where.add(CallLog.Calls.TYPE + " = " + CallLog.Calls.OUTGOING_TYPE)
            "missed" -> where.add(CallLog.Calls.TYPE + " IN (" + CallLog.Calls.MISSED_TYPE + ", " + CallLog.Calls.REJECTED_TYPE + ")")
        }
        val number = a.optString("number").filter { it.isDigit() }.takeLast(9)
        if (number.isNotEmpty()) { where.add(CallLog.Calls.NUMBER + " LIKE ?"); args.add("%$number") }
        time(a, "since")?.let { where.add(CallLog.Calls.DATE + " >= ?"); args.add(it.toString()) }
        val uri = CallLog.Calls.CONTENT_URI.buildUpon().appendQueryParameter("limit", limit.toString()).build()
        val out = JSONArray()
        svc.contentResolver.query(uri, arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            where.joinToString(" AND ").ifEmpty { null }, args.toTypedArray(), CallLog.Calls.DATE + " DESC")?.use { c ->
            while (c.moveToNext() && out.length() < limit) {
                val n = c.getString(1) ?: ""
                out.put(json(
                    "id" to c.getLong(0), "number" to n,
                    "name" to (c.getString(2)?.takeIf { it.isNotBlank() } ?: Contacts.name(svc, n)),
                    "type" to when (c.getInt(3)) { 1 -> "incoming"; 2 -> "outgoing"; 3 -> "missed"; 4 -> "voicemail"; 5 -> "declined"; 6 -> "blocked"; else -> "other" },
                    "time" to iso(c.getLong(4)), "seconds" to c.getLong(5),
                ))
            }
        }
        return out
    }

    // Notifications

    private fun listener(): NotifListener = NotifListener.instance
        ?: throw Fail("Notification access is off. On the phone, allow notification access for Phone Link.")

    private fun notifications(svc: LinkService, a: JSONObject): JSONArray {
        val app = a.optString("app").lowercase()
        val since = time(a, "since")
        val limit = a.optInt("limit", 100).coerceIn(1, 1000)
        val out = JSONArray()
        fun add(n: JSONObject) {
            n.remove("icon")
            n.put("time", iso(n.optLong("time")))
            n.optJSONArray("messages")?.let { m -> for (k in 0 until m.length()) m.getJSONObject(k).let { it.put("time", iso(it.optLong("time"))) } }
            out.put(n)
        }
        if (a.optBoolean("history")) {
            if (!NotifHistory.isOn(svc)) throw Fail("The notification history is off. The user can turn it on in Phone Link Settings > Agents on the Mac.")
            NotifHistory.query(svc, app, since, limit).forEach { add(it) }
            return out
        }
        listener()
        val list = NotifListener.activeJson(null, a.optBoolean("all"), agent = true)
        for (i in list.length() - 1 downTo 0) {
            val n = list.getJSONObject(i)
            if (!NotifHistory.isFromApp(n, app)) continue
            if (since != null && n.optLong("time") < since) continue
            add(n)
            if (out.length() >= limit) break
        }
        return out
    }

    private fun notificationAction(a: JSONObject): JSONObject {
        val l = listener()
        val key = a.getString("key")
        val sbn = l.activeNotifications.orEmpty().firstOrNull { it.key == key } ?: throw Fail("No notification has this key. It was removed.")
        val acts = sbn.notification.actions.orEmpty()
        when (val action = a.optString("action")) {
            "dismiss" -> l.dismiss(key)
            "open" -> l.open(key, a.optInt("display", Display.DEFAULT_DISPLAY))
            "action" -> {
                val i = a.optInt("index", -1)
                val title = a.optString("title")
                val idx = if (i >= 0) i else acts.indexOfFirst { it.title?.toString().equals(title, true) }
                if (idx !in acts.indices) throw Fail("This notification has no such action.")
                l.action(key, idx, if (a.has("text")) a.optString("text") else null)
            }
            "reply" -> {
                val idx = acts.indexOfFirst { it.remoteInputs?.any { r -> r.allowFreeFormInput } == true }
                if (idx < 0) throw Fail("This notification has no reply action.")
                l.action(key, idx, a.getString("text"))
            }
            else -> throw Fail("\"action\" must be dismiss, open, action or reply, not \"$action\".")
        }
        return json("done" to true)
    }

    // Apps and intents

    private fun apps(svc: LinkService, a: JSONObject): JSONArray {
        val pm = svc.packageManager
        val q = a.optString("query").lowercase()
        val launch = if (a.optBoolean("all")) null
            else pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), PackageManager.ResolveInfoFlags.of(0)).map { it.activityInfo.packageName }.toSet()
        val out = ArrayList<JSONObject>()
        for (ai in pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))) {
            if (launch != null && ai.packageName !in launch) continue
            val label = pm.getApplicationLabel(ai).toString()
            if (q.isNotEmpty() && !label.lowercase().contains(q) && !ai.packageName.lowercase().contains(q)) continue
            out.add(json("package" to ai.packageName, "label" to label, "system" to (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0)))
        }
        out.sortBy { it.getString("label").lowercase() }
        return out.toJsonArray { it }
    }

    /**
     * True only when the user turned off the app in Settings. Do not use ApplicationInfo.enabled: it is also false
     * for apps that Android put to sleep (DISABLED_UNTIL_USED), and those apps start normally.
     * Use it only to explain a failed start. Agents that see "disabled" in a list do not try to start the app.
     */
    private fun isDisabled(pm: PackageManager, pkg: String): Boolean = try {
        when (pm.getApplicationEnabledSetting(pkg)) {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER -> true
            else -> false
        }
    } catch (_: IllegalArgumentException) { false }

    private const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

    private fun appInfo(svc: LinkService, pkg: String): JSONObject {
        val pm = svc.packageManager
        val pi = try { pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of((PackageManager.GET_PERMISSIONS or PackageManager.GET_ACTIVITIES).toLong())) }
                 catch (_: PackageManager.NameNotFoundException) { throw Fail("No app has the package name $pkg.") }
        val ai = pi.applicationInfo ?: throw Fail("No app has the package name $pkg.")
        val perms = JSONArray()
        pi.requestedPermissions?.forEachIndexed { i, p ->
            val granted = (pi.requestedPermissionsFlags?.getOrNull(i) ?: 0) and android.content.pm.PackageInfo.REQUESTED_PERMISSION_GRANTED != 0
            perms.put(json("name" to p, "granted" to granted))
        }
        val o = json(
            "package" to pkg, "label" to pm.getApplicationLabel(ai).toString(),
            "version" to pi.versionName, "versionCode" to pi.longVersionCode,
            "installed" to iso(pi.firstInstallTime), "updated" to iso(pi.lastUpdateTime),
            "system" to (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0), "targetSdk" to ai.targetSdkVersion,
            "launch" to pm.getLaunchIntentForPackage(pkg)?.component?.flattenToShortString(),
            "permissions" to perms,
        )
        val filters = try { manifestActivities(svc, pkg) } catch (e: Exception) { Log.w(TAG, "manifest $pkg: ${e.javaClass.simpleName}"); null }
        o.put("activities", filters ?: (pi.activities ?: emptyArray()).filter { it.exported }.toList().toJsonArray { json("name" to it.name, "exported" to true) })
        return o
    }

    /** Reads the exported activities and their intent filters from the binary manifest of the app. */
    private fun manifestActivities(svc: LinkService, pkg: String): JSONArray {
        val ctx = svc.createPackageContext(pkg, Context.CONTEXT_IGNORE_SECURITY)
        val p = ctx.assets.openXmlResourceParser("AndroidManifest.xml")
        val out = JSONArray()
        var act: JSONObject? = null
        var filter: JSONObject? = null
        fun attr(n: String): String? = p.getAttributeValue(ANDROID_NS, n)
        fun add(o: JSONObject, k: String, v: String?) { if (!v.isNullOrEmpty()) (o.optJSONArray(k) ?: JSONArray().also { o.put(k, it) }).put(v) }
        try {
            while (true) {
                val e = p.next()
                if (e == XmlPullParser.END_DOCUMENT) break
                if (e == XmlPullParser.START_TAG) when (p.name) {
                    "activity", "activity-alias" -> {
                        var name = attr("name") ?: ""
                        if (name.startsWith(".")) name = pkg + name
                        act = json("name" to name, "exported" to attr("exported")?.let { it == "true" || it == "-1" }, "filters" to JSONArray())
                        attr("targetActivity")?.let { act?.put("target", it) }
                        attr("permission")?.let { act?.put("permission", it) }
                    }
                    "intent-filter" -> act?.let { filter = JSONObject(); it.getJSONArray("filters").put(filter) }
                    "action" -> filter?.let { add(it, "actions", attr("name")) }
                    "category" -> filter?.let { add(it, "categories", attr("name")) }
                    "data" -> filter?.let { f ->
                        add(f, "schemes", attr("scheme")); add(f, "hosts", attr("host"))
                        add(f, "paths", attr("path") ?: attr("pathPrefix") ?: attr("pathPattern")); add(f, "mimeTypes", attr("mimeType"))
                    }
                } else if (e == XmlPullParser.END_TAG) when (p.name) {
                    "activity", "activity-alias" -> {
                        act?.let { x ->
                            val f = x.getJSONArray("filters")
                            if (x.isNull("exported")) x.put("exported", f.length() > 0)
                            if (x.getBoolean("exported")) { if (f.length() == 0) x.remove("filters"); out.put(x) }
                        }
                        act = null
                    }
                    "intent-filter" -> filter = null
                }
            }
        } finally { p.close() }
        return out
    }

    private val FLAGS = mapOf(
        "NEW_TASK" to Intent.FLAG_ACTIVITY_NEW_TASK, "CLEAR_TOP" to Intent.FLAG_ACTIVITY_CLEAR_TOP, "CLEAR_TASK" to Intent.FLAG_ACTIVITY_CLEAR_TASK,
        "SINGLE_TOP" to Intent.FLAG_ACTIVITY_SINGLE_TOP, "NO_HISTORY" to Intent.FLAG_ACTIVITY_NO_HISTORY, "MULTIPLE_TASK" to Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
        "EXCLUDE_FROM_RECENTS" to Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS, "REORDER_TO_FRONT" to Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
        "NEW_DOCUMENT" to Intent.FLAG_ACTIVITY_NEW_DOCUMENT, "NO_ANIMATION" to Intent.FLAG_ACTIVITY_NO_ANIMATION,
    )
    private const val GRANT_FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
    @Suppress("DEPRECATION")
    private val BLOCKED = setOf(
        Intent.ACTION_CALL, "android.intent.action.CALL_PRIVILEGED", "android.intent.action.CALL_EMERGENCY",
        Intent.ACTION_DELETE, Intent.ACTION_UNINSTALL_PACKAGE, "android.intent.action.MASTER_CLEAR", "android.intent.action.FACTORY_RESET",
    )

    private fun ownUri(ctx: Context, u: Uri?): Boolean {
        if (u == null || u.scheme?.lowercase() != "content") return false
        val auth = (u.authority ?: "").lowercase().substringAfter('@')
        val pkg = ctx.packageName.lowercase()
        return auth == pkg || auth.startsWith("$pkg.")
    }

    private fun noOwn(svc: Context, u: Uri) { if (ownUri(svc, u)) throw Fail("Intents cannot point to Phone Link's own files.") }

    private fun intentOf(svc: LinkService, a: JSONObject): Intent {
        if (a.has("selector")) throw Fail("Intent selectors are not allowed.")
        val i = Intent()
        a.optString("action").ifEmpty { null }?.let { i.action = it }
        val data = a.optString("data").ifEmpty { null }?.let { Uri.parse(it) }
        val type = a.optString("type").ifEmpty { null }
        when {
            data != null && type != null -> i.setDataAndType(data, type)
            data != null -> i.data = data
            type != null -> i.type = type
        }
        strings(a.optJSONArray("categories")).forEach { i.addCategory(it) }
        a.optString("package").ifEmpty { null }?.let { i.setPackage(it) }
        a.optString("component").ifEmpty { null }?.let {
            i.component = ComponentName.unflattenFromString(it) ?: throw Fail("\"component\" must be package/class, for example com.example/.MainActivity.")
        }
        when (val f = a.opt("flags")) {
            is Number -> i.addFlags(f.toInt())
            is JSONArray -> strings(f).forEach { n ->
                i.addFlags(FLAGS[n.uppercase().removePrefix("FLAG_ACTIVITY_")] ?: throw Fail("Unknown flag $n. Known flags: " + FLAGS.keys.joinToString() + "."))
            }
        }
        when (val ex = a.opt("extras")) {
            is JSONArray -> for (k in 0 until ex.length()) {
                val e = ex.getJSONObject(k)
                putExtra(svc, i, e.getString("key"), e.optString("type", ""), e.opt("value"))
            }
            is JSONObject -> ex.keys().forEach { k -> putExtra(svc, i, k, "", ex.opt(k)) }
        }
        i.flags = i.flags and GRANT_FLAGS.inv()
        return i
    }

    private fun putExtra(svc: LinkService, i: Intent, key: String, type: String, v: Any?) {
        fun arr() = v as? JSONArray ?: throw Fail("Extra \"$key\" must be an array.")
        when (type.lowercase()) {
            "string" -> i.putExtra(key, v?.toString())
            "int" -> i.putExtra(key, (v as? Number)?.toInt() ?: v.toString().toInt())
            "long" -> i.putExtra(key, (v as? Number)?.toLong() ?: v.toString().toLong())
            "float" -> i.putExtra(key, (v as? Number)?.toFloat() ?: v.toString().toFloat())
            "double" -> i.putExtra(key, (v as? Number)?.toDouble() ?: v.toString().toDouble())
            "bool", "boolean" -> i.putExtra(key, v == true || v.toString() == "true")
            "uri" -> i.putExtra(key, Uri.parse(v.toString()).also { noOwn(svc, it) })
            "uri_list", "uri_array" -> i.putParcelableArrayListExtra(key, ArrayList(strings(arr()).map { Uri.parse(it).also { u -> noOwn(svc, u) } }))
            "string_array" -> i.putExtra(key, strings(arr()).toTypedArray())
            "string_list" -> i.putStringArrayListExtra(key, ArrayList(strings(arr())))
            "int_array" -> arr().let { x -> i.putExtra(key, IntArray(x.length()) { x.getInt(it) }) }
            "long_array" -> arr().let { x -> i.putExtra(key, LongArray(x.length()) { x.getLong(it) }) }
            "" -> when (v) {
                null, JSONObject.NULL -> i.putExtra(key, null as String?)
                is Boolean -> i.putExtra(key, v)
                is Int -> i.putExtra(key, v)
                is Long -> i.putExtra(key, v)
                is Number -> i.putExtra(key, v.toDouble())
                is JSONArray -> i.putExtra(key, strings(v).toTypedArray())
                else -> {
                    val s = v.toString()
                    if (s.startsWith("content://", true)) noOwn(svc, Uri.parse(s))
                    i.putExtra(key, s)
                }
            }
            else -> throw Fail("Unknown extra type \"$type\" for \"$key\".")
        }
    }

    private fun checkIntent(svc: LinkService, i: Intent) {
        if (i.action in BLOCKED) throw Fail("The action " + i.action + " is not allowed. To start a call, use the calls_control tool.")
        i.data?.let { noOwn(svc, it) }
        if (i.getPackage() == svc.packageName || i.component?.packageName == svc.packageName) throw Fail("Intents to Phone Link itself are not allowed.")
        val r = svc.packageManager.resolveActivity(i, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
        if (r?.activityInfo?.packageName == svc.packageName) throw Fail("Intents to Phone Link itself are not allowed.")
    }

    private fun resolveJson(svc: LinkService, r: ResolveInfo): JSONObject {
        val pm = svc.packageManager
        val f = r.filter
        return json(
            "component" to ComponentName(r.activityInfo.packageName, r.activityInfo.name).flattenToShortString(),
            "app" to pm.getApplicationLabel(r.activityInfo.applicationInfo).toString(),
            "label" to r.loadLabel(pm).toString(),
            "default" to r.isDefault,
            "filter" to f?.let { flt ->
                json("actions" to (0 until flt.countActions()).map { flt.getAction(it) }.toJsonArray { it },
                    "categories" to (0 until flt.countCategories()).map { flt.getCategory(it) }.toJsonArray { it },
                    "schemes" to (0 until flt.countDataSchemes()).map { flt.getDataScheme(it) }.toJsonArray { it },
                    "mimeTypes" to (0 until flt.countDataTypes()).map { flt.getDataType(it) }.toJsonArray { it })
            },
        )
    }

    private fun resolve(svc: LinkService, a: JSONObject): JSONObject {
        val i = intentOf(svc, a)
        val pm = svc.packageManager
        val list = pm.queryIntentActivities(i, PackageManager.ResolveInfoFlags.of((PackageManager.MATCH_DEFAULT_ONLY or PackageManager.GET_RESOLVED_FILTER).toLong()))
        val def = pm.resolveActivity(i, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
        return json(
            "activities" to list.toJsonArray { resolveJson(svc, it) },
            // A system resolver activity here means that the phone asks the user to choose an app.
            "opens" to def?.activityInfo?.let { ComponentName(it.packageName, it.name).flattenToShortString() },
        )
    }

    private class Waiting(val intent: Intent) {
        val done = CountDownLatch(1)
        @Volatile var result: JSONObject? = null
    }
    private val waiting = ConcurrentHashMap<String, Waiting>()
    private val ids = AtomicInteger()

    /** display: an app window on the Mac. Its virtual display stays unlocked when the phone is locked. */
    private fun launcher(svc: LinkService, display: Int = 0,
                         locked: String = "The phone is locked, and agents cannot unlock it. Give \"window\" to start the activity in an app window on the Mac. App windows work while the phone is locked."): Context {
        val pm = svc.getSystemService(PowerManager::class.java)
        val km = svc.getSystemService(KeyguardManager::class.java)
        if (display == 0 && (!pm.isInteractive || km.isKeyguardLocked)) throw Fail(locked)
        // Android lets an app start activities from the background only in some cases. A bound accessibility service is one.
        return InputService.instance ?: throw Fail("To open apps, turn on Phone Link screen control on the phone (Accessibility settings).")
    }

    private fun startIntent(svc: LinkService, a: JSONObject): JSONObject {
        val i = intentOf(svc, a)
        checkIntent(svc, i)
        val display = a.optInt("display", 0)
        val ctx = launcher(svc, display)
        if (svc.packageManager.resolveActivity(i, PackageManager.ResolveInfoFlags.of(0)) == null) throw Fail("No app on the phone can open this intent.")
        val options = displayOptions(display)
        if (!a.optBoolean("waitForResult")) {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i, options)
            return json("started" to true)
        }
        val id = "r" + ids.incrementAndGet()
        val w = Waiting(i)
        waiting[id] = w
        try {
            ctx.startActivity(Intent(svc, AgentResultActivity::class.java).putExtra("id", id).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), options)
            val ms = a.optLong("timeout", 120_000).coerceIn(1000, 600_000)
            if (!w.done.await(ms, TimeUnit.MILLISECONDS)) throw Fail("The app did not return a result in " + (ms / 1000) + " seconds.")
            return w.result ?: json("resultCode" to "canceled")
        } finally { waiting.remove(id) }
    }

    /** Opens an app. fresh (the default): on its start screen, not on the screen where the user left it. */
    private fun startApp(svc: LinkService, a: JSONObject): JSONObject {
        val pkg = a.getString("package")
        val display = a.optInt("display", 0)
        val ctx = launcher(svc, display)
        val i = svc.packageManager.getLaunchIntentForPackage(pkg)
            ?: throw Fail(if (isDisabled(svc.packageManager, pkg)) "The user turned off $pkg in the phone settings. Ask the user to turn it on."
                          else "$pkg is not installed, or it has no start screen. Use apps_read to find the package.")
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (a.optBoolean("fresh", true)) i.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
        ctx.startActivity(i, displayOptions(display))
        return json("started" to true, "package" to pkg)
    }

    private fun displayOptions(display: Int): Bundle? =
        if (display != 0) android.app.ActivityOptions.makeBasic().setLaunchDisplayId(display).toBundle() else null

    fun pending(id: String): Intent? = waiting[id]?.intent

    fun finished(id: String, code: Int, data: Intent?, error: String? = null) {
        val w = waiting[id] ?: return
        w.result = if (error != null) json("error" to error) else json(
            "resultCode" to when (code) { Activity.RESULT_OK -> "ok"; Activity.RESULT_CANCELED -> "canceled"; else -> code },
            "data" to data?.dataString,
            "type" to data?.type,
            "extras" to bundleJson(data?.extras),
        )
        w.done.countDown()
    }

    private fun bundleJson(b: Bundle?): JSONObject {
        val o = JSONObject()
        if (b == null) return o
        for (k in b.keySet()) o.put(k, valueJson(try { @Suppress("DEPRECATION") b.get(k) } catch (_: Exception) { "?" }))
        return o
    }

    private fun valueJson(v: Any?): Any = when (v) {
        null -> JSONObject.NULL
        is String, is Boolean, is Int, is Long, is Double -> v
        is Number -> v.toDouble()
        is CharSequence -> v.toString()
        is Bundle -> bundleJson(v)
        is Array<*> -> v.toList().toJsonArray { valueJson(it) }
        is Collection<*> -> v.toList().toJsonArray { valueJson(it) }
        is IntArray -> v.toList().toJsonArray { it }
        is LongArray -> v.toList().toJsonArray { it }
        is ByteArray -> json("bytes" to v.size)
        else -> v.toString()
    }

    // Clipboard

    @Volatile private var clipWait: CountDownLatch? = null
    @Volatile private var clipValue: JSONObject? = null

    // One read at a time: AgentClipActivity reports to the latch of the last request.
    @Synchronized private fun readClipboard(svc: LinkService): JSONObject {
        val ctx = launcher(svc, locked = "The phone is locked. Android lets Phone Link read the clipboard only when the phone is unlocked.")
        val l = CountDownLatch(1)
        clipValue = null
        clipWait = l
        ctx.startActivity(Intent(svc, AgentClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION))
        if (!l.await(5, TimeUnit.SECONDS)) throw Fail("The phone did not give the clipboard.")
        return clipValue ?: json("empty" to true)
    }

    fun clipRead(ctx: Context) {
        clipValue = try { Clip.read(ctx)?.also { it.remove("t") } } catch (_: Exception) { null }
        clipWait?.countDown()
    }

    // Location

    @Suppress("MissingPermission")
    private fun location(svc: LinkService, a: JSONObject): JSONObject {
        val lm = svc.getSystemService(LocationManager::class.java)
        if (!lm.isLocationEnabled) throw Fail("Location is off on the phone.")
        val fine = svc.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = svc.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) throw Fail("Allow Location for Phone Link on the phone. Select Allow all the time.")
        val maxAge = a.optLong("maxAge", 60_000)
        val providers = listOf(LocationManager.FUSED_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { lm.isProviderEnabled(it) }
        val last = providers.mapNotNull { try { lm.getLastKnownLocation(it) } catch (_: Exception) { null } }.maxByOrNull { it.time }
        var loc: Location? = if (last != null && System.currentTimeMillis() - last.time <= maxAge) last else null
        if (loc == null) {
            val provider = providers.firstOrNull() ?: throw Fail("No location provider is on.")
            val ms = a.optLong("timeout", 20_000).coerceIn(1000, 120_000)
            val l = CountDownLatch(1)
            val cancel = CancellationSignal()
            var got: Location? = null
            lm.getCurrentLocation(provider, cancel, svc.mainExecutor) { got = it; l.countDown() }
            if (!l.await(ms, TimeUnit.MILLISECONDS)) cancel.cancel()
            loc = got ?: last ?: throw Fail("The phone did not find its location in " + (ms / 1000) + " seconds.")
        }
        return json(
            "latitude" to loc.latitude, "longitude" to loc.longitude, "accuracy" to loc.accuracy.toDouble(),
            "altitude" to if (loc.hasAltitude()) loc.altitude else null, "speed" to if (loc.hasSpeed()) loc.speed.toDouble() else null,
            "time" to iso(loc.time), "provider" to loc.provider,
        )
    }

    // Media files

    private fun mediaList(svc: LinkService, a: JSONObject): JSONArray {
        val uri = when (a.optString("kind", "images")) {
            "images", "photos" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            "videos" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            "downloads" -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            "all", "files" -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else -> throw Fail("\"kind\" must be images, videos, audio, downloads or all.")
        }
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        a.optString("query").ifEmpty { null }?.let { where.add(MediaStore.MediaColumns.DISPLAY_NAME + " LIKE ?"); args.add("%$it%") }
        a.optString("folder").ifEmpty { null }?.let { where.add(MediaStore.MediaColumns.RELATIVE_PATH + " LIKE ?"); args.add("%$it%") }
        time(a, "since")?.let { where.add(MediaStore.MediaColumns.DATE_ADDED + " >= ?"); args.add((it / 1000).toString()) }
        val q = Bundle().apply {
            putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, where.joinToString(" AND ").ifEmpty { null })
            putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args.toTypedArray())
            putStringArray(android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.MediaColumns.DATE_ADDED))
            putInt(android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION, android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, a.optInt("limit", 50).coerceIn(1, 2000))
        }
        @Suppress("DEPRECATION")
        val cols = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DURATION)
        val out = JSONArray()
        svc.contentResolver.query(uri, cols, q, null)?.use { c ->
            while (c.moveToNext()) {
                val taken = c.getLong(5)
                out.put(json(
                    "id" to c.getLong(0), "name" to c.getString(1), "path" to c.getString(2), "mime" to c.getString(3),
                    "size" to c.getLong(4), "time" to iso(if (taken > 0) taken else c.getLong(6) * 1000),
                    "width" to c.getInt(7).takeIf { it > 0 }, "height" to c.getInt(8).takeIf { it > 0 },
                    "seconds" to c.getLong(9).takeIf { it > 0 }?.let { it / 1000.0 },
                ))
            }
        }
        return out
    }

    // Content providers

    private fun checkProvider(svc: LinkService, uri: Uri) {
        if (uri.scheme?.lowercase() != "content") throw Fail("The URI must start with content://.")
        if (ownUri(svc, uri)) throw Fail("Phone Link's own content providers are not available to agents.")
    }

    private fun cpQuery(svc: LinkService, a: JSONObject): JSONObject {
        val uri = Uri.parse(a.getString("uri"))
        checkProvider(svc, uri)
        val limit = a.optInt("limit", 100).coerceIn(1, 5000)
        val proj = a.optJSONArray("projection")?.let { strings(it).toTypedArray() }
        val sel = a.optString("selection").ifEmpty { null }
        val args = a.optJSONArray("args")?.let { strings(it).toTypedArray() }
        val sort = a.optString("sort").ifEmpty { null }
        val rows = JSONArray()
        var count = 0
        var columns = JSONArray()
        val c = svc.contentResolver.query(uri, proj, sel, args, sort) ?: throw Fail("No content provider answered for $uri.")
        c.use {
            count = c.count
            columns = c.columnNames.toList().toJsonArray { it }
            while (c.moveToNext() && rows.length() < limit) {
                val o = JSONObject()
                for (i in 0 until c.columnCount) {
                    o.put(c.getColumnName(i), when (c.getType(i)) {
                        Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
                        Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                        Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                        Cursor.FIELD_TYPE_BLOB -> c.getBlob(i).let { b -> if (b.size <= 4096) json("base64" to Base64.encodeToString(b, Base64.NO_WRAP)) else json("bytes" to b.size) }
                        else -> c.getString(i)
                    })
                }
                rows.put(o)
            }
        }
        return json("columns" to columns, "count" to count, "rows" to rows)
    }

    private fun values(o: JSONObject?): ContentValues {
        val v = ContentValues()
        o?.keys()?.forEach { k ->
            when (val x = o.get(k)) {
                JSONObject.NULL -> v.putNull(k)
                is Boolean -> v.put(k, x)
                is Int -> v.put(k, x)
                is Long -> v.put(k, x)
                is Number -> v.put(k, x.toDouble())
                else -> v.put(k, x.toString())
            }
        }
        return v
    }

    private fun cpModify(svc: LinkService, a: JSONObject): JSONObject {
        val uri = Uri.parse(a.getString("uri"))
        checkProvider(svc, uri)
        val sel = a.optString("selection").ifEmpty { null }
        val args = a.optJSONArray("args")?.let { strings(it).toTypedArray() }
        val cr = svc.contentResolver
        return when (val action = a.optString("action")) {
            "insert" -> json("uri" to cr.insert(uri, values(a.optJSONObject("values")))?.toString())
            "update" -> json("rows" to cr.update(uri, values(a.optJSONObject("values")), sel, args))
            "delete" -> json("rows" to cr.delete(uri, sel, args))
            else -> throw Fail("\"action\" must be insert, update or delete, not \"$action\".")
        }
    }

    // Notifications on the phone

    private const val CHANNEL = "agent"
    private val notifyIds = AtomicInteger(5000)

    private fun postNotification(svc: LinkService, a: JSONObject): JSONObject {
        val nm = svc.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Messages from agents on your Mac", NotificationManager.IMPORTANCE_HIGH))
        }
        if (!nm.areNotificationsEnabled()) throw Fail("Notifications from Phone Link are off on the phone.")
        val id = if (a.has("id")) a.getInt("id") else notifyIds.incrementAndGet()
        val text = a.optString("text")
        val n = Notification.Builder(svc, CHANNEL)
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle(a.optString("title").ifEmpty { "Phone Link" })
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .build()
        nm.notify("agent", id, n)
        return json("id" to id)
    }

    // Device settings

    private fun settings(svc: LinkService): JSONObject {
        val cr = svc.contentResolver
        val o = JSONObject()
        o.put("wifi", svc.getSystemService(WifiManager::class.java).isWifiEnabled)
        try { o.put("bluetooth", svc.getSystemService(BluetoothManager::class.java).adapter?.isEnabled) } catch (_: SecurityException) {}
        o.put("airplane", Settings.Global.getInt(cr, Settings.Global.AIRPLANE_MODE_ON, 0) != 0)
        o.put("location", svc.getSystemService(LocationManager::class.java).isLocationEnabled)
        o.put("hotspot", Hotspot.isOn(svc))
        o.put("privateWifi", PrivateWifi.json()?.let { json("on" to true, "ssid" to it.optString("ssid")) } ?: json("on" to false))
        o.put("brightness", json(
            "level" to Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS, -1),
            "auto" to (Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, 0) == 1)))
        o.put("autoRotate", Settings.System.getInt(cr, Settings.System.ACCELEROMETER_ROTATION, 0) == 1)
        o.put("screenTimeout", Settings.System.getInt(cr, Settings.System.SCREEN_OFF_TIMEOUT, 0))
        Settings.Global.getInt(cr, "mobile_data", -1).takeIf { it >= 0 }?.let { o.put("mobileData", it == 1) }
        try {
            val c = Controls.state(svc)
            c.optJSONObject("items")?.let { items -> items.keys().forEach { k -> o.put(k, items.get(k)) } }
            o.put("volume", c.optJSONObject("volume"))
        } catch (_: Exception) {}
        return o
    }

    /** The phone app changes Do Not Disturb, the flashlight, the ringer and the volume. The Mac changes the others with adb. */
    private fun setSetting(svc: LinkService, a: JSONObject): JSONObject {
        val m = when (val name = a.getString("name")) {
            "dnd", "torch" -> json("t" to "controls.set", "id" to name, "on" to a.getBoolean("on"))
            "ringer" -> json("t" to "controls.set", "id" to "ringer", "mode" to a.getString("mode"))
            "volume" -> json("t" to "volume.set", "stream" to a.optString("stream", "media"), "level" to a.getInt("level"))
            else -> throw Fail("Phone Link on the phone cannot change \"$name\".")
        }
        Controls.set(svc, m)
        return settings(svc)
    }
}

/** Starts an activity for a result and gives the result to Agent. */
class AgentResultActivity : Activity() {
    private var id: String? = null

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        id = state?.getString("id") ?: intent.getStringExtra("id")
        if (state != null) return
        val rid = id
        val target = rid?.let { Agent.pending(it) }
        if (rid == null || target == null) { finish(); return }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(target, 1)
        } catch (e: Exception) {
            Agent.finished(rid, RESULT_CANCELED, null, "The app did not start: " + e.javaClass.simpleName + ".")
            finish()
        }
    }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("id", id) }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        id?.let { Agent.finished(it, resultCode, data) }
        finish()
    }
}

/** Opens for a moment, because Android lets only the focused app read the clipboard. */
class AgentClipActivity : Activity() {
    private var done = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        Agent.clipRead(this)
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
