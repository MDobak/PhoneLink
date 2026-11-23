package com.mdobak.phonelink

import android.content.AttributionSource
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.ConcurrentHashMap

/**
 * Read-only content provider access for the shell user. An app_process process has no app record, so the usual
 * resolver cannot get providers. This uses getContentProviderExternal (like the "content" command) with the shell
 * attribution. Write calls throw.
 */
object ShellContent {
    val resolver: ContentResolver by lazy { wrap(Forward()) }

    // ContentResolver.wrap gives a resolver with no context, so it falls back to the application context, which
    // app_process lacks. Use the hidden constructor that takes a context.
    private fun wrap(p: ContentProvider): ContentResolver {
        val iface = Class.forName("android.content.ContentInterface")
        for (i in 1..9) {
            val cls = try { Class.forName("android.content.ContentResolver\$$i") } catch (_: ClassNotFoundException) { continue }
            if (cls.superclass != ContentResolver::class.java) continue
            val ctor = try { cls.getDeclaredConstructor(android.content.Context::class.java, iface) } catch (_: NoSuchMethodException) { continue }
            ctor.isAccessible = true
            return ctor.newInstance(Shell.context, p) as ContentResolver
        }
        return ContentResolver.wrap(p)
    }

    private val am: Any by lazy { Shell.asInterface("android.app.IActivityManager", Shell.service("activity")) }
    private val token = Binder()
    private val providers = ConcurrentHashMap<String, Any>()
    private val source: AttributionSource by lazy { AttributionSource.Builder(2000).setPackageName(Shell.PACKAGE).build() }

    private fun provider(uri: Uri): Any {
        // Authorities can start with "userId@". The shell reads user 0 only.
        val name = (uri.authority ?: throw IllegalArgumentException("The URI has no authority.")).substringAfter('@')
        providers[name]?.let { return it }
        val holder = Shell.call(am, "getContentProviderExternal", name, 0, token, "phonelink")
            ?: throw SecurityException("The provider $name is not available.")
        val p = holder.javaClass.getField("provider").get(holder) ?: throw SecurityException("The provider $name is not available.")
        providers[name] = p
        return p
    }

    // AttributionSource parameters get the shell attribution. The first other parameter gets the URI, the rest
    // get the values in order.
    private fun invoke(uri: Uri, name: String, vararg values: Any?): Any? {
        val p = provider(uri)
        val src = AttributionSource::class.java
        val m = p.javaClass.methods.firstOrNull { mm -> mm.name == name && mm.parameterTypes.count { it != src } == values.size + 1 }
            ?: throw NoSuchMethodException("IContentProvider.$name")
        val rest = ArrayDeque<Any?>(values.size + 1).apply { add(uri); addAll(values) }
        val args = m.parameterTypes.map { t -> if (t == src) source else rest.removeFirst() }.toTypedArray()
        try {
            return m.invoke(p, *args)
        } catch (e: InvocationTargetException) {
            val c = e.cause ?: e
            if (c is android.os.DeadObjectException) providers.remove(uri.authority?.substringAfter('@'))
            throw c
        }
    }

    // Not registered in the system. ContentResolver.wrap routes calls here and this forwards them to the real providers.
    private class Forward : ContentProvider() {
        override fun onCreate() = true

        override fun query(uri: Uri, projection: Array<out String>?, queryArgs: Bundle?, cancellationSignal: CancellationSignal?): Cursor? =
            invoke(uri, "query", projection, queryArgs, null) as Cursor?

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? =
            query(uri, projection, Bundle().apply {
                selection?.let { putString(ContentResolver.QUERY_ARG_SQL_SELECTION, it) }
                selectionArgs?.let { putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, it) }
                sortOrder?.let { putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, it) }
            }, null)

        override fun getType(uri: Uri): String? = invoke(uri, "getType") as String?

        override fun openFile(uri: Uri, mode: String, signal: CancellationSignal?): ParcelFileDescriptor? {
            require(mode == "r") { "Shell access is read-only." }
            return invoke(uri, "openFile", mode, null) as ParcelFileDescriptor?
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? = openFile(uri, mode, null)

        override fun openAssetFile(uri: Uri, mode: String, signal: CancellationSignal?): AssetFileDescriptor? {
            require(mode == "r") { "Shell access is read-only." }
            return invoke(uri, "openAssetFile", mode, null) as AssetFileDescriptor?
        }

        override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor? = openAssetFile(uri, mode, null)

        override fun openTypedAssetFile(uri: Uri, mimeTypeFilter: String, opts: Bundle?, signal: CancellationSignal?): AssetFileDescriptor? =
            invoke(uri, "openTypedAssetFile", mimeTypeFilter, opts, null) as AssetFileDescriptor?

        override fun openTypedAssetFile(uri: Uri, mimeTypeFilter: String, opts: Bundle?): AssetFileDescriptor? =
            openTypedAssetFile(uri, mimeTypeFilter, opts, null)

        // Shell access is read-only.
        override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Shell access is read-only.")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException("Shell access is read-only.")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
            throw UnsupportedOperationException("Shell access is read-only.")
    }
}
