package com.mdobak.phonelink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import java.io.FileDescriptor
import java.io.PrintWriter
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

const val PORT = 47800

fun phoneName(ctx: Context): String =
    Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL
const val SERVICE_TYPE = "_phonelink._tcp"

/** Foreground service: TCP server, Bonjour advertisement, phone listeners and screen capture. */
class LinkService : Service() {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var server: ServerSocket? = null
    @Volatile private var destroyed = false
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var nsdNetwork: Network? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private var projection: MediaProjection? = null
    // Set on the main thread, read by the session read thread.
    @Volatile private var streamer: ScreenStreamer? = null
    private var pendingScreen: Triple<Int, Int, Int>? = null
    private var consentShown = false
    private var audio: AudioCapture? = null
    private var wantAudio = false
    private var lastBattery = -1 to false
    // Random value from the Mac. adb reads it via dumpsys to find the linked phone.
    @Volatile var adbToken: String? = null
    private val batteryReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val level = batteryLevel(i)
            val plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
            if ((level to plugged) == lastBattery) return
            lastBattery = level to plugged
            if (Hub.session != null) Hub.send(status())
        }
    }
    // The service type must include mediaProjection while this is true.
    private var projectionGranted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Hub.service = this
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("link", "Connection", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel("prompt", "Prompts", NotificationManager.IMPORTANCE_HIGH))
        nm.createNotificationChannel(NotificationChannel("files", "Files", NotificationManager.IMPORTANCE_LOW))
        goForeground()
        startServer()
        // Android drops multicast while the screen is off unless an app holds this lock. Without it, Bonjour
        // queries go unanswered and the Mac cannot find the phone.
        multicastLock = applicationContext.getSystemService(WifiManager::class.java)
            .createMulticastLock("phonelink-mdns").apply { setReferenceCounted(false); acquire() }
        registerNsd(currentWifi())
        watchWifi()
        observePhone()
        // After an app update Android can leave the notification listener unbound.
        NotifListener.rebind(this)
        registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        destroyed = true
        stopScreen()
        Hub.session?.close()
        try { server?.close() } catch (_: Exception) {}
        try { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(wifiCallback) } catch (_: Exception) {}
        nsdListener?.let { try { getSystemService(NsdManager::class.java).unregisterService(it) } catch (_: Exception) {} }
        multicastLock?.takeIf { it.isHeld }?.release()
        main.removeCallbacksAndMessages(null)
        Sms.stop(this)
        Mms.stop(this)
        Photos.stop(this)
        Calls.stop(this)
        try { unregisterReceiver(batteryReceiver) } catch (_: Exception) {}
        wifiLock?.takeIf { it.isHeld }?.release()
        Hub.service = null
        super.onDestroy()
    }

    private fun goForeground() {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val s = Hub.session
        val text = when {
            streamer != null -> "Sharing screen with ${s?.macName}"
            s != null -> "Connected to ${s.macName}"
            else -> "Waiting for your Mac"
        }
        val b = Notification.Builder(this, "link")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle("Phone Link")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
        if (s != null) b.addAction(Notification.Action.Builder(null, "Send clipboard", ClipSendActivity.pending(this)).build())
        val n = b.build()
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if (projectionGranted || projection != null) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        // Screen sound needs the microphone type. Android refuses it in some states, so try without it then.
        val mic = (projectionGranted || projection != null) && wantAudio &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        try {
            startForeground(1, n, if (mic) type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else type)
        } catch (e: Exception) {
            if (!mic) throw e
            Log.w("PhoneLink", "microphone service type refused", e)
            startForeground(1, n, type)
        }
    }

    // An observer cannot start before its permission is granted, so the setup screen calls this again after a change.
    fun observePhone() {
        Sms.observe(this)
        Mms.observe(this)
        Photos.observe(this)
        Calls.listen(this)
        if (Hub.session != null) Hub.send(status())
    }

    fun onSessionChanged() = main.post {
        val connected = Hub.session != null
        if (!connected) stopScreen()
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        // Low latency works only with the screen on and an app of this phone in front. With the screen off Android
        // ignores the lock (Android 14+ also ignores the high-performance lock).
        if (connected && wifiLock == null) {
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "phonelink").apply { acquire() }
        } else if (!connected) {
            wifiLock?.takeIf { it.isHeld }?.release()
            wifiLock = null
        }
        goForeground()
    }

    private fun startServer() = thread(name = "phonelink-accept") {
        while (!destroyed) {
            try {
                val ss = ServerSocket()
                server = ss
                ss.reuseAddress = true
                ss.bind(InetSocketAddress(PORT))
                while (true) {
                    val sock = ss.accept()
                    thread(name = "phonelink-rx") {
                        // An uncaught exception in a thread kills the app. Session.run() catches its own errors.
                        try { Session(this, sock).run() } catch (e: Exception) {
                            Log.w("PhoneLink", "connection failed: $e")
                            try { sock.close() } catch (_: Exception) {}
                        }
                    }
                }
            } catch (e: Exception) {
                if (destroyed) break
                Log.w("PhoneLink", "server stopped: $e")
                try { server?.close() } catch (_: Exception) {}
                try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
            }
        }
    }

    private fun currentWifi(): Network? {
        val cm = getSystemService(ConnectivityManager::class.java)
        val n = cm.activeNetwork ?: return null
        return n.takeIf { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
    }

    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            main.post { if (!destroyed && network != nsdNetwork) registerNsd(network) }
        }
    }

    private fun watchWifi() {
        val req = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        try {
            getSystemService(ConnectivityManager::class.java).registerNetworkCallback(req, wifiCallback)
        } catch (e: Exception) {
            Log.w("PhoneLink", "cannot watch Wi-Fi: $e")
        }
    }

    private fun registerNsd(network: Network?) {
        val nsd = getSystemService(NsdManager::class.java)
        nsdListener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        nsdListener = null
        nsdNetwork = network
        val info = NsdServiceInfo().apply {
            serviceName = phoneName(this@LinkService)
            serviceType = SERVICE_TYPE
            port = PORT
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {}
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w("PhoneLink", "NSD failed $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            nsdListener = l
        } catch (e: Exception) {
            Log.w("PhoneLink", "NSD register failed: $e")
        }
    }

    // Printed by "adb shell dumpsys activity service com.mdobak.phonelink/.LinkService" (shell and system only).
    // "pair" opens pairing for 2 minutes so the Mac can set up the phone over adb. The user still confirms the code.
    override fun dump(fd: FileDescriptor?, writer: PrintWriter?, args: Array<out String>?) {
        if (args?.contains("pair") == true) {
            Hub.pairingUntil = System.currentTimeMillis() + 120_000
            Hub.changed()
            writer?.println("phonelink-pairing=on")
        }
        writer?.println("phonelink-token=" + (adbToken ?: "none"))
    }

    fun status(): JSONObject {
        val b = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = b?.let { batteryLevel(it) }
        val plugged = (b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        fun has(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        return json(
            "t" to "status",
            "name" to phoneName(this),
            "model" to Build.MODEL,
            "battery" to level,
            "charging" to plugged,
            "adbWifi" to json("granted" to AdbWifi.granted(this), "on" to AdbWifi.enabled(this)),
            "perms" to json(
                "sms" to (has(android.Manifest.permission.READ_SMS) && has(android.Manifest.permission.SEND_SMS)),
                "contacts" to has(android.Manifest.permission.READ_CONTACTS),
                "phone" to (has(android.Manifest.permission.CALL_PHONE) && has(android.Manifest.permission.READ_PHONE_STATE)),
                "notifications" to (NotifListener.instance != null),
                "control" to (InputService.instance != null),
                "files" to PhoneFiles.hasAccess(),
                "photos" to has(android.Manifest.permission.READ_MEDIA_IMAGES),
                "audio" to has(android.Manifest.permission.RECORD_AUDIO),
                "postNotifications" to (Build.VERSION.SDK_INT < 33 || has(android.Manifest.permission.POST_NOTIFICATIONS)),
                "callLog" to (has(android.Manifest.permission.READ_CALL_LOG) && has(android.Manifest.permission.ANSWER_PHONE_CALLS)),
                "background" to ignoringBatteryOptimizations(this),
            ),
        )
    }

    fun startScreen(maxSize: Int, bitrate: Int, fps: Int, sound: Boolean) = main.post {
        wantAudio = sound
        streamer?.let {
            setScreenAudio(sound)
            it.requestKeyFrame()
            it.sendInfo()
            return@post
        }
        pendingScreen = Triple(maxSize, bitrate, fps)
        consentShown = false
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val intent = Intent(this, ProjectionActivity::class.java)
            .putExtra(ProjectionActivity.EXTRA_REQUEST, mpm.createScreenCaptureIntent())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // A bound accessibility service may start activities from the background; the service context alone
        // may not. Otherwise ask the user through a notification.
        val starter: Context = InputService.instance ?: this
        try {
            starter.startActivity(intent)
        } catch (e: Exception) {
            Log.w("PhoneLink", "cannot start projection activity: $e")
        }
        main.postDelayed({
            if (projection == null && pendingScreen != null) promptForScreen(intent)
        }, 2500)
    }

    fun onConsentShown() = main.post { consentShown = true }

    // No answer in 2.5 s: tell the Mac, and notify if the consent screen did not open.
    private fun promptForScreen(intent: Intent) {
        Hub.send(json("t" to "screen.state", "state" to "waiting", "msg" to "Allow screen sharing on the phone"))
        if (consentShown) return
        val pi = PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(this, "prompt")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle("Share screen with your Mac?")
            .setContentText("Tap to allow")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(2, n)
    }

    fun onProjectionResult(resultCode: Int, data: Intent?) = main.post {
        getSystemService(NotificationManager::class.java).cancel(2)
        val params = pendingScreen ?: return@post
        pendingScreen = null
        if (resultCode != android.app.Activity.RESULT_OK || data == null) {
            Hub.send(json("t" to "screen.state", "state" to "stopped", "msg" to "Screen sharing was denied on the phone"))
            return@post
        }
        val mpm = getSystemService(MediaProjectionManager::class.java)
        // The foreground service must have the mediaProjection type before getMediaProjection().
        val p = try {
            projectionGranted = true
            goForeground()
            mpm.getMediaProjection(resultCode, data) ?: throw IllegalStateException("No projection")
        } catch (e: Exception) {
            Log.w("PhoneLink", "projection failed", e)
            projectionGranted = false
            goForeground()
            Hub.send(json("t" to "screen.state", "state" to "stopped", "msg" to "The phone did not start screen sharing. Try again."))
            return@post
        }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { main.post { stopScreen() } }
        }, main)
        try {
            streamer = ScreenStreamer(this, p, params.first, params.second, params.third).also { it.start() }
            goForeground()
            if (wantAudio) startAudio()
        } catch (e: Exception) {
            Log.w("PhoneLink", "screen start failed", e)
            Hub.send(json("t" to "screen.state", "state" to "stopped", "msg" to "Encoder error: ${e.message}"))
            stopScreen()
        }
    }

    fun stopScreen() {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { stopScreen() }; return }
        pendingScreen = null
        val had = streamer != null || projection != null
        audio?.stop()
        audio = null
        streamer?.stop()
        streamer = null
        projection?.let { p -> projection = null; try { p.stop() } catch (_: Exception) {} }
        projectionGranted = false
        if (had) {
            Hub.send(json("t" to "screen.state", "state" to "stopped"))
            goForeground()
        }
    }

    fun requestKeyFrame() { streamer?.requestKeyFrame() }

    fun setScreenAudio(on: Boolean) {
        if (Looper.myLooper() != Looper.getMainLooper()) { main.post { setScreenAudio(on) }; return }
        wantAudio = on
        if (projection == null) return
        if (on && audio == null) { goForeground(); startAudio() }
        if (!on && audio != null) { audio?.stop(); audio = null; Hub.send(json("t" to "screen.audio", "on" to false)); goForeground() }
    }

    private fun startAudio() {
        val p = projection ?: return
        val a = AudioCapture(this, p)
        val ok = a.start()
        audio = if (ok) a else null
        Hub.send(json("t" to "screen.audio", "on" to ok,
            "msg" to if (ok) null else if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
                "Allow Screen sound in Phone Link on the phone." else "The phone cannot share its sound."))
    }

    fun openUrl(url: String) = main.post {
        val u = android.net.Uri.parse(url)
        if (u.scheme != "http" && u.scheme != "https") return@post
        val i = Intent(Intent.ACTION_VIEW, u).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pm = getSystemService(PowerManager::class.java)
        val km = getSystemService(android.app.KeyguardManager::class.java)
        val starter = InputService.instance
        if (starter != null && pm.isInteractive && !km.isKeyguardLocked) {
            try { starter.startActivity(i); return@post } catch (e: Exception) { Log.w("PhoneLink", "cannot open link: ${e.javaClass.simpleName}") }
        }
        val pi = PendingIntent.getActivity(this, 7, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(this, "prompt")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle("Link from " + (Hub.session?.macName ?: "Mac"))
            .setContentText(u.host ?: url)
            .setStyle(Notification.BigTextStyle().bigText(url))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(7, n)
    }

    @Suppress("DEPRECATION")
    fun wakeScreen() {
        val pm = getSystemService(PowerManager::class.java)
        if (pm.isInteractive) return
        pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "phonelink:wake")
            .acquire(3000)
    }

    companion object {
        private fun batteryLevel(i: Intent) =
            i.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) * 100 / i.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, LinkService::class.java))
        }

        fun ignoringBatteryOptimizations(ctx: Context) =
            ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)

        fun batteryIntent(ctx: Context) =
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:" + ctx.packageName))
    }
}
