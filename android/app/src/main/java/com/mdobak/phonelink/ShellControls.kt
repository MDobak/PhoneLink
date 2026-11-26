package com.mdobak.phonelink

import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.telephony.SubscriptionManager
import org.json.JSONObject

/**
 * Mac menu controls that need the shell user. Same JSON as Controls.kt.
 * Reads use only binder calls and settings so controls.get stays fast. Commands (svc, cmd, settings) run only on a change.
 */
object ShellControls {
    private val audio: Any by lazy { Shell.asInterface("android.media.IAudioService", Shell.service("audio")) }
    private val power: Any by lazy { Shell.asInterface("android.os.IPowerManager", Shell.service("power")) }
    private val location: Any by lazy { Shell.asInterface("android.location.ILocationManager", Shell.service("location")) }
    private val activity: Any by lazy { Shell.asInterface("android.app.IActivityManager", Shell.service("activity")) }

    private val pm: Any by lazy { Shell.asInterface("android.content.pm.IPackageManager", Shell.service("package")) }
    private val features = HashMap<String, Boolean>()

    // The shell context's PackageManager has no feature cache, so ask the package service.
    private fun has(feature: String): Boolean = synchronized(features) {
        features.getOrPut(feature) {
            try { Shell.call(pm, "hasSystemFeature", feature, 0) as Boolean }
            catch (e: Throwable) { System.err.println("feature: " + (e.cause ?: e).javaClass.name); false }
        }
    }

    private fun bluetoothOn(): Boolean? = Shell.setting("global", "bluetooth_on")?.let { it == "1" || it == "2" }

    private val sub: Any by lazy { Shell.asInterface("com.android.internal.telephony.ISub", Shell.service("isub")) }
    private val phone: Any by lazy { Shell.asInterface("com.android.internal.telephony.ITelephony", Shell.service("phone")) }

    // Null if no data SIM. The static SubscriptionManager calls fail in app_process, so ask the service.
    private fun dataSub(): Int? {
        if (!has(PackageManager.FEATURE_TELEPHONY_DATA) && !has(PackageManager.FEATURE_TELEPHONY)) return null
        val id = try { Shell.call(sub, "getDefaultDataSubId") as Int }
            catch (_: Throwable) { Shell.setting("global", "multi_sim_data_call")?.toIntOrNull() ?: -1 }
        return id.takeIf { it >= 0 && it != SubscriptionManager.INVALID_SUBSCRIPTION_ID }
    }

    private fun dataOn(id: Int): Boolean? =
        try { Shell.call(phone, "isUserDataEnabled", id) as Boolean } catch (e: Throwable) {
            System.err.println("data state: " + (e.cause ?: e).javaClass.name)
            (Shell.setting("global", "mobile_data$id") ?: Shell.setting("global", "mobile_data"))?.let { it == "1" }
        }

    private fun powerSaving() = Shell.call(power, "isPowerSaveMode") as Boolean

    // Correct also when the user set a schedule.
    private fun darkOn(): Boolean {
        val c = Shell.call(activity, "getConfiguration") as Configuration
        return c.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }

    private fun locationOn() = Shell.call(location, "isLocationEnabledForUser", 0) as Boolean

    private fun rotationOn() = (Shell.setting("system", "accelerometer_rotation") ?: "0") == "1"

    private fun ringer() = Shell.call(audio, "getRingerModeExternal") as Int

    private fun volume(stream: Int) = Shell.call(audio, "getStreamVolume", stream) as Int

    fun state(): JSONObject {
        val items = JSONObject()
        fun on(id: String, read: () -> Boolean?) {
            try { read()?.let { items.put(id, JSONObject().put("on", it)) } }
            catch (e: Throwable) { System.err.println("controls $id: " + (e.cause ?: e).javaClass.name) }
        }
        if (has(PackageManager.FEATURE_BLUETOOTH)) on("bluetooth") { bluetoothOn() }
        dataSub()?.let { sub -> on("data") { dataOn(sub) } }
        on("powerSaving") { powerSaving() }
        on("darkMode") { darkOn() }
        if (has(PackageManager.FEATURE_LOCATION)) on("location") { locationOn() }
        if (has(PackageManager.FEATURE_SENSOR_ACCELEROMETER)) on("rotation") { rotationOn() }
        try { items.put("ringer", JSONObject().put("mode", Controls.ringerName(ringer()))) }
        catch (e: Throwable) { System.err.println("controls ringer: " + (e.cause ?: e).javaClass.name) }

        val vol = JSONObject()
        val fixed = try { Shell.call(audio, "isVolumeFixed") as Boolean } catch (_: Throwable) { false }
        if (!fixed) for ((name, stream) in Controls.STREAMS) {
            try {
                vol.put(name, JSONObject()
                    .put("level", volume(stream))
                    .put("min", Shell.call(audio, "getStreamMinVolume", stream) as Int)
                    .put("max", Shell.call(audio, "getStreamMaxVolume", stream) as Int))
            } catch (e: Throwable) { System.err.println("volume $name: " + (e.cause ?: e).javaClass.name) }
        }
        return JSONObject().put("t", "controls").put("items", items).put("volume", vol)
    }

    private fun command(vararg cmd: String) {
        val out = try { ShellData.run(*cmd) } catch (e: Exception) {
            throw IllegalStateException("The phone did not make the change. Try again.")
        }
        val bad = listOf("exception", "error", "unknown", "denied", "not allowed", "usage:", "failure")
        if (bad.any { out.contains(it, ignoreCase = true) }) {
            System.err.println("controls command " + cmd.take(3).joinToString(" ") + ": " + out.take(200))
            throw IllegalStateException("The phone did not make the change. Try again.")
        }
    }

    private fun waitFor(ms: Long, done: () -> Boolean?) {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) {
            if (try { done() == true } catch (_: Throwable) { false }) return
            Thread.sleep(80)
        }
    }

    fun set(m: JSONObject): JSONObject {
        if (m.optString("t") == "volume.set") {
            setVolume(m.optString("stream"), m.getInt("level"))
            return state()
        }
        val id = m.optString("id")
        if (id == "ringer") {
            setRinger(m.optString("mode"))
            return state()
        }
        if (!m.has("on")) throw IllegalStateException("No value was given for this control.")
        val on = m.getBoolean("on")
        when (id) {
            "bluetooth" -> {
                if (!has(PackageManager.FEATURE_BLUETOOTH)) throw IllegalStateException("This phone has no Bluetooth.")
                command("cmd", "bluetooth_manager", if (on) "enable" else "disable")
                waitFor(4000) { bluetoothOn() == on }
            }
            "data" -> {
                val sub = dataSub() ?: throw IllegalStateException("Mobile data is not available. Make sure that the phone has a SIM.")
                command("svc", "data", if (on) "enable" else "disable")
                waitFor(2000) { dataOn(sub) == on }
            }
            "powerSaving" -> {
                command("cmd", "power", "set-mode", if (on) "1" else "0")
                waitFor(1500) { powerSaving() == on }
            }
            "darkMode" -> {
                command("cmd", "uimode", "night", if (on) "yes" else "no")
                waitFor(1500) { darkOn() == on }
            }
            "location" -> {
                command("cmd", "location", "set-location-enabled", if (on) "true" else "false")
                waitFor(1500) { locationOn() == on }
            }
            "rotation" -> {
                command("settings", "put", "system", "accelerometer_rotation", if (on) "1" else "0")
                waitFor(1000) { rotationOn() == on }
            }
            else -> throw IllegalStateException("This control is not available without the Phone Link app.")
        }
        return state()
    }

    private fun setRinger(name: String) {
        val mode = Controls.ringerMode(name)
        if (ringer() == mode) return
        val arg = when (mode) {
            AudioManager.RINGER_MODE_SILENT -> "SILENT"
            AudioManager.RINGER_MODE_VIBRATE -> "VIBRATE"
            else -> "NORMAL"
        }
        try {
            command("cmd", "audio", "set-ringer-mode", arg)
        } catch (e: IllegalStateException) {
            // Older Android lacks this command. Ask the audio service.
            try { Shell.call(audio, "setRingerModeExternal", mode) } catch (_: Throwable) { throw e }
        }
        waitFor(1000) { ringer() == mode }
    }

    private fun setVolume(name: String, level: Int) {
        val stream = Controls.STREAMS[name] ?: throw IllegalStateException("This volume is not available.")
        val min = Shell.call(audio, "getStreamMinVolume", stream) as Int
        val max = Shell.call(audio, "getStreamMaxVolume", stream) as Int
        val v = level.coerceIn(min, max)
        try {
            try { Shell.call(audio, "setStreamVolume", stream, v, 0) }
            catch (_: Throwable) { Shell.call(audio, "setStreamVolumeWithAttribution", stream, v, 0) }
        } catch (e: Throwable) {
            System.err.println("volume set: " + (e.cause ?: e).javaClass.name)
            throw IllegalStateException(
                if (v == 0) "The phone did not turn this volume off. Do Not Disturb settings can block it."
                else "The phone did not change the volume. Try again.")
        }
    }
}
