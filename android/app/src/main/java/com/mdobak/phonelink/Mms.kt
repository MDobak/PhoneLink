package com.mdobak.phonelink

import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.telephony.SmsManager
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/** MMS ids are negative so they do not collide with SMS ids. */
object Mms {
    private val SMS: Uri = android.provider.Telephony.Sms.CONTENT_URI
    private val MMS = Uri.parse("content://mms")
    private val PART = Uri.parse("content://mms/part")
    private var observer: ContentObserver? = null
    private var thread: HandlerThread? = null
    @Volatile private var lastId = 0L

    fun threads(ctx: Context): JSONObject = try { conversations(ctx) } catch (e: Exception) {
        android.util.Log.w("PhoneLink", "conversations failed, using SMS only", e)
        Sms.threads(ctx)
    }

    private fun conversations(ctx: Context): JSONObject {
        val cr = ctx.contentResolver
        val addresses = HashMap<String, String>()
        cr.query(Uri.parse("content://mms-sms/canonical-addresses"), arrayOf("_id", "address"), null, null, null)?.use { c ->
            while (c.moveToNext()) addresses[c.getString(0)] = c.getString(1) ?: ""
        }
        val unread = HashMap<Long, Int>()
        cr.query(SMS, arrayOf("thread_id"), "read = 0 AND type = 1", null, null)?.use { c ->
            while (c.moveToNext()) unread.merge(c.getLong(0), 1, Int::plus)
        }
        try {
            cr.query(MMS, arrayOf("thread_id"), "read = 0 AND msg_box = 1", null, null)?.use { c ->
                while (c.moveToNext()) unread.merge(c.getLong(0), 1, Int::plus)
            }
        } catch (_: Exception) {}
        val arr = JSONArray()
        cr.query(
            Uri.parse("content://mms-sms/conversations?simple=true"),
            arrayOf("_id", "date", "recipient_ids", "snippet", "has_attachment", "message_count"), null, null, "date DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(5) == 0) continue
                val id = c.getLong(0)
                val recips = JSONArray()
                (c.getString(2) ?: "").split(' ').filter { it.isNotBlank() }.forEach { rid ->
                    val a = addresses[rid] ?: return@forEach
                    recips.put(json("address" to a, "name" to Contacts.name(ctx, a)))
                }
                if (recips.length() == 0) continue
                val first = recips.getJSONObject(0)
                val names = (0 until recips.length()).map { i ->
                    val r = recips.getJSONObject(i)
                    if (r.isNull("name")) r.getString("address") else r.getString("name")
                }
                var snippet = c.getString(3) ?: ""
                if (snippet.isBlank() && c.getInt(4) != 0) snippet = "Picture"
                arr.put(json(
                    "id" to id,
                    "address" to first.getString("address"),
                    "name" to if (recips.length() > 1) names.joinToString(", ") else first.opt("name"),
                    "snippet" to snippet,
                    "date" to c.getLong(1),
                    "unread" to (unread[id] ?: 0),
                    "recipients" to recips,
                ))
            }
        }
        return json("t" to "sms.threads", "threads" to arr)
    }

    fun messages(ctx: Context, thread: Long, maxCount: Int): JSONObject {
        val limit = maxCount.coerceIn(1, 5000)
        val list = ArrayList<JSONObject>()
        ctx.contentResolver.query(SMS, Sms.COLS, "thread_id = ?", arrayOf(thread.toString()), "date DESC LIMIT " + limit)?.use { c ->
            while (c.moveToNext()) list.add(Sms.row(c, ctx))
        }
        try {
            ctx.contentResolver.query(MMS, MMS_COLS, "thread_id = ? AND m_type IN (128, 132)", arrayOf(thread.toString()), "date DESC LIMIT " + limit)?.use { c ->
                while (c.moveToNext()) list.add(mmsRow(ctx, c))
            }
        } catch (_: Exception) {}
        list.sortBy { it.getLong("date") }
        val trimmed = if (list.size > limit) list.subList(list.size - limit, list.size) else list
        return json("t" to "sms.messages", "thread" to thread, "messages" to trimmed.toJsonArray { it })
    }

    private val MMS_COLS = arrayOf("_id", "thread_id", "date", "msg_box", "read", "sub")

    private fun mmsRow(ctx: Context, c: android.database.Cursor): JSONObject {
        val id = c.getLong(0)
        val box = c.getInt(3)
        val text = StringBuilder()
        val attachments = JSONArray()
        ctx.contentResolver.query(PART, arrayOf("_id", "ct", "text"), "mid = ?", arrayOf(id.toString()), null)?.use { p ->
            while (p.moveToNext()) {
                val ct = p.getString(1) ?: continue
                when {
                    ct == "text/plain" -> {
                        val t = p.getString(2) ?: readPartText(ctx, p.getLong(0))
                        if (!t.isNullOrEmpty()) { if (text.isNotEmpty()) text.append('\n'); text.append(t) }
                    }
                    ct.startsWith("image/") -> attachments.put(json("id" to p.getLong(0), "ct" to ct))
                }
            }
        }
        if (text.isEmpty()) c.getString(5)?.let { text.append(it) }
        val from = if (box == 1) sender(ctx, id) else null
        return json(
            "id" to -id,
            "thread" to c.getLong(1),
            "address" to (from ?: ""),
            "name" to Contacts.name(ctx, from),
            "body" to text.toString(),
            "date" to c.getLong(2) * 1000,
            "type" to box, // 1 inbox, 2 sent, 4 outbox, 5 failed
            "read" to (c.getInt(4) != 0),
            "attachments" to attachments,
        )
    }

    private fun readPartText(ctx: Context, partId: Long): String? = try {
        ctx.contentResolver.openInputStream(Uri.parse("content://mms/part/" + partId))?.use { String(it.readBytes()) }
    } catch (_: Exception) { null }

    private fun sender(ctx: Context, id: Long): String? {
        ctx.contentResolver.query(Uri.parse("content://mms/" + id + "/addr"), arrayOf("address", "type"), "type = 137", null, null)?.use { c ->
            if (c.moveToFirst()) return c.getString(0)?.takeIf { it != "insert-address-token" }
        }
        return null
    }

    /** A picture from an MMS, scaled to 1280 px, as base64 JPEG. */
    fun part(ctx: Context, id: Long): JSONObject {
        val bytes = ctx.contentResolver.openInputStream(Uri.parse("content://mms/part/" + id))?.use { it.readBytes() }
            ?: return json("t" to "mms.part", "id" to id, "data" to null)
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        var sample = 1
        while (maxOf(opts.outWidth, opts.outHeight) / (sample * 2) >= 1280) sample *= 2
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return json("t" to "mms.part", "id" to id, "data" to null)
        val out = ByteArrayOutputStream()
        scaled(bmp, 1280).compress(Bitmap.CompressFormat.JPEG, 85, out)
        return json("t" to "mms.part", "id" to id, "data" to Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP))
    }

    private fun scaled(b: Bitmap, side: Int): Bitmap {
        val s = minOf(1f, side.toFloat() / maxOf(b.width, b.height))
        return if (s < 1f) Bitmap.createScaledBitmap(b, (b.width * s).toInt().coerceAtLeast(1), (b.height * s).toInt().coerceAtLeast(1), true) else b
    }

    /** Sends an MMS to a group or with a picture (base64, any image type). */
    @Suppress("DEPRECATION")
    fun send(ctx: Context, to: List<String>, body: String, image: String?, done: (Boolean, String?) -> Unit) {
        val sm = ctx.getSystemService(SmsManager::class.java)
        val max = try { sm.carrierConfigValues.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 300 * 1024) } catch (_: Exception) { 300 * 1024 }
        val jpeg = image?.let { fitJpeg(Base64.decode(it, Base64.NO_WRAP), max - 8 * 1024) }
        if (image != null && jpeg == null) { done(false, "The picture cannot be read."); return }
        val pdu = MmsPdu.sendReq(to, body.ifBlank { null }, jpeg)
        val dir = ShareProvider.dir(ctx)
        dir.listFiles()?.filter { it.name.startsWith("mms-") && it.lastModified() < System.currentTimeMillis() - 3_600_000 }?.forEach { it.delete() }
        val f = File(dir, "mms-" + System.currentTimeMillis() + ".pdu")
        f.writeBytes(pdu)
        val uri = ShareProvider.uri(ctx, f)
        for (pkg in listOf("com.android.phone", "com.android.mms.service")) {
            try { ctx.grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Exception) {}
        }
        sm.sendMultimediaMessage(ctx, uri, null, null, Sms.sentIntent(ctx, done))
    }

    private fun fitJpeg(bytes: ByteArray, max: Int): ByteArray? {
        val src = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        for (side in intArrayOf(1600, 1280, 1024, 800, 640, 480)) {
            val b = scaled(src, side)
            for (q in intArrayOf(85, 70, 55)) {
                val out = ByteArrayOutputStream()
                b.compress(Bitmap.CompressFormat.JPEG, q, out)
                if (out.size() <= max) return out.toByteArray()
            }
        }
        return null
    }

    /** Safe to call again, for example after READ_SMS is granted. */
    fun observe(ctx: Context) {
        if (observer != null) return
        val ht = HandlerThread("phonelink-mms").also { it.start() }
        resetCursor(ctx)
        val h = Handler(ht.looper)
        val push = Runnable { pushNew(ctx) }
        val o = object : ContentObserver(h) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                // An MMS arrives in steps (notification, download, parts). Wait until it settles.
                h.removeCallbacks(push)
                h.postDelayed(push, 1500)
            }
        }
        try {
            ctx.contentResolver.registerContentObserver(MMS, true, o)
            observer = o
            thread = ht
        } catch (_: SecurityException) {
            ht.quitSafely()
        }
    }

    fun stop(ctx: Context) {
        observer?.let { ctx.contentResolver.unregisterContentObserver(it) }
        thread?.quitSafely()
        observer = null
        thread = null
    }

    fun resetCursor(ctx: Context) {
        try {
            ctx.contentResolver.query(MMS, arrayOf("_id"), null, null, "_id DESC LIMIT 1")?.use { c ->
                if (c.moveToFirst()) lastId = maxOf(lastId, c.getLong(0))
            }
        } catch (_: Exception) {}
    }

    private fun pushNew(ctx: Context) {
        val s = Hub.session ?: return
        try {
            ctx.contentResolver.query(MMS, MMS_COLS, "_id > ? AND m_type IN (128, 132)", arrayOf(lastId.toString()), "_id ASC")?.use { c ->
                while (c.moveToNext()) {
                    lastId = maxOf(lastId, c.getLong(0))
                    s.send(json("t" to "sms.new", "message" to mmsRow(ctx, c)))
                }
            }
        } catch (_: Exception) {}
    }
}

/** Builds an M-Send.req PDU (OMA MMS encapsulation 1.2, WSP encoding). */
object MmsPdu {
    fun sendReq(to: List<String>, text: String?, jpeg: ByteArray?): ByteArray {
        val o = ByteArrayOutputStream()
        o.write(0x8C); o.write(0x80)                                   // X-Mms-Message-Type: m-send-req
        o.write(0x98); str(o, "T" + java.lang.Long.toHexString(System.currentTimeMillis())) // X-Mms-Transaction-ID
        o.write(0x8D); o.write(0x92)                                   // X-Mms-MMS-Version: 1.2
        o.write(0x89); o.write(0x01); o.write(0x81)                    // From: insert-address-token
        for (a in to) { o.write(0x97); str(o, a.filter { it.isDigit() || it == '+' } + "/TYPE=PLMN") } // To
        o.write(0x8A); o.write(0x80)                                   // X-Mms-Message-Class: personal
        o.write(0x86); o.write(0x81)                                   // X-Mms-Delivery-Report: no
        o.write(0x90); o.write(0x81)                                   // X-Mms-Read-Report: no

        val q = '"'
        val smil = buildString {
            append("<smil><head><layout><root-layout/>")
            if (jpeg != null) append("<region id=" + q + "Image" + q + " top=" + q + "0" + q + " left=" + q + "0" + q + " height=" + q + "80%" + q + " width=" + q + "100%" + q + " fit=" + q + "meet" + q + "/>")
            if (text != null) append("<region id=" + q + "Text" + q + " top=" + q + "80%" + q + " left=" + q + "0" + q + " height=" + q + "20%" + q + " width=" + q + "100%" + q + "/>")
            append("</layout></head><body><par dur=" + q + "5000ms" + q + ">")
            if (jpeg != null) append("<img src=" + q + "image.jpg" + q + " region=" + q + "Image" + q + "/>")
            if (text != null) append("<text src=" + q + "text.txt" + q + " region=" + q + "Text" + q + "/>")
            append("</par></body></smil>")
        }.toByteArray()

        // Content-Type: application/vnd.wap.multipart.related; type="application/smil"; start="<smil>"
        o.write(0x84)
        val ct = ByteArrayOutputStream()
        ct.write(0xB3)
        ct.write(0x89); str(ct, "application/smil")
        ct.write(0x8A); str(ct, "<smil>")
        valueLength(o, ct.size()); o.write(ct.toByteArray())

        val parts = ArrayList<ByteArray>()
        parts.add(part(textType("application/smil"), "smil", "smil.xml", smil))
        if (jpeg != null) {
            val t = ByteArrayOutputStream()
            t.write(0x9E); t.write(0x85); str(t, "image.jpg")         // image/jpeg; name=image.jpg
            parts.add(part(general(t.toByteArray()), "image", "image.jpg", jpeg))
        }
        if (text != null) {
            val t = ByteArrayOutputStream()
            t.write(0x83); t.write(0x81); t.write(0xEA)               // text/plain; charset=utf-8
            parts.add(part(general(t.toByteArray()), "text", "text.txt", text.toByteArray()))
        }
        uintvar(o, parts.size.toLong())
        parts.forEach { o.write(it) }
        return o.toByteArray()
    }

    private fun part(contentType: ByteArray, id: String, location: String, data: ByteArray): ByteArray {
        val h = ByteArrayOutputStream()
        h.write(contentType)
        h.write(0xC0); h.write(0x22); h.write(("<" + id + ">").toByteArray()); h.write(0) // Content-ID (quoted string)
        h.write(0x8E); str(h, location)                                                 // Content-Location
        val o = ByteArrayOutputStream()
        uintvar(o, h.size().toLong())
        uintvar(o, data.size.toLong())
        o.write(h.toByteArray())
        o.write(data)
        return o.toByteArray()
    }

    private fun textType(t: String) = ByteArrayOutputStream().also { str(it, t) }.toByteArray()

    private fun general(b: ByteArray) = ByteArrayOutputStream().also { valueLength(it, b.size); it.write(b) }.toByteArray()

    private fun str(o: ByteArrayOutputStream, s: String) {
        val b = s.toByteArray()
        if (b.isNotEmpty() && (b[0].toInt() and 0xff) > 127) o.write(0x7F)
        o.write(b); o.write(0)
    }

    private fun valueLength(o: ByteArrayOutputStream, n: Int) {
        if (n < 31) o.write(n) else { o.write(31); uintvar(o, n.toLong()) }
    }

    private fun uintvar(o: ByteArrayOutputStream, v: Long) {
        val tmp = ArrayList<Int>()
        var x = v
        tmp.add((x and 0x7f).toInt())
        x = x shr 7
        while (x > 0) { tmp.add(((x and 0x7f) or 0x80).toInt()); x = x shr 7 }
        tmp.reversed().forEach { o.write(it) }
    }
}
