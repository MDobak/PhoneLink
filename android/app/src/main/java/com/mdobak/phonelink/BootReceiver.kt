package com.mdobak.phonelink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Exported for system broadcasts. Ignore other intents.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            LinkService.start(context)
        } catch (e: Exception) {
            Log.w("PhoneLink", "cannot start the service: $e")
        }
    }
}
