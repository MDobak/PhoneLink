package com.mdobak.phonelink

import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper

/** Helpers for code that runs with app_process as the shell user (ShellServer, ShellAgent). */
object Shell {
    const val PACKAGE = "com.android.shell"

    // A shell package context, which system services need for permission checks. Leaves the global ActivityThread
    // alone because the mirror display needs its original state. First use must be on a Looper thread.
    val context: Context by lazy {
        val at = Class.forName("android.app.ActivityThread")
        val t = at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        val system = at.getDeclaredMethod("getSystemContext").apply { isAccessible = true }.invoke(t) as Context
        object : ContextWrapper(system) {
            override fun getPackageName() = PACKAGE
            override fun getOpPackageName() = PACKAGE
            override fun getAttributionSource(): AttributionSource = AttributionSource.Builder(2000).setPackageName(PACKAGE).build()
            override fun getApplicationContext(): Context = this
            // The system context's resolver sends package "android", which the shell does not own.
            override fun getContentResolver(): android.content.ContentResolver = ShellContent.resolver
        }
    }

    // In app_process an uncaught exception in any thread kills the process and the Mac loses the helper.
    // Logs only the class and top frame (messages can contain private data). Exits with code 1 only on the calling thread.
    fun guardThreads() {
        val main = Thread.currentThread()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                System.err.println("uncaught (" + (if (t === main) "main" else t.name) + "): " + e.javaClass.name +
                    (e.stackTrace.firstOrNull()?.let { " at $it" } ?: ""))
            } catch (_: Throwable) {}
            if (t === main) kotlin.system.exitProcess(1)
        }
    }

    // Calls a hidden service method whose parameters change between Android versions. Tries overloads from longest
    // to shortest. Leading values go first; then the first String gets the package name, other objects get null,
    // ints and longs get 0 (user 0, default device), Booleans get false. Throws the last overload's error.
    fun call(target: Any, name: String, vararg leading: Any?): Any? {
        val methods = target.javaClass.methods.filter { it.name == name }.sortedByDescending { it.parameterTypes.size }
        var last: Throwable? = null
        for (m in methods) {
            val types = m.parameterTypes
            if (types.size < leading.size) continue
            var pkgDone = false
            val args = Array<Any?>(types.size) { i ->
                if (i < leading.size) leading[i]
                else when (types[i]) {
                    String::class.java -> if (!pkgDone) { pkgDone = true; PACKAGE } else null
                    Int::class.javaPrimitiveType -> 0
                    Boolean::class.javaPrimitiveType -> false
                    Long::class.javaPrimitiveType -> 0L
                    else -> null
                }
            }
            try { return m.invoke(target, *args) } catch (e: Throwable) { last = e.cause ?: e }
        }
        throw last ?: NoSuchMethodException(name)
    }

    fun service(name: String): android.os.IBinder =
        Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, name) as android.os.IBinder?
            ?: throw IllegalStateException("The system service $name is not available.")

    fun asInterface(stub: String, binder: android.os.IBinder): Any =
        Class.forName("$stub\$Stub").getMethod("asInterface", android.os.IBinder::class.java).invoke(null, binder)
            ?: throw IllegalStateException("No interface $stub.")

    /** A value from the settings provider. table: global, secure or system. */
    fun setting(table: String, name: String): String? = try {
        ShellContent.resolver.query(android.net.Uri.parse("content://settings/$table"), arrayOf("value"), "name=?", arrayOf(name), null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (_: Exception) { null }

    fun iconPng(pkg: String, size: Int): String {
        val d = context.packageManager.getApplicationIcon(pkg)
        val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(android.graphics.Canvas(bmp))
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
    }
}
