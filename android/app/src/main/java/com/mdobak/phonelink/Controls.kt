package com.mdobak.phonelink

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.json.JSONObject

/**
 * Mac menu controls handled by the app: Do Not Disturb, ringer, flashlight and stream volumes. Controls that need
 * shell rights are in ShellControls. Each side reports only what it can change now.
 *
 * - {"t":"controls.get"} -> {"t":"controls","items":{id:{"on":bool}|{"mode":name}},"volume":{stream:{"level","min","max"}}}
 * - {"t":"controls.set","id":id,"on":bool} or {"t":"controls.set","id":"ringer","mode":"normal|vibrate|silent"}
 * - {"t":"volume.set","stream":name,"level":N}
 * A set gets a new "controls" message or an "error" with user-facing text. While connected, the app also sends
 * "controls" when a value changes on the phone.
 */
object Controls {
    private const val TAG = "PhoneLink"

    val STREAMS = linkedMapOf(
        "media" to AudioManager.STREAM_MUSIC,
        "ring" to AudioManager.STREAM_RING,
        "notification" to AudioManager.STREAM_NOTIFICATION,
        "alarm" to AudioManager.STREAM_ALARM,
        "call" to AudioManager.STREAM_VOICE_CALL,
    )

    fun ringerName(mode: Int) = when (mode) {
        AudioManager.RINGER_MODE_SILENT -> "silent"
        AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
        else -> "normal"
    }

    fun ringerMode(name: String) = when (name) {
        "normal" -> AudioManager.RINGER_MODE_NORMAL
        "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
        "silent" -> AudioManager.RINGER_MODE_SILENT
        else -> throw IllegalStateException("This sound mode is not available.")
    }

    private const val POLICY_TEXT = "Allow Do Not Disturb access for Phone Link on the phone, then try again."

    private val lock = Object()
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var receiver: BroadcastReceiver? = null
    private var torchCallback: CameraManager.TorchCallback? = null
    private var session: Session? = null
    private var appCtx: Context? = null
    private var lastPush: String? = null

    private val torchCamera: String? by lazy { findTorch() }
    @Volatile private var torchOn: Boolean? = null

    fun start(ctx: Context, s: Session) = synchronized(lock) {
        stopLocked()
        val app = ctx.applicationContext
        appCtx = app
        session = s
        lastPush = null
        val t = HandlerThread("phonelink-controls").apply { start() }
        val h = Handler(t.looper)
        thread = t
        handler = h
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { changed() }
        }
        val f = IntentFilter().apply {
            addAction(AudioManager.RINGER_MODE_CHANGED_ACTION)
            addAction("android.media.VOLUME_CHANGED_ACTION")
            addAction("android.media.STREAM_MUTE_CHANGED_ACTION")
            addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            addAction(NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED)
        }
        try {
            app.registerReceiver(r, f, null, h, Context.RECEIVER_NOT_EXPORTED)
            receiver = r
        } catch (e: Exception) { Log.w(TAG, "controls receiver: ${e.javaClass.simpleName}") }
        if (torchCamera(app) != null) {
            val cb = object : CameraManager.TorchCallback() {
                override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
                    if (cameraId != torchCamera) return
                    if (torchOn != enabled) { torchOn = enabled; changed() }
                }
            }
            try {
                app.getSystemService(CameraManager::class.java).registerTorchCallback(cb, h)
                torchCallback = cb
            } catch (e: Exception) { Log.w(TAG, "torch callback: ${e.javaClass.simpleName}") }
        }
    }

    // No-op if a newer session owns the listeners.
    fun stop(s: Session) = synchronized(lock) { if (session === s) stopLocked() }

    private fun stopLocked() {
        val app = appCtx
        receiver?.let { r -> try { app?.unregisterReceiver(r) } catch (_: Exception) {} }
        torchCallback?.let { cb -> try { app?.getSystemService(CameraManager::class.java)?.unregisterTorchCallback(cb) } catch (_: Exception) {} }
        receiver = null
        torchCallback = null
        thread?.quitSafely()
        thread = null
        handler = null
        session = null
        torchOn = null
    }

    private val pushTask = Runnable { push() }

    // Debounced by 150 ms so one change on the phone sends one message.
    private fun changed() {
        val h = synchronized(lock) { handler } ?: return
        h.removeCallbacks(pushTask)
        h.postDelayed(pushTask, 150)
    }

    private fun push() {
        val (s, ctx) = synchronized(lock) { session to appCtx }
        if (s == null || ctx == null || s.closed) return
        val j = try { state(ctx) } catch (e: Exception) { Log.w(TAG, "controls state: ${e.javaClass.simpleName}"); return }
        val text = j.toString()
        synchronized(lock) {
            if (text == lastPush) return
            lastPush = text
        }
        s.send(j)
    }

    private fun torchCamera(ctx: Context): String? = try { torchCamera } catch (_: Exception) { null }

    private fun findTorch(): String? {
        val ctx = appCtx ?: Hub.service ?: return null
        val cm = ctx.getSystemService(CameraManager::class.java) ?: return null
        val withFlash = cm.cameraIdList.filter {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
        return withFlash.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: withFlash.firstOrNull()
    }

    private fun canDnd(nm: NotificationManager) = NotifListener.instance != null || nm.isNotificationPolicyAccessGranted

    private fun dndOn(nm: NotificationManager): Boolean {
        val f = nm.currentInterruptionFilter
        return f != NotificationManager.INTERRUPTION_FILTER_ALL && f != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
    }

    fun state(ctx: Context): JSONObject {
        val items = JSONObject()
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm != null && canDnd(nm)) items.put("dnd", json("on" to dndOn(nm)))
        val am = ctx.getSystemService(AudioManager::class.java)
        items.put("ringer", json("mode" to ringerName(am.ringerMode)))
        if (torchCamera(ctx) != null) {
            // The torch callback reports the first value shortly after registration. Wait briefly for it.
            var n = 0
            while (torchOn == null && n++ < 6 && synchronized(lock) { torchCallback } != null) Thread.sleep(50)
            items.put("torch", json("on" to (torchOn ?: false)))
        }
        val volume = JSONObject()
        if (!am.isVolumeFixed) {
            for ((name, stream) in STREAMS) {
                try {
                    volume.put(name, json(
                        "level" to am.getStreamVolume(stream),
                        "min" to am.getStreamMinVolume(stream),
                        "max" to am.getStreamMaxVolume(stream),
                    ))
                } catch (e: Exception) { Log.w(TAG, "volume $name: ${e.javaClass.simpleName}") }
            }
        }
        return json("t" to "controls", "items" to items, "volume" to volume)
    }

    fun set(ctx: Context, m: JSONObject): JSONObject {
        try {
            if (m.optString("t") == "volume.set") setVolume(ctx, m.optString("stream"), m.getInt("level"))
            else when (val id = m.optString("id")) {
                "dnd" -> setDnd(ctx, m.getBoolean("on"))
                "ringer" -> setRinger(ctx, m.optString("mode"))
                "torch" -> setTorch(ctx, m.getBoolean("on"))
                else -> throw IllegalStateException(if (id.isEmpty()) "No control was selected." else "Phone Link on the phone cannot change this control.")
            }
        } catch (e: IllegalStateException) {
            throw e
        } catch (e: SecurityException) {
            Log.w(TAG, "controls set: SecurityException")
            throw IllegalStateException(POLICY_TEXT)
        } catch (e: Exception) {
            Log.w(TAG, "controls set: ${e.javaClass.simpleName}")
            throw IllegalStateException("The phone did not make the change. Try again.")
        }
        val j = state(ctx)
        synchronized(lock) { if (session != null) lastPush = j.toString() }
        return j
    }

    private fun waitFor(ms: Long, done: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (!done() && System.currentTimeMillis() < end) Thread.sleep(40)
    }

    private fun setDnd(ctx: Context, on: Boolean) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val filter = if (on) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL
        if (dndOn(nm) == on) return
        if (!NotifListener.setDndByUser(filter)) {
            if (!nm.isNotificationPolicyAccessGranted) throw IllegalStateException(POLICY_TEXT)
            nm.setInterruptionFilter(filter)
        }
        waitFor(800) { dndOn(nm) == on }
    }

    private fun setRinger(ctx: Context, name: String) {
        val mode = ringerMode(name)
        val am = ctx.getSystemService(AudioManager::class.java)
        if (am.ringerMode == mode) return
        try {
            am.ringerMode = mode
        } catch (e: SecurityException) {
            throw IllegalStateException(
                if (mode == AudioManager.RINGER_MODE_SILENT) "To use Silent, allow Do Not Disturb access for Phone Link on the phone."
                else POLICY_TEXT)
        }
        waitFor(300) { am.ringerMode == mode }
    }

    private fun setTorch(ctx: Context, on: Boolean) {
        val id = torchCamera(ctx) ?: throw IllegalStateException("This phone has no flashlight.")
        val cm = ctx.getSystemService(CameraManager::class.java)
        try {
            cm.setTorchMode(id, on)
        } catch (e: android.hardware.camera2.CameraAccessException) {
            throw IllegalStateException("The flashlight is not available now. An app uses the camera.")
        }
        waitFor(500) { torchOn == on }
        torchOn = on
    }

    private fun setVolume(ctx: Context, name: String, level: Int) {
        val stream = STREAMS[name] ?: throw IllegalStateException("This volume is not available.")
        val am = ctx.getSystemService(AudioManager::class.java)
        if (am.isVolumeFixed) throw IllegalStateException("The volume of this phone cannot be changed.")
        val v = level.coerceIn(am.getStreamMinVolume(stream), am.getStreamMaxVolume(stream))
        try {
            am.setStreamVolume(stream, v, 0)
        } catch (e: SecurityException) {
            throw IllegalStateException("To turn this volume off, allow Do Not Disturb access for Phone Link on the phone.")
        }
    }
}
