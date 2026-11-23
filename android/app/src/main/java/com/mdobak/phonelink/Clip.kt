package com.mdobak.phonelink

import android.app.Activity
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Base64
import android.widget.Toast
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException

/**
 * Android lets only the foreground app read the clipboard, so the phone sends it on request
 * (Quick Settings tile, notification or share sheet). The Mac clipboard comes automatically.
 */
object Clip {
    private const val MAX_IMAGE = 8 shl 20
    private val main = Handler(Looper.getMainLooper())

    fun apply(ctx: Context, m: JSONObject) {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        val clip: ClipData = when {
            m.has("text") && !m.isNull("text") -> ClipData.newPlainText("From Mac", m.getString("text"))
            m.has("image") && !m.isNull("image") -> {
                val bytes = Base64.decode(m.getString("image"), Base64.NO_WRAP)
                val dir = ShareProvider.dir(ctx)
                dir.listFiles()?.filter { it.name.startsWith("clip-") }?.forEach { it.delete() }
                val f = File(dir, "clip-${System.currentTimeMillis()}.png")
                f.writeBytes(bytes)
                ClipData.newUri(ctx.contentResolver, "Image from Mac", ShareProvider.uri(ctx, f))
            }
            else -> return
        }
        main.post { try { cm.setPrimaryClip(clip) } catch (_: Exception) {} }
    }

    /** Works only while an activity of this app has focus. */
    fun read(ctx: Context): JSONObject? {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val uri = item.uri
        val type = uri?.let { ctx.contentResolver.getType(it) }
        if (uri != null && type != null && type.startsWith("image/")) {
            val bytes = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
            val png = if (bytes.size <= MAX_IMAGE && type == "image/png") bytes else {
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
                ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            }
            if (png.size > MAX_IMAGE) return null
            return json("t" to "clip", "image" to Base64.encodeToString(png, Base64.NO_WRAP))
        }
        val text = item.coerceToText(ctx)?.toString()
        if (text.isNullOrEmpty()) return null
        return json("t" to "clip", "text" to text)
    }

    fun sendCurrent(ctx: Context): String {
        val s = Hub.session ?: return "Not connected to your Mac."
        val m = try { read(ctx) } catch (_: Exception) { null } ?: return "The clipboard is empty."
        s.send(m)
        return "Clipboard sent to ${s.macName}"
    }
}

/** Opens for a moment to read the clipboard, because Android lets only the focused app read it. */
class ClipSendActivity : Activity() {
    private var done = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        Toast.makeText(this, Clip.sendCurrent(this), Toast.LENGTH_SHORT).show()
        finish()
    }

    companion object {
        fun pending(ctx: Context): PendingIntent = PendingIntent.getActivity(
            ctx, 5, Intent(ctx, ClipSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class ClipTile : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = if (Hub.session != null) Tile.STATE_INACTIVE else Tile.STATE_UNAVAILABLE
            subtitle = Hub.session?.macName
            updateTile()
        }
    }

    @Suppress("DEPRECATION")
    override fun onClick() {
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(ClipSendActivity.pending(this))
        else startActivityAndCollapse(Intent(this, ClipSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** Read access to cache files for other apps: clipboard images and outgoing MMS. */
class ShareProvider : ContentProvider() {
    companion object {
        fun dir(ctx: Context) = File(ctx.cacheDir, "shared").apply { mkdirs() }
        fun uri(ctx: Context, f: File): Uri = Uri.parse("content://${ctx.packageName}.share/" + Uri.encode(f.name))
    }

    private fun file(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        val d = dir(ctx)
        val f = File(d, name)
        if (f.canonicalFile.parentFile != d.canonicalFile || !f.isFile) throw FileNotFoundException(name)
        return f
    }

    override fun onCreate() = true

    override fun getType(uri: Uri): String = when (uri.lastPathSegment?.substringAfterLast('.')) {
        "png" -> "image/png"
        "jpg" -> "image/jpeg"
        "pdu" -> "application/vnd.wap.mms-message"
        else -> "application/octet-stream"
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor {
        val f = file(uri)
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply { addRow(arrayOf(f.name, f.length())) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
}
