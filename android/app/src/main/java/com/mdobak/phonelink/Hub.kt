package com.mdobak.phonelink

import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Shared state between the service, the current Mac session and the UI. */
object Hub {
    @Volatile var service: LinkService? = null
    @Volatile var session: Session? = null
    @Volatile var pairingUntil = 0L
    @Volatile var pairRequest: PairRequest? = null

    fun isPairing() = System.currentTimeMillis() < pairingUntil

    fun send(msg: JSONObject) { session?.send(msg) }

    class PairRequest(val macName: String, val sas: String) {
        private val latch = CountDownLatch(1)
        @Volatile private var accepted = false
        val resolved get() = latch.count == 0L
        fun resolve(ok: Boolean) { accepted = ok; latch.countDown() }
        fun await(): Boolean { latch.await(120, TimeUnit.SECONDS); return accepted }
    }

    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    fun addListener(l: () -> Unit) { listeners.add(l) }
    fun removeListener(l: () -> Unit) { listeners.remove(l) }
    fun changed() { main.post { listeners.forEach { it() } } }
    /** A service with a permission (accessibility, notifications) started or stopped. The Mac also gets the new status. */
    fun permsChanged() {
        changed()
        main.post { service?.takeIf { session != null }?.let { send(it.status()) } }
    }
}

fun json(vararg pairs: Pair<String, Any?>): JSONObject {
    val o = JSONObject()
    for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
    return o
}

fun <T> List<T>.toJsonArray(map: (T) -> Any?): JSONArray {
    val a = JSONArray()
    forEach { a.put(map(it)) }
    return a
}
