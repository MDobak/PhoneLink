package com.mdobak.phonelink

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.Size
import org.json.JSONArray
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.concurrent.Executors

object Photos {
    private val IMAGES: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    private val pool = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null
    private val notify = Runnable { Hub.send(json("t" to "photos.changed")) }

    fun list(ctx: Context, s: Session, limit: Int) = pool.execute {
        val items = JSONArray()
        try {
            val args = Bundle().apply {
                putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media.DATE_ADDED))
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit.coerceIn(1, 500))
            }
            val cols = arrayOf(
                MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.SIZE, MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.MIME_TYPE,
            )
            ctx.contentResolver.query(IMAGES, cols, args, null)?.use { c ->
                while (c.moveToNext()) {
                    val taken = c.getLong(2)
                    items.put(json(
                        "id" to c.getLong(0), "name" to c.getString(1),
                        "date" to (if (taken > 0) taken else c.getLong(3) * 1000),
                        "size" to c.getLong(4), "width" to c.getInt(5), "height" to c.getInt(6), "mime" to c.getString(7),
                    ))
                }
            }
            s.send(json("t" to "photos.list", "items" to items))
        } catch (_: SecurityException) {
            s.send(json("t" to "photos.list", "items" to items, "error" to "Allow Photos in Phone Link on the phone."))
        } catch (e: Exception) {
            // An exception that leaves the pool thread stops the app.
            Log.w("PhoneLink", "photos list: ${e.javaClass.simpleName}")
            s.send(json("t" to "photos.list", "items" to items, "error" to "The phone cannot read its photos."))
        }
    }

    /** The Mac asks only for photos it has not cached. */
    fun thumbs(ctx: Context, s: Session, ids: JSONArray) = pool.execute {
        for (i in 0 until ids.length()) {
            if (s.closed) return@execute
            val id = ids.optLong(i)
            val data = try {
                val bmp = ctx.contentResolver.loadThumbnail(ContentUris.withAppendedId(IMAGES, id), Size(360, 360), null)
                val out = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            } catch (_: Exception) { null }
            s.send(json("t" to "photos.thumb", "id" to id, "data" to data))
        }
    }

    fun open(ctx: Context, id: Long): Triple<String, Long, InputStream> {
        val uri = ContentUris.withAppendedId(IMAGES, id)
        var name = "Photo $id.jpg"
        var size = -1L
        ctx.contentResolver.query(uri, arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) { name = c.getString(0) ?: name; size = c.getLong(1) }
        }
        val input = ctx.contentResolver.openInputStream(uri) ?: throw FileNotFoundException("The photo is not available.")
        return Triple(name, size, input)
    }

    /** Safe to call again, for example after READ_MEDIA_IMAGES is granted. */
    fun observe(ctx: Context) {
        if (observer != null) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(notify)
                main.postDelayed(notify, 1500)
            }
        }
        try {
            ctx.contentResolver.registerContentObserver(IMAGES, true, o)
            observer = o
        } catch (_: Exception) {}
    }

    fun stop(ctx: Context) {
        observer?.let { ctx.contentResolver.unregisterContentObserver(it) }
        observer = null
        main.removeCallbacks(notify)
    }
}
