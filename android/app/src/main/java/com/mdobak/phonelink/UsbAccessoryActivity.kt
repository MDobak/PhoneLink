package com.mdobak.phonelink

import android.app.Activity
import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Bundle

/**
 * Android starts this activity when the Mac switches the phone to accessory mode. It shows nothing: it gives the
 * accessory to LinkService and closes.
 */
class UsbAccessoryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
        finish()
    }

    private fun handle(i: Intent) {
        val acc = i.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java) ?: return
        val svc = Hub.service
        if (svc != null) svc.openAccessory(acc, attached = true)
        else startForegroundService(Intent(this, LinkService::class.java).setAction(LinkService.ACTION_ACCESSORY)
            .putExtra(UsbManager.EXTRA_ACCESSORY, acc))
    }
}
