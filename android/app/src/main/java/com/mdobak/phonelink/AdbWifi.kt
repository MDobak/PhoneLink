package com.mdobak.phonelink

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.Settings
import org.json.JSONObject

/**
 * Turns on Wireless debugging when the paired Mac asks for it.
 * The app must have WRITE_SECURE_SETTINGS. Only adb can give it ("pm grant"); the Mac does this one time.
 */
object AdbWifi {
    private const val KEY = "adb_wifi_enabled"

    fun granted(c: Context) =
        c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    fun enabled(c: Context) = Settings.Global.getInt(c.contentResolver, KEY, 0) == 1

    fun enable(c: Context): JSONObject {
        val r = JSONObject().put("t", "adb.wifi")
        fun fail(e: String) = r.put("ok", false).put("error", e)
        if (!granted(c)) return fail("permission")
        val cr = c.contentResolver
        // Do not turn on Developer options. The user must turn them on.
        if (Settings.Global.getInt(cr, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 1) return fail("developer")
        val cm = c.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true) return fail("wifi")
        if (enabled(c)) return r.put("ok", true).put("changed", false)
        return try {
            Settings.Global.putInt(cr, KEY, 1)
            r.put("ok", enabled(c)).put("changed", true)
        } catch (e: SecurityException) {
            fail("permission")
        }
    }
}
