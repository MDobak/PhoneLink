package com.mdobak.phonelink

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject

/**
 * A private Wi-Fi network for the Mac: the local-only hotspot of Android. It does not share the internet connection
 * of the phone, so the Mac cannot use mobile data through it. The Mac asks for it over Bluetooth ("lohs.start"),
 * joins it, and then the session uses Wi-Fi speed. The network stops when the Mac asks ("lohs.stop"), or 60 seconds
 * after the last session ended.
 */
object PrivateWifi {
    private const val TAG = "PhoneLink"
    private val main = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var ssid: String? = null
    private var pass: String? = null
    private val waiting = mutableListOf<(JSONObject) -> Unit>()

    val permission: String =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION

    fun allowed(c: Context) = c.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    @Volatile var isOn = false
        private set

    /** The network for the "links" message, or null. */
    fun json(): JSONObject? = synchronized(this) { ssid?.let { json("ssid" to it, "pass" to pass) } }

    /** Starts the network, or gives the network that is on. done gets the "lohs" reply. Any thread. */
    fun start(c: Context, done: (JSONObject) -> Unit) = main.post {
        json()?.let { done(reply(it)); return@post }
        if (!allowed(c)) {
            done(json("t" to "lohs", "error" to "On the phone, open Phone Link and allow Private Wi-Fi network."))
            return@post
        }
        waiting.add(done)
        if (waiting.size > 1) return@post
        val wm = c.applicationContext.getSystemService(WifiManager::class.java)
        try {
            wm.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    val conf = r.softApConfiguration
                    val name = if (Build.VERSION.SDK_INT >= 33) conf.wifiSsid?.bytes?.let { String(it, Charsets.UTF_8) }
                               else @Suppress("DEPRECATION") conf.ssid
                    synchronized(this@PrivateWifi) {
                        reservation = r
                        ssid = name
                        pass = conf.passphrase
                        isOn = true
                    }
                    finish(json()?.let { reply(it) } ?: json("t" to "lohs", "error" to "The phone did not give the network name."))
                    changed()
                }
                override fun onStopped() { clear(); changed() }
                override fun onFailed(reason: Int) {
                    Log.w(TAG, "local-only hotspot failed: $reason")
                    finish(json("t" to "lohs", "error" to failure(reason)))
                }
            }, main)
        } catch (e: Exception) {
            Log.w(TAG, "local-only hotspot: $e")
            finish(json("t" to "lohs", "error" to "The phone cannot start a private Wi-Fi network."))
        }
    }

    fun stop() = main.post {
        val r = synchronized(this) { reservation }
        clear()
        try { r?.close() } catch (_: Exception) {}
        changed()
    }

    /** Stops the network when no session uses it for 60 seconds. */
    fun sessionEnded() {
        main.postDelayed({ if (Hub.session == null && isOn) stop() }, 60_000)
    }

    private fun reply(n: JSONObject) = json("t" to "lohs", "ssid" to n.optString("ssid"), "pass" to n.opt("pass"))

    private fun finish(r: JSONObject) {
        val list = waiting.toList()
        waiting.clear()
        list.forEach { it(r) }
    }

    private fun clear() = synchronized(this) {
        reservation = null
        ssid = null
        pass = null
        isOn = false
    }

    private fun changed() {
        Hub.changed()
        Hub.service?.let { s -> Hub.session?.send(s.links()) }
    }

    private fun failure(reason: Int) = when (reason) {
        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE ->
            "The phone cannot start a private Wi-Fi network while Mobile Hotspot or another Wi-Fi feature is on."
        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "The phone does not allow a private Wi-Fi network."
        else -> "The phone cannot start a private Wi-Fi network."
    }
}
