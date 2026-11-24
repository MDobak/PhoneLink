package com.mdobak.phonelink

import android.os.SystemClock
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket

enum class LinkKind { TCP, USB, BLUETOOTH }

/** A reliable, ordered byte stream to the Mac. A Session sends the same frames on each kind. */
interface Link : Closeable {
    val kind: LinkKind
    val input: InputStream
    val output: OutputStream
    /** The local address of a TCP link. */
    val localAddress: InetAddress? get() = null
    /** Safe to call more than once and from any thread. */
    override fun close()
}

/** Wi-Fi, the hotspot of this phone, or "adb forward" from the Mac. */
class TcpLink(private val socket: Socket) : Link {
    init { socket.tcpNoDelay = true }
    override val kind = LinkKind.TCP
    override val input: InputStream = socket.getInputStream()
    override val output: OutputStream = socket.getOutputStream()
    override val localAddress: InetAddress? get() = socket.localAddress
    override fun close() { try { socket.close() } catch (_: Exception) {} }
}

/**
 * Measures how long one read waits. Not all links have a read timeout, so the session calls check() at an interval
 * and closes the link when a read waits longer than limitMs.
 */
class WatchedInput(private val inner: InputStream) : InputStream() {
    @Volatile var limitMs = 150_000L
    @Volatile private var since = 0L

    override fun read(): Int = watch { inner.read() }
    override fun read(b: ByteArray, off: Int, len: Int): Int = watch { inner.read(b, off, len) }
    override fun available() = inner.available()
    override fun close() = inner.close()

    private inline fun <T> watch(f: () -> T): T {
        since = SystemClock.elapsedRealtime()
        try { return f() } finally { since = 0 }
    }

    /** True when a read waits longer than the limit. */
    fun stalled(): Boolean {
        val s = since
        return s != 0L && SystemClock.elapsedRealtime() - s > limitMs
    }
}
