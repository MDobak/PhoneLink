package com.mdobak.phonelink

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Invisible activity: shows the system screen-capture consent and gives the result to the service. */
class ProjectionActivity : Activity() {
    companion object { const val EXTRA_REQUEST = "request" }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // After a configuration change the consent screen is already open.
        if (savedInstanceState != null) return
        @Suppress("DEPRECATION")
        val req = intent.getParcelableExtra<Intent>(EXTRA_REQUEST)
        if (req == null) { finish(); return }
        @Suppress("DEPRECATION")
        startActivityForResult(req, 1)
        Hub.service?.onConsentShown()
    }

    @Deprecated("Activity result API needs AndroidX; this app has no dependencies")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        Hub.service?.onProjectionResult(resultCode, data)
        finish()
    }
}
