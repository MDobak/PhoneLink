package com.mdobak.phonelink

import android.content.Context
import android.util.Base64

/** Paired Macs: id -> (name, long-term key), in private app storage. */
object Pairings {
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("pairings", Context.MODE_PRIVATE)

    fun key(ctx: Context, id: String): ByteArray? =
        prefs(ctx).getString("key.$id", null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    fun save(ctx: Context, id: String, name: String, key: ByteArray) {
        val p = prefs(ctx)
        val ids = p.getStringSet("ids", emptySet())!!.toMutableSet().apply { add(id) }
        p.edit()
            .putStringSet("ids", ids)
            .putString("name.$id", name)
            .putString("key.$id", Base64.encodeToString(key, Base64.NO_WRAP))
            .apply()
    }

    fun list(ctx: Context): List<Pair<String, String>> {
        val p = prefs(ctx)
        return p.getStringSet("ids", emptySet())!!.map { it to (p.getString("name.$it", it) ?: it) }.sortedBy { it.second }
    }

    fun remove(ctx: Context, id: String) {
        val p = prefs(ctx)
        val ids = p.getStringSet("ids", emptySet())!!.toMutableSet().apply { remove(id) }
        p.edit().putStringSet("ids", ids).remove("name.$id").remove("key.$id").apply()
    }
}
