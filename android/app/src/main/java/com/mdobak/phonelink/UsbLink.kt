package com.mdobak.phonelink

import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** The Mac reads this first, so that it does not write before this phone opened the accessory. */
val USB_READY = "PLNKRDY1".toByteArray()

/** Android Open Accessory on the USB cable. The Mac starts accessory mode (UsbLink.swift on the Mac). */
class UsbLink(private val pfd: ParcelFileDescriptor) : Link {
    private val closed = AtomicBoolean()
    override val kind = LinkKind.USB
    override val input: InputStream = AccessoryInput(FileInputStream(pfd.fileDescriptor))
    override val output: OutputStream = FileOutputStream(pfd.fileDescriptor)
    override fun close() {
        if (closed.compareAndSet(false, true)) try { pfd.close() } catch (_: Exception) {}
    }
}

/**
 * Each accessory read must ask for 16 KiB, or the driver can lose data. The Mac also sends empty packets, which
 * give reads of 0 bytes. This stream never gives 0 bytes, because BufferedInputStream reads 0 as the end.
 */
private class AccessoryInput(private val inner: InputStream) : InputStream() {
    private val buf = ByteArray(16384)
    private var pos = 0
    private var end = 0

    private fun fill(): Boolean {
        while (pos >= end) {
            val n = inner.read(buf, 0, buf.size)
            if (n < 0) return false
            pos = 0
            end = n
        }
        return true
    }

    override fun read(): Int = if (fill()) buf[pos++].toInt() and 0xff else -1

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (!fill()) return -1
        val n = minOf(len, end - pos)
        System.arraycopy(buf, pos, b, off, n)
        pos += n
        return n
    }

    override fun available() = end - pos
    override fun close() = inner.close()
}
