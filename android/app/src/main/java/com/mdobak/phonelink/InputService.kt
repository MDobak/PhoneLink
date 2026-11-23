package com.mdobak.phonelink

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.DisplayMetrics
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray

/** Remote control via accessibility. Coordinates from the Mac are 0..1 of the screen. */
class InputService : AccessibilityService() {
    companion object {
        @Volatile var instance: InputService? = null
        fun require(): InputService = instance ?: throw IllegalStateException("Screen control is off. On the phone, turn on Phone Link screen control in Accessibility settings.")
    }

    override fun onServiceConnected() { instance = this; Hub.changed() }
    override fun onUnbind(intent: android.content.Intent?): Boolean { instance = null; Hub.changed(); return super.onUnbind(intent) }
    override fun onDestroy() { if (instance === this) instance = null; super.onDestroy() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    @Suppress("DEPRECATION")
    private fun screen(): Pair<Int, Int> {
        val m = DisplayMetrics()
        getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(m)
        return m.widthPixels to m.heightPixels
    }

    /** points: [[x, y, ms], ...]. One point is a tap; a long time on one point is a long press. */
    fun gesture(points: JSONArray) {
        if (points.length() == 0) return
        val (w, h) = screen()
        val list = (0 until points.length()).map { i ->
            points.getJSONArray(i).let { Triple((it.getDouble(0) * w).toFloat().coerceIn(0f, w - 1f), (it.getDouble(1) * h).toFloat().coerceIn(0f, h - 1f), it.optLong(2)) }
        }
        main.post { live = null; replay(list) }
    }

    private fun replay(list: List<Triple<Float, Float, Long>>) {
        if (list.isEmpty()) return
        val first = list[0]
        val path = Path().apply { moveTo(first.first, first.second) }
        for (i in 1 until list.size) path.lineTo(list[i].first, list[i].second)
        if (list.size == 1) path.lineTo(first.first, first.second)
        val duration = (list.last().third - first.third).coerceIn(1, 59_000)
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    // Accessibility services cannot inject single touch events, so a stroke is sent in parts that continue
    // each other (willContinue). A part is sent only after the previous one completes. Main thread only.

    private val main = Handler(Looper.getMainLooper())

    private class Live(val start: Long, var x: Float, var y: Float) {
        var stroke: GestureDescription.StrokeDescription? = null
        var time = start
        val pending = ArrayList<Triple<Float, Float, Long>>()
        val all = arrayListOf(Triple(x, y, 0L))
        var busy = false
        var up = false
        var failed = false
    }

    private var live: Live? = null

    fun touch(action: String, nx: Double, ny: Double) {
        val (w, h) = screen()
        val x = (nx * w).toFloat().coerceIn(0f, w - 1f)
        val y = (ny * h).toFloat().coerceIn(0f, h - 1f)
        main.post {
            stopScroll()
            liveTouch(action, x, y)
        }
    }

    private fun liveTouch(action: String, x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        if (action == "down") {
            // A new gesture cancels a stroke that is still open.
            val l = Live(now, x, y)
            live = l
            next(l)
            return
        }
        val l = live ?: return
        if (l.up) return
        // A stroke cannot be cancelled: lift the finger at its last position.
        val p = if (action == "cancel") Triple(l.all.last().first, l.all.last().second, now - l.start) else Triple(x, y, now - l.start)
        l.all.add(p)
        if (action == "up" || action == "cancel") l.up = true
        if (action == "move" || p.first != l.x || p.second != l.y) l.pending.add(p)
        if (l.failed) {
            if (l.up && !l.busy) fallback(l)
            return
        }
        if (!l.busy) next(l)
    }

    private fun next(l: Live) {
        if (live !== l || l.busy || l.failed) return
        val first = l.stroke == null
        if (!first && l.pending.isEmpty() && !l.up) return
        val path = Path().apply { moveTo(l.x, l.y) }
        var end = l.time
        for (p in l.pending) { path.lineTo(p.first, p.second); end = p.third + l.start }
        if (l.pending.isEmpty()) path.lineTo(l.x, l.y)
        // Use the real time between points so fling speed is right, but cap it to keep latency low.
        val duration = if (l.pending.isEmpty()) 1L else (end - l.time).coerceIn(8, 40)
        val last = l.pending.lastOrNull()
        val willContinue = !l.up
        val stroke = try {
            l.stroke?.continueStroke(path, 0, duration, willContinue)
                ?: GestureDescription.StrokeDescription(path, 0, duration, willContinue)
        } catch (e: Exception) {
            Log.w("InputService", "stroke: $e")
            fail(l)
            return
        }
        l.pending.clear()
        if (last != null) { l.x = last.first; l.y = last.second }
        l.time = end
        l.stroke = stroke
        l.busy = true
        val ok = dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), object : GestureResultCallback() {
            override fun onCompleted(d: GestureDescription?) {
                l.busy = false
                if (!willContinue) { if (live === l) live = null; return }
                next(l)
            }

            override fun onCancelled(d: GestureDescription?) {
                l.busy = false
                if (live === l) fail(l)
            }
        }, main)
        if (!ok) { l.busy = false; fail(l) }
    }

    /** The phone rejected a stroke part: send the full gesture at the end. */
    private fun fail(l: Live) {
        l.failed = true
        if (l.up) fallback(l)
    }

    private fun fallback(l: Live) {
        if (live === l) live = null
        replay(l.all)
    }

    // Accessibility services cannot send scroll events. A scroll becomes a one-finger drag that lifts
    // when no scroll arrives for a short time.

    private var scrollAt: Pair<Float, Float>? = null
    private val scrollEnd = Runnable { stopScroll() }

    private fun stopScroll() {
        val p = scrollAt ?: return
        scrollAt = null
        main.removeCallbacks(scrollEnd)
        liveTouch("up", p.first, p.second)
    }

    /** With lines, dx and dy are wheel steps. Else they are fractions of the screen size. Positive dy moves the content down. */
    fun scroll(nx: Double, ny: Double, dx: Double, dy: Double, lines: Boolean) {
        val (w, h) = screen()
        val line = 64 * resources.displayMetrics.density
        val mx = (if (lines) dx * line else dx * w).toFloat()
        val my = (if (lines) dy * line else dy * h).toFloat()
        main.post {
            var p = scrollAt
            if (p == null) {
                p = (nx * w).toFloat().coerceIn(0f, w - 1f) to (ny * h).toFloat().coerceIn(0f, h - 1f)
                liveTouch("down", p.first, p.second)
            }
            p = (p.first + mx).coerceIn(0f, w - 1f) to (p.second + my).coerceIn(0f, h - 1f)
            scrollAt = p
            liveTouch("move", p.first, p.second)
            main.removeCallbacks(scrollEnd)
            main.postDelayed(scrollEnd, 120)
        }
    }

    fun global(action: String) {
        val a = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "lock" -> GLOBAL_ACTION_LOCK_SCREEN
            "power" -> GLOBAL_ACTION_POWER_DIALOG
            "screenshot" -> GLOBAL_ACTION_TAKE_SCREENSHOT
            else -> return
        }
        performGlobalAction(a)
    }

    private fun focusedInput(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }

    private fun current(n: AccessibilityNodeInfo): String =
        if (n.isShowingHintText) "" else (n.text?.toString() ?: "")

    private fun setText(n: AccessibilityNodeInfo, text: String, cursor: Int) {
        n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        })
        n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
        })
    }

    private fun selection(n: AccessibilityNodeInfo, len: Int): Pair<Int, Int> {
        var s = n.textSelectionStart
        var e = n.textSelectionEnd
        if (s < 0 || e < 0 || s > len || e > len) { s = len; e = len }
        return minOf(s, e) to maxOf(s, e)
    }

    fun typeText(text: String) {
        val n = focusedInput() ?: return
        val cur = current(n)
        val (s, e) = selection(n, cur.length)
        setText(n, cur.substring(0, s) + text + cur.substring(e), s + text.length)
    }

    fun key(key: String) {
        if (key == "escape") { performGlobalAction(GLOBAL_ACTION_BACK); return }
        val n = focusedInput() ?: return
        val cur = current(n)
        val (s, e) = selection(n, cur.length)
        when (key) {
            "backspace" -> when {
                s != e -> setText(n, cur.substring(0, s) + cur.substring(e), s)
                s > 0 -> {
                    val cut = Character.offsetByCodePoints(cur, s, -1)
                    setText(n, cur.substring(0, cut) + cur.substring(s), cut)
                }
            }
            "delete" -> when {
                s != e -> setText(n, cur.substring(0, s) + cur.substring(e), s)
                s < cur.length -> setText(n, cur.substring(0, s) + cur.substring(Character.offsetByCodePoints(cur, s, 1)), s)
            }
            "enter" -> n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            "left" -> if (s > 0) setText(n, cur, s - 1)
            "right" -> if (e < cur.length) setText(n, cur, e + 1)
            "select_all" -> n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cur.length)
            })
            "copy" -> n.performAction(AccessibilityNodeInfo.ACTION_COPY)
            "paste" -> n.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            "cut" -> n.performAction(AccessibilityNodeInfo.ACTION_CUT)
        }
    }
}
