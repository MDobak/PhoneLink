package com.mdobak.phonelink

import android.Manifest
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.Gravity
import android.widget.LinearLayout
import java.net.Inet4Address
import java.net.NetworkInterface

/** Setup screen: connection state, access and paired Macs. */
class MainActivity : UiActivity() {
    private var dialog: AlertDialog? = null
    /** Also starts the countdown when pairing opens from the Mac. */
    private val refresh: () -> Unit = { content.removeCallbacks(tick); tick.run() }
    private val tick = object : Runnable {
        override fun run() {
            render()
            if (Hub.isPairing()) content.postDelayed(this, 1000)
        }
    }

    private val runtimePerms = arrayOf(
        Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS,
        Manifest.permission.READ_CONTACTS, Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG, Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.POST_NOTIFICATIONS,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(scrollContent())
        LinkService.start(this)
    }

    override fun onResume() {
        super.onResume()
        Hub.addListener(refresh)
        // Permissions may have been granted here or in system settings: start the observers that need them.
        Hub.service?.observePhone()
        render()
        if (Hub.isPairing()) content.post(tick)
    }

    override fun onPause() {
        Hub.removeListener(refresh)
        content.removeCallbacks(tick)
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        Hub.service?.observePhone()
        render()
    }

    override fun onDestroy() {
        dialog?.dismiss()
        dialog = null
        super.onDestroy()
    }

    private fun has(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun notificationAccess() =
        Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?.contains(ComponentName(this, NotifListener::class.java).flattenToString()) == true

    private fun accessibility() =
        Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?.contains(ComponentName(this, InputService::class.java).flattenToString()) == true

    private fun ipAddress(): String? = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && (it.name.startsWith("wlan") || it.name.startsWith("eth")) }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address }?.hostAddress
    } catch (_: Exception) { null }

    private fun render() {
        content.removeAllViews()
        val s = Hub.session

        content.addView(label("Phone Link", 34f).apply {
            setPadding(dp(20), dp(56), dp(20), dp(24))
        })

        val conn = section(null)
        val ip = ipAddress()
        conn.addView(row(
            R.drawable.ic_laptop,
            if (s != null) s.macName else "Not connected",
            if (s != null) "Connected"
            else if (ip != null) "Open Phone Link on your Mac. IP address: $ip"
            else "Connect to Wi-Fi, or connect to your Mac with USB.",
            null,
        ))
        if (s != null) {
            conn.addView(divider())
            conn.addView(row(R.drawable.ic_folder, "Files on ${s.macName}", null, null) {
                startActivity(Intent(this, MacFilesActivity::class.java))
            })
            conn.addView(divider())
            conn.addView(row(R.drawable.ic_rd_display, "Remote Desktop", null, null) {
                startActivity(Intent(this, RemoteDesktopActivity::class.java))
            })
            conn.addView(divider())
            conn.addView(row(R.drawable.ic_rd_terminal, "Terminal", null, null) {
                startActivity(Intent(this, TerminalActivity::class.java))
            })
        }

        val access = section("Access")
        val perms = runtimePerms.all { has(it) }
        access.addView(row(R.drawable.ic_sms, "Messages, contacts and calls", "Text and call from your Mac",
            check(perms, "Allow") { requestPermissions(runtimePerms, 1) }))
        access.addView(divider())
        access.addView(row(R.drawable.ic_bell, "Notifications", "Show phone notifications on your Mac",
            check(notificationAccess(), "Turn on") { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }))
        access.addView(divider())
        val control = accessibility()
        access.addView(row(R.drawable.ic_cast, "Screen control",
            if (control) "Control this phone from your Mac" else "In Accessibility, open Installed apps",
            check(control, "Turn on") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }))
        access.addView(divider())
        access.addView(row(R.drawable.ic_folder, "Files", "Browse phone files from your Mac",
            check(Environment.isExternalStorageManager(), "Allow") {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            }))
        access.addView(divider())
        access.addView(row(R.drawable.ic_photo, "Photos", "See recent photos on your Mac",
            check(has(Manifest.permission.READ_MEDIA_IMAGES), "Allow") { requestPermissions(arrayOf(Manifest.permission.READ_MEDIA_IMAGES), 2) }))
        access.addView(divider())
        access.addView(row(R.drawable.ic_volume, "Screen sound", "Hear the phone on your Mac during screen sharing",
            check(has(Manifest.permission.RECORD_AUDIO), "Allow") { requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 3) }))
        access.addView(divider())
        access.addView(row(R.drawable.ic_battery, "Background use", "Stay connected when the screen is off",
            check(LinkService.ignoringBatteryOptimizations(this), "Allow") { startActivity(LinkService.batteryIntent(this)) }))

        val macs = section("Paired Macs")
        val list = Pairings.list(this)
        list.forEachIndexed { i, (id, name) ->
            if (i > 0) macs.addView(divider())
            val connected = s?.macId == id
            macs.addView(row(R.drawable.ic_laptop, name, if (connected) "Connected" else "Not connected",
                textButton("Forget") { confirmForget(id, name) }))
        }
        if (list.isNotEmpty()) macs.addView(divider())
        if (Hub.isPairing()) {
            val left = ((Hub.pairingUntil - System.currentTimeMillis()) / 1000).coerceAtLeast(0)
            macs.addView(row(R.drawable.ic_add, "Ready to pair", "Select this phone on your Mac · %d:%02d".format(left / 60, left % 60),
                textButton("Cancel") { Hub.pairingUntil = 0; render() }))
        } else {
            macs.addView(row(R.drawable.ic_add, "Pair a new Mac", null, null, titleColorId = R.color.primary) {
                Hub.pairingUntil = System.currentTimeMillis() + 120_000
                render()
                content.removeCallbacks(tick)
                content.postDelayed(tick, 1000)
            })
        }

        content.addView(label("Your data stays between this phone and your Mac. No cloud service is used.", 13f, R.color.on_surface_variant).apply {
            setPadding(dp(20), dp(16), dp(20), 0)
        })

        showPairDialog()
    }

    private fun confirmForget(id: String, name: String) {
        AlertDialog.Builder(this)
            .setTitle("Forget $name?")
            .setMessage("To connect again, you must pair again.")
            .setPositiveButton("Forget") { _, _ ->
                Pairings.remove(this, id)
                Hub.session?.takeIf { it.macId == id }?.close()
                render()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showPairDialog() {
        val req = Hub.pairRequest?.takeIf { !it.resolved }
        if (req == null) { dialog?.dismiss(); dialog = null; return }
        if (dialog?.isShowing == true) return
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), 0)
        }
        body.addView(label("Check that your Mac shows the same code.", 15f, R.color.on_surface_variant))
        body.addView(label(req.sas.substring(0, 3) + " " + req.sas.substring(3), 40f).apply {
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            fontFeatureSettings = "tnum"
            letterSpacing = 0.06f
            gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, dp(8))
            contentDescription = "Code " + req.sas.toCharArray().joinToString(" ")
        })
        dialog = AlertDialog.Builder(this)
            .setTitle("Pair with ${req.macName}?")
            .setView(body)
            .setPositiveButton("Pair") { _, _ -> req.resolve(true) }
            .setNegativeButton("Cancel") { _, _ -> req.resolve(false) }
            .setCancelable(false)
            .show()
    }
}
