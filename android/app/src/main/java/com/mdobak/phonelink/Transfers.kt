package com.mdobak.phonelink

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

const val MSG_FILE: Byte = 3
private const val CHUNK = 256 * 1024
private const val TAG = "PhoneLinkFiles"

/** The phone's own storage, as the Mac sees it. Needs "All files access". */
object PhoneFiles {
    fun hasAccess() = Environment.isExternalStorageManager()

    private fun roots(ctx: Context): List<Pair<String, File>> =
        ctx.getSystemService(StorageManager::class.java).storageVolumes.mapNotNull { v ->
            val dir = v.directory ?: return@mapNotNull null
            (if (v.isPrimary) "Internal storage" else v.getDescription(ctx)) to dir
        }

    private fun requireAccess() {
        if (!hasAccess()) throw FileAccessException()
    }

    /** Only paths inside a storage volume are allowed. */
    fun resolve(ctx: Context, path: String): File {
        requireAccess()
        val f = File(path).canonicalFile
        val inside = roots(ctx).any { (_, r) ->
            val root = r.canonicalFile
            f == root || f.path.startsWith(root.path + "/")
        }
        if (!inside) throw SecurityException("This location is not available.")
        return f
    }

    fun list(dir: File): JSONArray {
        if (!dir.isDirectory) throw IOException("This folder does not exist.")
        val a = JSONArray()
        (dir.listFiles() ?: throw IOException("Cannot open this folder.")).forEach { f ->
            a.put(json("name" to f.name, "path" to f.path, "dir" to f.isDirectory,
                "size" to (if (f.isFile) f.length() else 0L), "mtime" to f.lastModified()))
        }
        return a
    }

    fun rootsJson(ctx: Context): JSONArray {
        requireAccess()
        return roots(ctx).toJsonArray { (name, f) -> json("name" to name, "path" to f.path, "dir" to true) }
    }

    private fun isRoot(ctx: Context, f: File) = roots(ctx).any { (_, r) -> r.canonicalFile == f }

    private fun resolveItem(ctx: Context, path: String): File {
        if (path.startsWith("media:")) throw IOException("You cannot change this item.")
        val f = resolve(ctx, path)
        if (isRoot(ctx, f)) throw IOException("You cannot change this location.")
        return f
    }

    private fun mustExist(f: File) { if (!f.exists()) throw FileNotFound() }

    private fun checkName(name: String): String {
        val n = name.trim()
        if (n.isEmpty() || n == "." || n == ".." || n.contains('/') || n.any { it.code < 32 } || n.length > 255) {
            throw IOException("The name \"$name\" is not valid.")
        }
        return n
    }

    private fun info(f: File, deep: Boolean): JSONObject {
        val o = json("name" to f.name, "path" to f.path, "dir" to f.isDirectory,
            "size" to (if (f.isFile) f.length() else 0L), "mtime" to f.lastModified(), "writable" to f.canWrite())
        try {
            o.put("ctime", Files.readAttributes(f.toPath(), BasicFileAttributes::class.java).creationTime().toMillis())
        } catch (_: Exception) {}
        if (deep && f.isDirectory) {
            var count = 0L
            var bytes = 0L
            val end = System.currentTimeMillis() + 10_000
            for (c in f.walkTopDown()) {
                if (c == f) continue
                count++
                if (c.isFile) bytes += c.length()
                if (count >= 500_000 || System.currentTimeMillis() > end) { o.put("partial", true); break }
            }
            o.put("count", count)
            o.put("size", bytes)
        }
        return o
    }

    fun stat(ctx: Context, path: String, deep: Boolean): JSONObject {
        val f = resolve(ctx, path)
        mustExist(f)
        val o = json("item" to info(f, deep))
        if (f.isDirectory) { o.put("free", f.usableSpace); o.put("total", f.totalSpace) }
        return o
    }

    fun delete(ctx: Context, paths: JSONArray): JSONObject {
        val files = (0 until paths.length()).map { resolveItem(ctx, paths.getString(it)) }
        files.forEach { mustExist(it) }
        val done = ArrayList<String>()
        try {
            for (f in files) {
                if (!f.deleteRecursively()) throw IOException("Cannot delete \"${f.name}\".")
                done.add(f.path)
            }
        } finally {
            scan(ctx, done)
        }
        return json("count" to done.size)
    }

    fun rename(ctx: Context, path: String, name: String): JSONObject {
        val f = resolveItem(ctx, path)
        mustExist(f)
        val dest = File(f.parentFile, checkName(name))
        // A case-only rename is allowed: the storage sees no difference.
        if (dest.exists() && !Files.isSameFile(f.toPath(), dest.toPath())) throw FileExists(dest.name)
        if (!f.renameTo(dest)) throw IOException("Cannot rename \"${f.name}\".")
        scan(ctx, listOf(f.path, dest.path))
        return json("path" to dest.path, "item" to info(dest, false))
    }

    fun mkdir(ctx: Context, dirPath: String, name: String, unique: Boolean): JSONObject {
        val dir = resolve(ctx, dirPath)
        if (!dir.isDirectory) throw FileNotFound()
        val n = checkName(name)
        var f = File(dir, n)
        if (f.exists()) {
            if (!unique) throw FileExists(n)
            var i = 2
            while (f.exists()) { f = File(dir, "$n $i"); i++ }
        }
        if (!f.mkdir()) throw IOException("Cannot make the folder \"${f.name}\".")
        return json("path" to f.path, "item" to info(f, false))
    }

    fun move(ctx: Context, from: String, to: String, overwrite: Boolean): JSONObject {
        val src = resolveItem(ctx, from)
        val dest = resolveItem(ctx, to)
        mustExist(src)
        if (dest.path.startsWith(src.path + "/")) throw IOException("You cannot move a folder into itself.")
        if (dest.parentFile?.isDirectory != true) throw FileNotFound()
        var replaced = false
        if (dest.exists() && !Files.isSameFile(src.toPath(), dest.toPath())) {
            if (!overwrite) throw FileExists(dest.name)
            if (!dest.deleteRecursively()) throw IOException("Cannot replace \"${dest.name}\".")
            replaced = true
        }
        if (!src.renameTo(dest)) {
            // Across volumes: copy, then delete the original.
            if (!src.copyRecursively(dest, overwrite = false)) throw IOException("Cannot move \"${src.name}\".")
            if (!src.deleteRecursively()) throw IOException("\"${src.name}\" was copied, but the original cannot be deleted.")
        }
        scan(ctx, listOf(src.path, dest.path))
        return json("path" to dest.path, "replaced" to replaced)
    }

    fun copy(ctx: Context, from: String, to: String?, overwrite: Boolean): JSONObject {
        val src = resolveItem(ctx, from)
        mustExist(src)
        val dest = if (to != null) resolveItem(ctx, to) else duplicateName(src)
        if (dest.path == src.path || dest.path.startsWith(src.path + "/")) throw IOException("You cannot copy a folder into itself.")
        if (dest.parentFile?.isDirectory != true) throw FileNotFound()
        var replaced = false
        if (dest.exists()) {
            if (!overwrite) throw FileExists(dest.name)
            // On case-insensitive storage "a.txt" and "A.txt" are the same file. Do not delete the source.
            if (Files.isSameFile(src.toPath(), dest.toPath())) throw IOException("You cannot copy an item onto itself.")
            if (!dest.deleteRecursively()) throw IOException("Cannot replace \"${dest.name}\".")
            replaced = true
        }
        if (!src.copyRecursively(dest, overwrite = false)) throw IOException("Cannot copy \"${src.name}\".")
        scan(ctx, listOf(dest.path))
        return json("path" to dest.path, "replaced" to replaced, "item" to info(dest, false))
    }

    private fun duplicateName(src: File): File {
        val dir = src.parentFile ?: throw IOException("Cannot copy this item.")
        val name = src.name
        val base = if (src.isDirectory) name else name.substringBeforeLast('.', name)
        val ext = if (!src.isDirectory && name.contains('.') && !name.startsWith('.')) "." + name.substringAfterLast('.') else ""
        var f = File(dir, "$base copy$ext")
        var i = 2
        while (f.exists()) { f = File(dir, "$base copy $i$ext"); i++ }
        return f
    }

    private fun scan(ctx: Context, paths: List<String>) {
        if (paths.isNotEmpty()) MediaScannerConnection.scanFile(ctx, paths.toTypedArray(), null, null)
    }
}

class FileAccessException : SecurityException("Allow file access in Phone Link on the phone.")
class FileNotFound : IOException("The item does not exist.")
class FileExists(name: String) : IOException("An item with the name \"$name\" already exists.")

class RemoteFile(val name: String, val path: String, val dir: Boolean, val size: Long, val mtime: Long) {
    constructor(j: JSONObject) : this(j.optString("name"), j.optString("path"), j.optBoolean("dir"), j.optLong("size"), j.optLong("mtime"))
}

/**
 * File browsing and transfer in both directions over the encrypted session.
 *
 * The phone uses ids below 2^31, the Mac uses ids from 2^31. File data goes in type-3 frames: [3][id u32][bytes].
 *  - fs.roots, fs.list {id, path}  ->  fs.result {id, items} or fs.error {id, msg, code}
 *  - fs.get {id, path, offset?, length? | suffix?}  ->  fs.meta {id, name, size, offset?, length?}, data frames, fs.end {id}
 *    "size" is always the full size.
 *  - fs.put {id, dir?, name, size, replace?, quiet?}, data frames, fs.end {id}  ->  fs.done {id, name} or fs.error
 *    With no "dir", the file goes to Download/Phone Link on the phone or Downloads on the Mac.
 *  - fs.cancel {id}: either side stops the transfer.
 *  - fs.stat {path, deep}, fs.delete {paths}, fs.rename {path, name}, fs.mkdir {dir, name, unique},
 *    fs.move {from, to, overwrite}, fs.copy {from, to?, overwrite}  ->  fs.result or fs.error
 * Error codes: "perm" (no file access), "notfound", "exists".
 */
object Transfers {
    enum class State { ACTIVE, DONE, FAILED, CANCELLED }

    class Item(val id: Int, val name: String, val upload: Boolean, @Volatile var total: Long) {
        @Volatile var done = 0L
        @Volatile var state = State.ACTIVE
        @Volatile var error: String? = null
        @Volatile var uri: Uri? = null
        val active get() = state == State.ACTIVE
    }

    class Source(val name: String, val size: Long, val input: InputStream)

    private class Incoming(val item: Item?, val expected: Long, val replyDone: Boolean,
                           val out: OutputStream, val commit: () -> String, val abort: () -> Unit,
                           val quiet: Boolean = false) {
        var received = 0L
    }
    private class Sending(val item: Item?) { @Volatile var cancelled = false }

    private val ids = AtomicInteger(1)
    val items = CopyOnWriteArrayList<Item>()
    private val incoming = ConcurrentHashMap<Int, Incoming>()
    private val sending = ConcurrentHashMap<Int, Sending>()
    private val pending = ConcurrentHashMap<Int, (JSONObject) -> Unit>()
    private val pool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    @Volatile private var lastChange = 0L

    fun addListener(l: () -> Unit) { listeners.add(l) }
    fun removeListener(l: () -> Unit) { listeners.remove(l) }

    private fun changed(force: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - lastChange < 250) return
        lastChange = now
        main.post {
            listeners.forEach { it() }
            updateNotification()
        }
    }

    private fun err(id: Int, e: Exception) = json("t" to "fs.error", "id" to id,
        "msg" to (e.message ?: e.toString()), "code" to when (e) {
            is FileAccessException -> "perm"
            is FileNotFound -> "notfound"
            is FileExists -> "exists"
            else -> null
        })

    private fun op(s: Session, id: Int, block: () -> JSONObject) = pool.execute {
        try {
            val r = block()
            r.put("t", "fs.result"); r.put("id", id)
            s.send(r)
        } catch (e: Exception) {
            s.send(err(id, e))
        }
    }

    // Requests from the Mac run on the read thread.

    fun handle(ctx: Context, s: Session, m: JSONObject) {
        val id = m.optInt("id")
        when (m.optString("t")) {
            "fs.roots" -> op(s, id) { json("items" to PhoneFiles.rootsJson(ctx)) }
            "fs.list" -> op(s, id) {
                val dir = PhoneFiles.resolve(ctx, m.getString("path"))
                json("path" to dir.path, "writable" to dir.canWrite(), "items" to PhoneFiles.list(dir))
            }
            "fs.stat" -> op(s, id) { PhoneFiles.stat(ctx, m.getString("path"), m.optBoolean("deep")) }
            "fs.delete" -> op(s, id) { PhoneFiles.delete(ctx, m.getJSONArray("paths")) }
            "fs.rename" -> op(s, id) { PhoneFiles.rename(ctx, m.getString("path"), m.getString("name")) }
            "fs.mkdir" -> op(s, id) { PhoneFiles.mkdir(ctx, m.getString("dir"), m.getString("name"), m.optBoolean("unique")) }
            "fs.move" -> op(s, id) { PhoneFiles.move(ctx, m.getString("from"), m.getString("to"), m.optBoolean("overwrite")) }
            "fs.copy" -> op(s, id) {
                PhoneFiles.copy(ctx, m.getString("from"), if (m.isNull("to")) null else m.optString("to"), m.optBoolean("overwrite"))
            }
            "fs.get" -> serveFile(ctx, s, id, m)
            "fs.put" -> receive(ctx, s, id, m)
            "fs.end" -> finishIncoming(ctx, s, id)
            "fs.cancel" -> {
                sending[id]?.let { it.cancelled = true; it.item?.state = State.CANCELLED }
                incoming.remove(id)?.let { it.abort(); it.item?.state = State.CANCELLED }
                changed(true)
            }
            "fs.meta" -> incoming[id]?.item?.let { it.total = m.optLong("size", it.total); changed(true) }
            "fs.done" -> sending.remove(id)?.item?.let { it.state = State.DONE; it.done = it.total.coerceAtLeast(it.done); changed(true) }
            "fs.error" -> {
                sending.remove(id)?.let { it.cancelled = true; it.item?.apply { state = State.FAILED; error = m.optString("msg") } }
                incoming.remove(id)?.let { it.abort(); it.item?.apply { state = State.FAILED; error = m.optString("msg") } }
                pending.remove(id)?.let { cb -> main.post { cb(m) } }
                changed(true)
            }
            "fs.result" -> pending.remove(id)?.let { cb -> main.post { cb(m) } }
        }
    }

    private fun serveFile(ctx: Context, s: Session, id: Int, m: JSONObject) = pool.execute {
        val path = m.optString("path")
        val snd = Sending(null)
        sending[id] = snd
        fun part(size: Long): Pair<Long, Long> {
            if (m.has("suffix")) { val n = m.optLong("suffix").coerceIn(0, size); return (size - n) to n }
            val off = m.optLong("offset", 0).coerceIn(0, size)
            val len = m.optLong("length", -1)
            return off to (if (len < 0) size - off else len.coerceAtMost(size - off))
        }
        fun meta(name: String, size: Long, off: Long, len: Long) {
            val j = json("t" to "fs.meta", "id" to id, "name" to name, "size" to size)
            if (m.has("offset") || m.has("suffix")) { j.put("offset", off); j.put("length", len) }
            s.send(j)
        }
        try {
            if (path.startsWith("media:")) {
                val (name, size, input) = Photos.open(ctx, path.removePrefix("media:").toLong())
                input.use {
                    if (size < 0) { meta(name, size, 0, -1); stream(s, id, it, snd) }
                    else {
                        val (off, len) = part(size)
                        var skip = off
                        while (skip > 0) { val n = it.skip(skip); if (n <= 0) break; skip -= n }
                        meta(name, size, off, len)
                        stream(s, id, it, snd, len)
                    }
                }
            } else {
                val f = PhoneFiles.resolve(ctx, path)
                if (!f.exists()) throw FileNotFound()
                if (!f.isFile) throw IOException("This item is not a file.")
                val size = f.length()
                val (off, len) = part(size)
                FileInputStream(f).use {
                    if (off > 0) it.channel.position(off)
                    meta(f.name, size, off, len)
                    stream(s, id, it, snd, len)
                }
            }
            if (!snd.cancelled) s.send(json("t" to "fs.end", "id" to id))
        } catch (e: Exception) {
            if (!snd.cancelled) s.send(err(id, e))
        } finally {
            sending.remove(id)
        }
    }

    private fun stream(s: Session, id: Int, input: InputStream, snd: Sending, limit: Long = -1) {
        val buf = ByteArray(CHUNK)
        var left = limit
        while (!snd.cancelled && left != 0L) {
            val want = if (left < 0) CHUNK else minOf(CHUNK.toLong(), left).toInt()
            val n = input.read(buf, 0, want)
            if (n < 0) break
            if (n == 0) continue
            s.sendChunk(id, buf, n)
            if (left > 0) left -= n
            snd.item?.let { it.done += n; changed(false) }
        }
    }

    private fun receive(ctx: Context, s: Session, id: Int, m: JSONObject) {
        try {
            val name = safeName(m.optString("name"))
            val size = m.optLong("size", -1)
            val dir = if (m.isNull("dir")) null else m.getString("dir")
            // A quiet copy (Finder drive) shows no progress or notification.
            val quiet = m.optBoolean("quiet") && dir != null
            val item = Item(id, name, upload = false, total = size)
            val inc = if (dir == null) downloadsTarget(ctx, name, size, item, replyDone = true)
                      else folderTarget(ctx, PhoneFiles.resolve(ctx, dir), name, size, if (quiet) null else item,
                                        m.optBoolean("replace"), quiet)
            incoming[id] = inc
            if (!quiet) { items.add(0, item); changed(true) }
        } catch (e: Exception) {
            s.send(err(id, e))
        }
    }

    // Runs on the read thread.
    fun onChunk(s: Session, id: Int, data: ByteArray, off: Int, len: Int) {
        val inc = incoming[id] ?: return
        try {
            inc.out.write(data, off, len)
            inc.received += len
            inc.item?.let { it.done = inc.received; changed(false) }
        } catch (e: Exception) {
            incoming.remove(id)
            inc.abort()
            // A user cancel closes the output, so the write fails. Keep the state "cancelled".
            inc.item?.takeIf { it.active }?.apply { state = State.FAILED; error = e.message }
            s.send(json("t" to "fs.cancel", "id" to id))
            if (inc.replyDone) s.send(err(id, e))
            changed(true)
        }
    }

    private fun finishIncoming(ctx: Context, s: Session, id: Int) {
        val inc = incoming.remove(id) ?: return
        try {
            if (inc.expected >= 0 && inc.received != inc.expected) throw IOException("The file is incomplete.")
            val name = inc.commit()
            inc.item?.apply { state = State.DONE; done = inc.received; total = inc.received }
            if (inc.replyDone) s.send(json("t" to "fs.done", "id" to id, "name" to name))
            if (!inc.quiet) notifyReceived(ctx, name, inc.item?.uri, s.macName)
        } catch (e: Exception) {
            inc.abort()
            inc.item?.apply { state = State.FAILED; error = e.message }
            if (inc.replyDone) s.send(err(id, e))
        }
        changed(true)
    }

    fun sessionClosed() {
        incoming.values.forEach { it.abort(); it.item?.takeIf { i -> i.active }?.apply { state = State.FAILED; error = "The Mac disconnected." } }
        incoming.clear()
        sending.values.forEach { it.cancelled = true; it.item?.takeIf { i -> i.active }?.apply { state = State.FAILED; error = "The Mac disconnected." } }
        sending.clear()
        val cbs = pending.values.toList()
        pending.clear()
        main.post { cbs.forEach { it(json("t" to "fs.error", "msg" to "The Mac disconnected.")) } }
        changed(true)
    }

    // Download/Phone Link through MediaStore, so no storage permission is needed.
    private fun downloadsTarget(ctx: Context, name: String, size: Long, item: Item, replyDone: Boolean): Incoming {
        val cr = ctx.contentResolver
        val cv = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Phone Link")
            put(MediaStore.Downloads.IS_PENDING, 1)
            mimeOf(name)?.let { put(MediaStore.Downloads.MIME_TYPE, it) }
        }
        val uri = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv) ?: throw IOException("Cannot save the file.")
        val out = try { cr.openOutputStream(uri) ?: throw IOException("Cannot save the file.") }
                  catch (e: Exception) { cr.delete(uri, null, null); throw e }
        return Incoming(item, size, replyDone, out,
            commit = {
                out.close()
                cr.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                item.uri = uri
                cr.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0) else name
                } ?: name
            },
            abort = { try { out.close() } catch (_: Exception) {}; cr.delete(uri, null, null) })
    }

    // Writes to a hidden temp file first. With replace, overwrites a file with the same name, else picks a free name.
    private fun folderTarget(ctx: Context, dir: File, name: String, size: Long, item: Item?,
                             replace: Boolean, quiet: Boolean): Incoming {
        if (!dir.isDirectory) throw IOException("This folder does not exist.")
        if (replace && File(dir, name).isDirectory) throw FileExists(name)
        val dest = if (replace) File(dir, name) else unique(dir, name)
        val tmp = File(dir, ".${dest.name}.${System.nanoTime()}.phonelink-part")
        val out = FileOutputStream(tmp)
        return Incoming(item, size, true, out,
            commit = {
                out.close()
                val final = if (replace) dest else unique(dir, dest.name)
                if (replace && final.isDirectory) throw FileExists(name)
                // rename() replaces an existing file in one step.
                if (!tmp.renameTo(final)) throw IOException("Cannot save the file.")
                MediaScannerConnection.scanFile(ctx, arrayOf(final.path), null, null)
                final.name
            },
            abort = { try { out.close() } catch (_: Exception) {}; tmp.delete() }, quiet = quiet)
    }

    private fun mimeOf(name: String) =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())

    private fun safeName(raw: String): String {
        val n = raw.substringAfterLast('/').substringAfterLast('\\').filter { it.code >= 32 && it.code != 127 }.trim().take(200)
        return if (n.isEmpty() || n == "." || n == "..") "file" else n
    }

    private fun unique(dir: File, name: String): File {
        var f = File(dir, name)
        if (!f.exists()) return f
        val base = name.substringBeforeLast('.', name)
        val ext = if (name.contains('.') && !name.startsWith('.')) "." + name.substringAfterLast('.') else ""
        var i = 1
        while (f.exists()) { f = File(dir, "$base ($i)$ext"); i++ }
        return f
    }

    // Requests to the Mac run on the main thread.

    fun request(t: String, path: String?, cb: (JSONObject) -> Unit) {
        val s = Hub.session ?: return cb(json("t" to "fs.error", "msg" to "Phone Link is not connected to a Mac."))
        val id = ids.getAndIncrement()
        pending[id] = cb
        s.send(json("t" to t, "id" to id, "path" to path))
    }

    /**
     * Why files cannot go to or from the Mac now, or null. Bluetooth is too slow for files, and a file blocks the
     * messages behind it. The Mac also refuses files on Bluetooth.
     */
    fun unavailable(): String? {
        val s = Hub.session ?: return "Not connected to your Mac."
        return if (s.kind == LinkKind.BLUETOOTH) "Files cannot go over Bluetooth. Connect through Wi-Fi or a USB cable." else null
    }

    /** Returns an error message, or null when the download started. */
    fun download(ctx: Context, f: RemoteFile): String? {
        unavailable()?.let { return it }
        val s = Hub.session ?: return "Not connected to your Mac."
        val id = ids.getAndIncrement()
        val item = Item(id, f.name, upload = false, total = f.size)
        items.add(0, item)
        try {
            incoming[id] = downloadsTarget(ctx.applicationContext, safeName(f.name), -1, item, replyDone = false)
            s.send(json("t" to "fs.get", "id" to id, "path" to f.path))
        } catch (e: Exception) {
            item.state = State.FAILED; item.error = e.message
        }
        changed(true)
        return null
    }

    // Open the files now: a share or picker grant can end when its activity closes.
    fun open(ctx: Context, uris: List<Uri>): List<Source> = uris.mapNotNull { uri ->
        try {
            var name = uri.lastPathSegment ?: "file"
            var size = -1L
            ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
            val input = ctx.contentResolver.openInputStream(uri) ?: return@mapNotNull null
            Source(safeName(name), size, input)
        } catch (e: Exception) {
            Log.w(TAG, "cannot open a shared file: ${e.javaClass.simpleName}")
            null
        }
    }

    /** Returns an error message, or null when the upload started. */
    fun upload(sources: List<Source>, dir: String?): String? {
        val s = Hub.session
        val error = unavailable()
        if (s == null || error != null) {
            sources.forEach { try { it.input.close() } catch (_: Exception) {} }
            return error ?: "Not connected to your Mac."
        }
        val queued = sources.map { src ->
            val item = Item(ids.getAndIncrement(), src.name, upload = true, total = src.size)
            items.add(0, item)
            src to item
        }
        changed(true)
        thread(name = "phonelink-upload") {
            for ((src, item) in queued) {
                if (!item.active) { try { src.input.close() } catch (_: Exception) {}; continue }
                val snd = Sending(item)
                sending[item.id] = snd
                try {
                    s.send(json("t" to "fs.put", "id" to item.id, "dir" to dir, "name" to src.name, "size" to src.size))
                    src.input.use { stream(s, item.id, it, snd) }
                    if (snd.cancelled) {
                        sending.remove(item.id)
                        s.send(json("t" to "fs.cancel", "id" to item.id))
                    } else {
                        s.send(json("t" to "fs.end", "id" to item.id))
                    }
                } catch (e: Exception) {
                    sending.remove(item.id)
                    if (item.active) { item.state = State.FAILED; item.error = e.message }
                    s.send(json("t" to "fs.cancel", "id" to item.id))
                }
                changed(true)
            }
        }
        return null
    }

    fun cancel(item: Item) {
        if (!item.active) return
        item.state = State.CANCELLED
        sending[item.id]?.cancelled = true
        incoming.remove(item.id)?.abort()
        Hub.session?.send(json("t" to "fs.cancel", "id" to item.id))
        changed(true)
    }

    fun clearFinished() { items.removeAll { !it.active }; changed(true) }

    private fun updateNotification() {
        val ctx = Hub.service ?: return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val active = items.filter { it.active }
        if (active.isEmpty()) { nm.cancel(3); return }
        val total = active.sumOf { it.total.coerceAtLeast(0) }
        val done = active.sumOf { it.done }
        val up = active.count { it.upload }
        val title = when {
            active.size == 1 && up == 1 -> "Sending ${active[0].name}"
            active.size == 1 -> "Receiving ${active[0].name}"
            up == active.size -> "Sending ${active.size} files"
            else -> "Copying ${active.size} files"
        }
        val open = PendingIntent.getActivity(ctx, 3, Intent(ctx, MacFilesActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(ctx, "files")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle(title)
            .setContentText(Hub.session?.macName ?: "")
            .setProgress(1000, if (total > 0) (done * 1000 / total).toInt() else 0, total <= 0)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        nm.notify(3, n)
    }

    private fun notifyReceived(ctx: Context, name: String, uri: Uri?, mac: String) {
        val b = Notification.Builder(ctx, "files")
            .setSmallIcon(R.drawable.ic_notif)
            .setContentTitle(name)
            .setContentText(if (uri != null) "From $mac · Saved in Download/Phone Link" else "From $mac")
            .setAutoCancel(true)
        if (uri != null) {
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeOf(name) ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            b.setContentIntent(PendingIntent.getActivity(ctx, uri.hashCode(), view, PendingIntent.FLAG_IMMUTABLE))
        }
        ctx.getSystemService(NotificationManager::class.java).notify(1000 + (name.hashCode() and 0xfff), b.build())
    }
}
