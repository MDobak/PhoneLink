package com.mdobak.phonelink

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Base64
import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.concurrent.thread

/** An L2CAP channel from the Mac. The session encrypts the data, so the channel needs no Bluetooth pairing. */
class BtLink(private val socket: BluetoothSocket) : Link {
    override val kind = LinkKind.BLUETOOTH
    override val input: InputStream = socket.inputStream
    override val output: OutputStream = socket.outputStream
    override fun close() { try { socket.close() } catch (_: Exception) {} }
}

/**
 * Bluetooth LE for places with no shared Wi-Fi and no cable, and for pairing. The phone advertises SERVICE. The
 * service data in the scan response is [flags][PSM, 2 bytes, little-endian][more]:
 * - flags bit 0 clear: a paired phone. "more" is an 8-byte tag: HMAC-SHA256(beacon key, "phonelink ble" + slot),
 *   with slot = Unix time / 15 minutes. Only the paired Macs have the beacon key, so other devices cannot follow the
 *   phone with a fixed value.
 * - flags bit 0 set: pairing is open. "more" is the start of the phone name (UTF-8, 10 bytes maximum).
 * The Mac connects to the L2CAP channel (BleLink.swift on the Mac).
 */
object Bluetooth {
    val SERVICE: UUID = UUID.fromString("7a6c0001-5c3e-4f8b-9d6a-50484c4e4b31")
    val permissions = arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
    private const val TAG = "PhoneLink"
    private const val SLOT_MS = 15 * 60_000L
    private const val NAME_BYTES = 10

    private val main = Handler(Looper.getMainLooper())
    private var server: BluetoothServerSocket? = null
    private var psm = 0
    private var advertising: AdvertiseCallback? = null
    /** The advertisement content: pairing mode and slot. A change restarts the advertisement. */
    private var advertised: Pair<Boolean, Long>? = null
    private var svc: LinkService? = null
    private val update = Runnable { svc?.let { refresh(it) } }

    fun allowed(ctx: Context) = permissions.all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun adapter(ctx: Context): BluetoothAdapter? = ctx.getSystemService(BluetoothManager::class.java)?.adapter

    /** A random key for the advertisement tag. The phone sends it to the paired Macs in the session ("links"). */
    fun beaconKey(ctx: Context): ByteArray = synchronized(this) {
        val p = ctx.getSharedPreferences("bluetooth", Context.MODE_PRIVATE)
        p.getString("key", null)?.let { return Base64.decode(it, Base64.NO_WRAP) }
        val k = Crypto.random(32)
        p.edit().putString("key", Base64.encodeToString(k, Base64.NO_WRAP)).apply()
        return k
    }

    private fun tag(key: ByteArray, slot: Long): ByteArray =
        Crypto.hmac(key, "phonelink ble".toByteArray() + ByteBuffer.allocate(8).putLong(slot).array()).copyOf(8)

    /**
     * Starts, changes or stops the server and the advertisement for the current state: permissions, Bluetooth on,
     * and a paired Mac or open pairing. Call again when one of them changes.
     */
    @Synchronized
    fun refresh(svc: LinkService) {
        this.svc = svc
        main.removeCallbacks(update)
        val pairing = Hub.isPairing()
        val want = try {
            allowed(svc) && adapter(svc)?.isEnabled == true && (pairing || Pairings.list(svc).isNotEmpty())
        } catch (_: SecurityException) { false }
        if (!want) {
            if (server != null) stop()
            return
        }
        if (server == null) startServer(svc)
        if (server == null) return
        val now = System.currentTimeMillis()
        val slot = now / SLOT_MS
        if (advertised != (pairing to slot)) advertise(svc, pairing, slot)
        // At the end of pairing or at the next slot, change the advertisement.
        val next = if (pairing) Hub.pairingUntil + 500 else (slot + 1) * SLOT_MS + 1000
        main.postDelayed(update, (next - now).coerceAtLeast(1000))
    }

    @Synchronized
    fun stop() {
        main.removeCallbacks(update)
        stopAdvertising()
        server?.let { try { it.close() } catch (_: Exception) {} }
        server = null
    }

    private fun stopAdvertising() {
        val a = advertising ?: return
        advertising = null
        advertised = null
        try { svc?.let { adapter(it)?.bluetoothLeAdvertiser?.stopAdvertising(a) } } catch (_: Exception) {}
    }

    private fun advertise(svc: LinkService, pairing: Boolean, slot: Long) {
        stopAdvertising()
        val adv = adapter(svc)?.bluetoothLeAdvertiser ?: return
        val more = if (pairing) nameStart(phoneName(svc)) else tag(beaconKey(svc), slot)
        val payload = byteArrayOf(if (pairing) 1 else 0, (psm and 0xff).toByte(), (psm shr 8).toByte()) + more
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(if (pairing) AdvertiseSettings.ADVERTISE_MODE_BALANCED else AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
        val scan = AdvertiseData.Builder()
            .addServiceData(ParcelUuid(SERVICE), payload)
            .setIncludeDeviceName(false)
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) { Log.w(TAG, "Bluetooth advertising failed: $errorCode") }
        }
        advertising = cb
        advertised = pairing to slot
        try { adv.startAdvertising(settings, data, scan, cb) } catch (e: Exception) { Log.w(TAG, "Bluetooth advertising: $e") }
    }

    /** The first bytes of the name, cut at a character boundary. */
    private fun nameStart(name: String): ByteArray {
        var s = name
        while (s.toByteArray().size > NAME_BYTES) s = s.substring(0, s.offsetByCodePoints(s.length, -1))
        return s.toByteArray()
    }

    private fun startServer(svc: LinkService) {
        val ad = adapter(svc) ?: return
        val ss = try { ad.listenUsingInsecureL2capChannel() } catch (e: Exception) {
            Log.w(TAG, "Bluetooth server failed: $e")
            return
        }
        server = ss
        psm = ss.psm
        thread(name = "phonelink-bt-accept") {
            try {
                while (true) {
                    val s = ss.accept()
                    thread(name = "phonelink-bt") {
                        try { Session(svc, BtLink(s)).run() } catch (e: Exception) {
                            Log.w(TAG, "Bluetooth connection failed: $e")
                            try { s.close() } catch (_: Exception) {}
                        }
                    }
                }
            } catch (e: Exception) {
                // close() in stop() ends accept(). Otherwise Bluetooth stopped: start again at the next refresh.
                synchronized(this) { if (server === ss) stop() }
            }
        }
    }
}
