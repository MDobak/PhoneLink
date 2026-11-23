package com.mdobak.phonelink

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.provider.CallLog
import org.json.JSONArray
import android.os.Handler
import android.os.Looper
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import org.json.JSONObject

/** Android gives cellular call audio only to the system, so call audio stays on the phone. */
object Calls {
    @Volatile var current: JSONObject? = null
        private set
    private var listener: PhoneStateListener? = null
    private var lastNumber: String? = null
    private var wasRinging = false
    private var answered = false
    @Volatile private var endedByMac = false

    fun dial(ctx: Context, number: String) = telecom(ctx) { placeCall(Uri.fromParts("tel", number, null), Bundle()) }

    @Suppress("DEPRECATION")
    fun answer(ctx: Context) = telecom(ctx) { acceptRingingCall() }

    @Suppress("DEPRECATION")
    fun end(ctx: Context) { endedByMac = true; telecom(ctx) { endCall() } }

    /** A missing permission gives a message for the user instead of the system text. */
    private fun telecom(ctx: Context, block: TelecomManager.() -> Unit) {
        try {
            ctx.getSystemService(TelecomManager::class.java).block()
        } catch (_: SecurityException) {
            throw SecurityException("Allow Messages, contacts and calls in Phone Link on the phone.")
        }
    }

    /** Types: 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 declined, 6 blocked. */
    fun log(ctx: Context, limit: Int): JSONObject {
        val uri = CallLog.Calls.CONTENT_URI.buildUpon().appendQueryParameter("limit", limit.coerceIn(1, 500).toString()).build()
        val arr = JSONArray()
        ctx.contentResolver.query(
            uri, arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            null, null, CallLog.Calls.DATE + " DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val number = c.getString(1) ?: ""
                arr.put(json(
                    "id" to c.getLong(0), "number" to number,
                    "name" to (c.getString(2)?.takeIf { it.isNotBlank() } ?: Contacts.name(ctx, number)),
                    "type" to c.getInt(3), "date" to c.getLong(4), "duration" to c.getLong(5),
                ))
            }
        }
        return json("t" to "calls.log", "items" to arr)
    }

    /** Safe to call again, for example after READ_PHONE_STATE is granted. */
    @Suppress("DEPRECATION")
    fun listen(ctx: Context) {
        val tm = ctx.getSystemService(TelephonyManager::class.java) ?: return
        Handler(Looper.getMainLooper()).post {
            if (listener != null) return@post
            // The older listener gives the phone number (with READ_CALL_LOG); TelephonyCallback does not.
            val l = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, number: String?) {
                    if (!number.isNullOrEmpty()) lastNumber = number
                    val s = when (state) {
                        TelephonyManager.CALL_STATE_RINGING -> "ringing"
                        TelephonyManager.CALL_STATE_OFFHOOK -> "active"
                        else -> "idle"
                    }
                    val n = lastNumber
                    val msg = json("t" to "call.state", "state" to s, "number" to n, "name" to Contacts.name(ctx, n))
                    when (s) {
                        "ringing" -> { wasRinging = true; answered = false; endedByMac = false }
                        "active" -> answered = true
                    }
                    Hub.send(msg)
                    if (s == "idle") {
                        // A call that rang and was not answered here or declined from the Mac is a missed call.
                        if (wasRinging && !answered && !endedByMac) {
                            Hub.send(json("t" to "call.missed", "number" to n, "name" to Contacts.name(ctx, n), "date" to System.currentTimeMillis()))
                        }
                        wasRinging = false; answered = false; endedByMac = false
                        lastNumber = null; current = null
                    } else current = msg
                }
            }
            try {
                tm.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
                listener = l
            } catch (_: SecurityException) {}
        }
    }

    @Suppress("DEPRECATION")
    fun stop(ctx: Context) = Handler(Looper.getMainLooper()).post {
        listener?.let { ctx.getSystemService(TelephonyManager::class.java)?.listen(it, PhoneStateListener.LISTEN_NONE) }
        listener = null
    }
}
