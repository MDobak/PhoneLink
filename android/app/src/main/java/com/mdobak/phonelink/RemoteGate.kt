package com.mdobak.phonelink

import android.app.Activity
import android.app.KeyguardManager
import android.hardware.biometrics.BiometricManager.Authenticators
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import android.os.SystemClock

/**
 * Asks for the device credential before the first use and after 5 minutes away.
 * Call unlock() in onStart and left() in onStop of each protected activity.
 */
object RemoteGate {
    private const val GRACE_MS = 5 * 60_000L

    @Volatile private var unlocked = false
    @Volatile private var leftAt = 0L
    /** Main thread only. */
    private var cancel: CancellationSignal? = null

    fun left() {
        if (unlocked) leftAt = SystemClock.elapsedRealtime()
    }

    private fun isOpen(): Boolean =
        unlocked && (leftAt == 0L || SystemClock.elapsedRealtime() - leftAt < GRACE_MS)

    fun unlock(a: Activity, subtitle: String, ok: () -> Unit, failed: () -> Unit) {
        if (isOpen()) { leftAt = 0L; ok(); return }
        unlocked = false
        val km = a.getSystemService(KeyguardManager::class.java)
        if (km == null || !km.isDeviceSecure) {
            // No screen lock: there is no credential to ask for.
            unlocked = true; leftAt = 0L; ok(); return
        }
        cancel?.cancel()
        val signal = CancellationSignal()
        cancel = signal
        val prompt = BiometricPrompt.Builder(a)
            .setTitle("Unlock Phone Link")
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL)
            .build()
        try {
            prompt.authenticate(signal, a.mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (cancel !== signal) return
                    unlocked = true; leftAt = 0L; cancel = null
                    ok()
                }
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    // A newer prompt cancelled this one: keep its screen and signal.
                    if (cancel !== signal) return
                    cancel = null
                    failed()
                }
            })
        } catch (e: Exception) {
            if (cancel === signal) cancel = null
            failed()
        }
    }
}
