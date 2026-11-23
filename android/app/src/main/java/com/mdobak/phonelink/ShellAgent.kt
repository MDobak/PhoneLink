package com.mdobak.phonelink

import android.content.ClipData
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Binder
import android.os.Looper
import android.os.Parcel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.system.exitProcess

/**
 * Data agent, started by the Mac as the shell user while adb sees the phone. Needs only the APK, not the installed app:
 * CLASSPATH=/data/local/tmp/phonelink.apk app_process / com.mdobak.phonelink.ShellAgent
 * Serves one Mac on the local socket "phonelink-agent" (via adb forward), then exits.
 *
 * Protocol: frames are a 4-byte big-endian length, then UTF-8 JSON (16 MB max).
 * - On connect: {"t":"hello","sdk":N}, then {"t":"caps","types":[...],"push":[...]}. {"t":"caps"} asks again.
 * - Data requests use the same JSON as the app session (Session.kt). The agent cannot send SMS or MMS.
 * - photos.delete moves to the trash on Android 11+ (cap "photos.trash"), else deletes. SMS cannot be deleted:
 *   only the default SMS app may write SMS (WRITE_SMS app op).
 * - Agent-only: apps, icon, hotspot, clip.set, ping, notif.watch, sms.watch, controls.get/set, volume.set.
 *   notif.watch also toggles the SMS watch unless the request has "sms".
 * - Replies echo "rid". If a request has "id" and the reply does not, the reply gets it. mms.part and
 *   photos.thumb must use "rid" because their JSON uses "id" for data.
 * - Errors: {"t":<request type>,"error":<text>}.
 * - Pushes (no "rid"): clip, notif.posted, notif.removed, sms.new, ring.state.
 */
object ShellAgent {
    private var out: DataOutputStream? = null
    private val lock = Object()

    @JvmStatic
    fun main(args: Array<String>) {
        Shell.guardThreads()
        try { Looper.prepareMainLooper() } catch (_: Exception) {}
        Shell.context // First use needs the Looper of this thread.
        val server = try { LocalServerSocket(args.firstOrNull() ?: "phonelink-agent") } catch (e: Exception) {
            System.err.println("socket: $e"); exitProcess(2)
        }
        println("ready")
        System.out.flush()
        thread(isDaemon = true, name = "clipboard") { watchClipboard() }
        ShellData.push = { send(it) }
        // Exit if no Mac connects soon, so no helper is left behind.
        val idle = thread(isDaemon = true) { try { Thread.sleep(20_000); exitProcess(3) } catch (_: InterruptedException) {} }
        val client: LocalSocket = server.accept()
        idle.interrupt()
        // Free the socket name now so a new helper can bind it even if this one hangs.
        // If the name is taken, a new helper exits with code 2.
        try { server.close() } catch (_: Exception) {}
        val o = DataOutputStream(BufferedOutputStream(client.outputStream, 1 shl 16))
        synchronized(lock) { out = o }
        send(JSONObject().put("t", "hello").put("sdk", android.os.Build.VERSION.SDK_INT))
        send(caps())
        lastClip?.let { send(JSONObject().put("t", "clip").put("text", it)) }
        try {
            val input = DataInputStream(BufferedInputStream(client.inputStream))
            while (true) {
                val n = input.readInt()
                if (n !in 0..(16 shl 20)) break
                val m = JSONObject(String(ByteArray(n).also { input.readFully(it) }))
                if (m.optString("t") == "stop") break
                thread(isDaemon = true) { serve(m) }
            }
        } catch (_: Exception) {}
        synchronized(lock) { out = null }
        try { client.close() } catch (_: Exception) {}
        exitProcess(0)
    }

    private fun serve(m: JSONObject) {
        val reply = replyTo(m)
        try { handle(m, reply)?.let(reply) } catch (e: Throwable) {
            // Log only the class and stack. Messages can contain private data.
            val c = e.cause ?: e
            System.err.println(m.optString("t") + ": " + c.javaClass.name + c.stackTrace.take(8).joinToString("") { "\n  at $it" })
            reply(JSONObject().put("t", m.optString("t")).put("error", c.toString()))
        }
    }

    private fun send(j: JSONObject) = synchronized(lock) {
        val o = out ?: return
        try {
            val b = j.toString().toByteArray()
            o.writeInt(b.size)
            o.write(b)
            o.flush()
        } catch (_: Exception) {}
    }

    private fun replyTo(m: JSONObject): (JSONObject) -> Unit = { r ->
        if (m.has("rid")) r.put("rid", m.get("rid"))
        if (m.has("id") && !r.has("id")) r.put("id", m.get("id"))
        send(r)
    }

    private fun caps(): JSONObject {
        val types = mutableListOf(
            "caps", "ping", "apps", "icon", "hotspot", "clip.set", "clip", "status",
            "sms.threads", "sms.messages", "mms.part", "contacts", "calls.log", "photos.list", "photos.thumb",
            "notif.list", "notif.watch", "sms.watch", "url.open", "call.dial", "ring", "ring.stop", "media.cmd",
            "notif.dismiss", "photos.delete", "controls", "controls.get", "controls.set", "volume.set",
        )
        if (android.os.Build.VERSION.SDK_INT >= 30) types.add("photos.trash")
        return JSONObject().put("t", "caps").put("types", JSONArray(types))
            .put("push", JSONArray(listOf("clip", "notif.posted", "notif.removed", "sms.new", "ring.state")))
    }

    // Null means no reply. Multi-reply requests (photos) reply themselves.
    private fun handle(m: JSONObject, reply: (JSONObject) -> Unit): JSONObject? = when (m.optString("t")) {
        "caps" -> caps()
        "ping" -> JSONObject().put("t", "pong")
        "status" -> ShellData.status()
        "sms.threads" -> ShellData.smsThreads()
        "sms.messages" -> ShellData.smsMessages(m.getLong("thread"), m.optInt("limit", 300))
        "mms.part" -> ShellData.mmsPart(m.getLong("id"))
        "contacts" -> ShellData.contacts()
        "calls.log" -> ShellData.callsLog(m.optInt("limit", 100))
        "photos.list" -> { ShellData.photosList(m.optInt("limit", 60), reply); null }
        "photos.thumb" -> { ShellData.photosThumbs(m.getJSONArray("ids"), reply); null }
        "photos.delete" -> ShellData.photosDelete(m.getJSONArray("ids"))
        "notif.list" -> ShellData.notifList()
        "notif.dismiss" -> { ShellData.notifDismiss(m.getString("key")); null }
        "notif.watch" -> {
            val on = m.optBoolean("on")
            ShellData.watch(notifs = on, sms = if (m.has("sms")) m.optBoolean("sms") else on); null
        }
        "sms.watch" -> { ShellData.watch(sms = m.optBoolean("on")); null }
        "url.open" -> { ShellData.openUrl(m.getString("url")); null }
        "call.dial" -> { ShellData.dial(m.getString("number")); null }
        "ring" -> { ShellData.ringStart(); null }
        "ring.stop" -> { ShellData.ringStop(); null }
        "media.cmd" -> { ShellData.mediaCommand(m.optString("action")); null }
        "clip" -> {
            // The shell has no file provider, so it can set only text.
            if (m.has("text") && !m.isNull("text")) setClip(m.getString("text"))
            else if (m.has("image")) error("The phone can get only text without the Phone Link app.")
            null
        }
        "apps" -> JSONObject().put("t", "apps").put("apps", apps(m.optBoolean("system")))
        "icon" -> JSONObject().put("t", "icon").put("pkg", m.getString("pkg"))
            .put("png", Shell.iconPng(m.getString("pkg"), m.optInt("size", 96).coerceIn(16, 256)))
        "hotspot" -> {
            if (m.has("on")) setHotspot(m.getBoolean("on"))
            hotspotState()
        }
        "clip.set" -> { setClip(m.getString("text")); null }
        "controls.get" -> ShellControls.state()
        "controls.set", "volume.set" -> try { ShellControls.set(m) } catch (e: Throwable) {
            val c = e.cause ?: e
            val text = if (c is IllegalStateException && c.message != null) c.message!! else "The phone did not make the change. Try again."
            if (c !is IllegalStateException) System.err.println(m.optString("t") + ": " + c.javaClass.name)
            JSONObject().put("t", "error").put("req", m.optString("t")).put("msg", text).put("error", text)
        }
        else -> JSONObject().put("t", m.optString("t")).put("error", "unknown request")
    }

    @Volatile private var lastClip: String? = null

    private val clipboard: Any by lazy { Shell.asInterface("android.content.IClipboard", Shell.service("clipboard")) }

    // The listener is an AIDL interface: give Android a Binder that answers its one call,
    // wrapped in a Proxy of the hidden interface.
    private fun watchClipboard() {
        try {
            val binder = object : Binder() {
                override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                    if (code == FIRST_CALL_TRANSACTION) { thread { readClip() }; return true }
                    return super.onTransact(code, data, reply, flags)
                }
            }
            val cls = Class.forName("android.content.IOnPrimaryClipChangedListener")
            val listener = Proxy.newProxyInstance(cls.classLoader, arrayOf(cls)) { proxy, method, args ->
                when (method.name) {
                    "asBinder" -> binder
                    // Object methods: returning null for a primitive type throws.
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.getOrNull(0)
                    "toString" -> "PhoneLinkClipListener"
                    else -> null
                }
            }
            Shell.call(clipboard, "addPrimaryClipChangedListener", listener)
            readClip(initial = true)
            Looper.prepare()
            Looper.loop()
        } catch (e: Throwable) {
            System.err.println("clipboard: $e " + (e.cause ?: ""))
        }
    }

    private fun readClip(initial: Boolean = false) {
        try {
            val clip = Shell.call(clipboard, "getPrimaryClip") as ClipData? ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).text?.toString() ?: return
            if (text == lastClip) return
            lastClip = text
            if (!initial && text.length <= 1_000_000) send(JSONObject().put("t", "clip").put("text", text))
        } catch (e: Throwable) { System.err.println("clip read: $e " + (e.cause ?: "")) }
    }

    private fun setClip(text: String) {
        lastClip = text
        Shell.call(clipboard, "setPrimaryClip", ClipData.newPlainText("Phone Link", text))
    }

    private val pm: PackageManager get() = Shell.context.packageManager

    private fun apps(includeSystem: Boolean): JSONArray {
        val list = JSONArray()
        @Suppress("DEPRECATION")
        for (p in pm.getInstalledPackages(0)) {
            val ai = p.applicationInfo ?: continue
            val system = ai.flags and ApplicationInfo.FLAG_SYSTEM != 0
            val updated = ai.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP != 0
            val launchable = pm.getLaunchIntentForPackage(p.packageName) != null
            if (!includeSystem && system && !updated) continue
            if (!launchable && !includeSystem) continue
            list.put(JSONObject()
                .put("pkg", p.packageName)
                .put("label", try { pm.getApplicationLabel(ai).toString() } catch (_: Exception) { p.packageName })
                .put("version", p.versionName ?: "")
                .put("system", system)
                .put("enabled", ai.enabled)
                .put("launchable", launchable)
                .put("installed", p.firstInstallTime)
                .put("updated", p.lastUpdateTime)
                .put("size", try { java.io.File(ai.sourceDir).length() } catch (_: Exception) { 0L }))
        }
        return list
    }

    private val wifi: Any by lazy { Shell.asInterface("android.net.wifi.IWifiManager", Shell.service("wifi")) }

    private fun hotspotState(): JSONObject {
        val j = JSONObject().put("t", "hotspot")
        val w = wifi
        // WIFI_AP_STATE_ENABLING = 12, WIFI_AP_STATE_ENABLED = 13
        val state = try { Shell.call(w, "getWifiApEnabledState") as Int } catch (e: Throwable) { System.err.println("ap state: $e"); -1 }
        j.put("on", state == 12 || state == 13)
        try {
            val cfg = Shell.call(w, "getSoftApConfiguration")!!
            val ssid = try { cfg.javaClass.getMethod("getWifiSsid").invoke(cfg)?.toString()?.trim('"') } catch (_: Exception) { null }
                ?: cfg.javaClass.getMethod("getSsid").invoke(cfg) as String?
            j.put("ssid", ssid)
            j.put("password", cfg.javaClass.getMethod("getPassphrase").invoke(cfg) as String?)
        } catch (e: Exception) { System.err.println("softap config: $e") }
        return j
    }

    private fun setHotspot(on: Boolean) {
        // TetheringManager has a hidden constructor that takes the binder of the tethering service.
        val tm = android.net.TetheringManager::class.java
            .getDeclaredConstructor(android.content.Context::class.java, java.util.function.Supplier::class.java)
            .apply { isAccessible = true }
            .newInstance(Shell.context, java.util.function.Supplier { Shell.service("tethering") })
        if (!on) {
            tm.javaClass.getMethod("stopTethering", Int::class.javaPrimitiveType).invoke(tm, 0)
            return
        }
        val reqCls = Class.forName("android.net.TetheringManager\$TetheringRequest\$Builder")
        val req = reqCls.getMethod("build").invoke(reqCls.getConstructor(Int::class.javaPrimitiveType).newInstance(0))
        val cbCls = Class.forName("android.net.TetheringManager\$StartTetheringCallback")
        // The callback can run before startTethering returns. A latch keeps that early signal.
        val done = CountDownLatch(1)
        val failure = AtomicReference<String?>()
        val cb = Proxy.newProxyInstance(cbCls.classLoader, arrayOf(cbCls)) { _, method, args ->
            when (method.name) {
                "onTetheringStarted" -> done.countDown()
                "onTetheringFailed" -> { failure.set("error " + args?.getOrNull(0)); done.countDown() }
            }
            null
        }
        tm.javaClass.getMethod("startTethering", req.javaClass, Executor::class.java, cbCls)
            .invoke(tm, req, Executor { it.run() }, cb)
        done.await(8, TimeUnit.SECONDS)
        failure.get()?.let { error(it) }
    }
}
