package com.mdobak.phonelink

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Now playing and media controls. Needs notification access. */
object Media {
    private val main = Handler(Looper.getMainLooper())
    private var msm: MediaSessionManager? = null
    private var ctx: Context? = null
    private var controller: MediaController? = null
    private var sentArt: String? = null

    private val sessions = MediaSessionManager.OnActiveSessionsChangedListener { pick(it) }
    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) { schedule() }
        override fun onMetadataChanged(metadata: MediaMetadata?) { schedule() }
        override fun onSessionDestroyed() { refresh() }
    }
    private val pushNow = Runnable { push() }

    fun start(listener: NotifListener) = main.post {
        val m = listener.getSystemService(MediaSessionManager::class.java)
        msm = m
        ctx = listener.applicationContext
        val cn = ComponentName(listener, NotifListener::class.java)
        try {
            m.addOnActiveSessionsChangedListener(sessions, cn, main)
            pick(m.getActiveSessions(cn))
        } catch (_: SecurityException) {}
    }

    fun stop() = main.post {
        try { msm?.removeOnActiveSessionsChangedListener(sessions) } catch (_: Exception) {}
        controller?.unregisterCallback(callback)
        controller = null
        msm = null
    }

    private fun refresh() {
        val c = ctx ?: return
        try { pick(msm?.getActiveSessions(ComponentName(c, NotifListener::class.java))) } catch (_: Exception) { pick(null) }
    }

    private fun pick(list: List<MediaController>?) {
        val best = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = best
            best?.registerCallback(callback, main)
        }
        schedule()
    }

    private fun schedule() {
        main.removeCallbacks(pushNow)
        main.postDelayed(pushNow, 150)
    }

    fun sessionStarted() = main.post { sentArt = null; refresh(); push() }

    private fun push() {
        if (Hub.session == null) return
        Hub.send(current())
    }

    private fun current(): JSONObject {
        // Another session can start to play while the current one is paused.
        val c = controller ?: return json("t" to "media", "active" to false)
        val md = c.metadata
        val ps = c.playbackState
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md?.description?.title?.toString()
        if (title.isNullOrBlank() || ps == null || ps.state == PlaybackState.STATE_NONE || ps.state == PlaybackState.STATE_STOPPED) {
            return json("t" to "media", "active" to false)
        }
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: md?.description?.subtitle?.toString()
        val album = md?.getString(MediaMetadata.METADATA_KEY_ALBUM)
        val playing = ps.state == PlaybackState.STATE_PLAYING || ps.state == PlaybackState.STATE_BUFFERING
        var pos = ps.position
        if (ps.state == PlaybackState.STATE_PLAYING && ps.lastPositionUpdateTime > 0) {
            pos += ((SystemClock.elapsedRealtime() - ps.lastPositionUpdateTime) * ps.playbackSpeed).toLong()
        }
        val duration = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        val artKey = "${c.packageName}|$title|$artist|$album"
        val o = json(
            "t" to "media", "active" to true,
            "pkg" to c.packageName, "app" to appLabel(c.packageName),
            "title" to title, "artist" to artist, "album" to album,
            "playing" to playing,
            "position" to pos.coerceAtLeast(0), "duration" to duration,
            "canNext" to (ps.actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L),
            "canPrevious" to (ps.actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L),
            "canSeek" to (ps.actions and PlaybackState.ACTION_SEEK_TO != 0L && duration > 0),
            "artKey" to artKey,
        )
        if (artKey != sentArt) {
            val bmp = md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md?.getBitmap(MediaMetadata.METADATA_KEY_ART)
                ?: md?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            o.put("art", bmp?.let { jpeg(it) } ?: JSONObject.NULL)
            sentArt = artKey
        }
        return o
    }

    private fun appLabel(pkg: String): String = try {
        val pm = ctx?.packageManager ?: return pkg
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun jpeg(b: Bitmap): String? = try {
        val side = 240
        val scale = minOf(1f, side.toFloat() / maxOf(b.width, b.height))
        val s = if (scale < 1f) Bitmap.createScaledBitmap(b, (b.width * scale).toInt().coerceAtLeast(1), (b.height * scale).toInt().coerceAtLeast(1), true) else b
        val out = ByteArrayOutputStream()
        s.compress(Bitmap.CompressFormat.JPEG, 85, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

    fun command(m: JSONObject) = main.post {
        val c = controller ?: return@post
        val t = c.transportControls
        when (m.optString("action")) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "previous" -> t.skipToPrevious()
            "seek" -> t.seekTo(m.optLong("position"))
        }
    }
}
