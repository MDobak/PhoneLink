package com.mdobak.phonelink

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * The phone hotspot, as the app sees it. The app cannot turn the hotspot on (only the system and the shell can), so
 * it opens the hotspot settings. When the Mac is on the hotspot, it finds the phone at its gateway address.
 */
object Hotspot {
    /** Sticky system broadcast (hidden WifiManager.WIFI_AP_STATE_CHANGED_ACTION). */
    const val STATE_ACTION = "android.net.wifi.WIFI_AP_STATE_CHANGED"
    private const val EXTRA_STATE = "wifi_state"
    private const val ENABLING = 12
    private const val ENABLED = 13

    /** The name that the phone settings use. */
    val term: String get() = if (Build.MANUFACTURER.equals("samsung", ignoreCase = true)) "Mobile Hotspot" else "Hotspot"

    fun isOn(c: Context): Boolean {
        // The private Wi-Fi network (PrivateWifi) also turns on the access point.
        if (PrivateWifi.isOn) return false
        val state = try { c.registerReceiver(null, IntentFilter(STATE_ACTION))?.getIntExtra(EXTRA_STATE, -1) } catch (_: Exception) { null }
        if (state != null && state != -1) return state == ENABLING || state == ENABLED
        return tetherInterfaces(c).isNotEmpty()
    }

    /** Interfaces with a private IPv4 address that no network of the phone uses: hotspot, USB or Bluetooth tethering. */
    private fun tetherInterfaces(c: Context): Set<String> = try {
        val cm = c.getSystemService(ConnectivityManager::class.java)
        @Suppress("DEPRECATION")
        val used = cm.allNetworks.mapNotNull { cm.getLinkProperties(it)?.interfaceName }.toSet()
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && it.name !in used }
            .filter { i -> i.inetAddresses.toList().any { it is Inet4Address && it.isSiteLocalAddress } }
            .map { it.name }
            .toSet()
    } catch (_: Exception) { emptySet() }

    /** True when a connection with this local address goes through a tethering interface. */
    fun isTethered(c: Context, local: InetAddress?): Boolean = try {
        val name = local?.let { NetworkInterface.getByInetAddress(it)?.name }
        name != null && name in tetherInterfaces(c)
    } catch (_: Exception) { false }

    /** The internet connection of the phone: "wifi", "cellular", "ethernet" or null. */
    fun uplink(c: Context): String? {
        val cm = c.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return null
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> null
        }
    }

    /** Opens the hotspot screen of the system settings, or the closest screen that the phone has. */
    fun openSettings(c: Context) {
        val actions = listOf("android.settings.WIFI_AP_SETTINGS", "android.settings.TETHER_SETTINGS", Settings.ACTION_WIRELESS_SETTINGS)
        for (a in actions) {
            try { c.startActivity(Intent(a)); return } catch (_: ActivityNotFoundException) {} catch (_: SecurityException) {}
        }
    }
}
