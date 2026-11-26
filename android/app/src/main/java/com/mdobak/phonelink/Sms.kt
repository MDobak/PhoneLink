package com.mdobak.phonelink

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** SMS from the system provider. RCS chats (Samsung Messages, Google Messages) are not in this provider. */
object Sms {
    private val SMS = Telephony.Sms.CONTENT_URI
    val COLS = arrayOf("_id", "thread_id", "address", "body", "date", "type", "read")
    private var observer: ContentObserver? = null
    private var thread: HandlerThread? = null
    @Volatile private var lastId = 0L

    fun row(c: Cursor, ctx: Context) = json(
        "id" to c.getLong(0),
        "thread" to c.getLong(1),
        "address" to (c.getString(2) ?: ""),
        "name" to Contacts.name(ctx, c.getString(2)),
        "body" to (c.getString(3) ?: ""),
        "date" to c.getLong(4),
        "type" to c.getInt(5), // 1 inbox, 2 sent, 4 outbox, 5 failed, 6 queued
        "read" to (c.getInt(6) != 0),
    )

    fun threads(ctx: Context): JSONObject {
        val seen = LinkedHashMap<Long, JSONObject>()
        val unread = HashMap<Long, Int>()
        ctx.contentResolver.query(SMS, COLS, null, null, "date DESC")?.use { c ->
            var n = 0
            while (c.moveToNext() && n++ < 20000) {
                val t = c.getLong(1)
                if (c.getInt(5) == 1 && c.getInt(6) == 0) unread[t] = (unread[t] ?: 0) + 1
                if (!seen.containsKey(t)) seen[t] = row(c, ctx)
            }
        }
        val arr = JSONArray()
        for ((t, m) in seen) {
            arr.put(json(
                "id" to t,
                "address" to m.getString("address"),
                "name" to m.opt("name"),
                "snippet" to m.getString("body"),
                "date" to m.getLong("date"),
                "unread" to (unread[t] ?: 0),
            ))
        }
        return json("t" to "sms.threads", "threads" to arr)
    }

    private val callbacks = ConcurrentHashMap<Int, (Boolean, String?) -> Unit>()
    private val nextId = AtomicInteger(1)
    private var receiver: BroadcastReceiver? = null
    private const val ACTION_SENT = "com.mdobak.phonelink.SMS_SENT"

    fun sentIntent(ctx: Context, done: (Boolean, String?) -> Unit): PendingIntent = sentIntent(ctx, register(done))

    private fun register(done: (Boolean, String?) -> Unit): Int = nextId.getAndIncrement().also { callbacks[it] = done }

    private fun sentIntent(ctx: Context, id: Int): PendingIntent {
        return PendingIntent.getBroadcast(
            ctx, id, Intent(ACTION_SENT).setPackage(ctx.packageName).putExtra("id", id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
        )
    }

    /** sim: a subscription id, or -1 for the default SIM. */
    fun send(ctx: Context, address: String, body: String, sim: Int = -1, done: (Boolean, String?) -> Unit) {
        val sm = manager(ctx, sim)
        val parts = sm.divideMessage(body)
        val id = register(done)
        val pi = sentIntent(ctx, id)
        // The system writes the message to the "sent" folder, because this app is not the default SMS app.
        try {
            if (parts.size == 1) {
                sm.sendTextMessage(address, null, body, pi, null)
            } else {
                val sent = ArrayList<PendingIntent?>(parts.size)
                repeat(parts.size - 1) { sent.add(null) }
                sent.add(pi)
                sm.sendMultipartTextMessage(address, null, parts, sent, null)
            }
        } catch (e: Exception) {
            // The system rejected it, so no sent intent will come. Tell the Mac now.
            callbacks.remove(id)
            done(false, if (e is SecurityException) "Allow Messages, contacts and calls in Phone Link on the phone." else "The phone did not accept the message.")
        }
    }

    fun manager(ctx: Context, sim: Int): SmsManager {
        val sm = ctx.getSystemService(SmsManager::class.java)
        return if (sim >= 0) sm.createForSubscriptionId(sim) else sm
    }

    private fun failure(code: Int) = when (code) {
        SmsManager.RESULT_ERROR_NO_SERVICE -> "The phone has no mobile service."
        SmsManager.RESULT_ERROR_RADIO_OFF -> "The mobile network of the phone is off."
        SmsManager.RESULT_ERROR_NULL_PDU, SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "The mobile network did not accept the message."
        else -> "Error code $code."
    }

    /** Safe to call again, for example after READ_SMS is granted. */
    fun observe(ctx: Context) {
        if (receiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    val cb = callbacks.remove(i.getIntExtra("id", -1)) ?: return
                    if (resultCode == Activity.RESULT_OK) cb(true, null) else cb(false, failure(resultCode))
                }
            }
            ctx.registerReceiver(r, IntentFilter(ACTION_SENT), Context.RECEIVER_NOT_EXPORTED)
            receiver = r
        }
        if (observer != null) return
        val ht = HandlerThread("phonelink-sms").also { it.start() }
        resetCursor(ctx)
        val o = object : ContentObserver(Handler(ht.looper)) {
            override fun onChange(selfChange: Boolean, uri: Uri?) { pushNew(ctx) }
        }
        try {
            ctx.contentResolver.registerContentObserver(Uri.parse("content://sms"), true, o)
            observer = o
            thread = ht
        } catch (_: SecurityException) {
            ht.quitSafely()
        }
    }

    fun stop(ctx: Context) {
        observer?.let { ctx.contentResolver.unregisterContentObserver(it) }
        receiver?.let { ctx.unregisterReceiver(it) }
        thread?.quitSafely()
        observer = null
        receiver = null
        thread = null
    }

    fun resetCursor(ctx: Context) {
        try {
            ctx.contentResolver.query(SMS, arrayOf("_id"), null, null, "_id DESC LIMIT 1")?.use { c ->
                if (c.moveToFirst()) lastId = maxOf(lastId, c.getLong(0))
            }
        } catch (_: SecurityException) {}
    }

    private fun pushNew(ctx: Context) {
        val s = Hub.session ?: return
        try {
            ctx.contentResolver.query(SMS, COLS, "_id > ?", arrayOf(lastId.toString()), "_id ASC")?.use { c ->
                while (c.moveToNext()) {
                    lastId = maxOf(lastId, c.getLong(0))
                    // A message from the Mac can arrive here as "outbox". The Mac loads the conversation again on "sms.sent".
                    s.send(json("t" to "sms.new", "message" to row(c, ctx)))
                }
            }
        } catch (_: SecurityException) {}
    }
}

object Contacts {
    private val cache = ConcurrentHashMap<String, String>()

    fun name(ctx: Context, number: String?): String? {
        if (number.isNullOrBlank()) return null
        cache[number]?.let { return it.ifEmpty { null } }
        var name = ""
        try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            ctx.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) name = c.getString(0) ?: ""
            }
        } catch (_: Exception) {}
        cache[number] = name
        return name.ifEmpty { null }
    }

    fun all(ctx: Context): JSONObject {
        val arr = JSONArray()
        // A contact in several accounts has one row per account. Dedupe by contact and the last 9 digits.
        val seen = HashSet<String>()
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE, ContactsContract.CommonDataKinds.Phone.STARRED,
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID),
            null, null, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val digits = (c.getString(1) ?: "").filter { it.isDigit() }.takeLast(9)
                if (!seen.add(c.getLong(4).toString() + "|" + digits)) continue
                arr.put(json("name" to c.getString(0), "number" to c.getString(1),
                    "label" to ContactsContract.CommonDataKinds.Phone.getTypeLabel(ctx.resources, c.getInt(2), "").toString(),
                    "starred" to (c.getInt(3) != 0)))
            }
        }
        return json("t" to "contacts", "items" to arr)
    }
}
