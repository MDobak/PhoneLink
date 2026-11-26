package com.mdobak.phonelink

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Remote control via accessibility. Coordinates from the Mac are 0..1 of the screen. */
class InputService : AccessibilityService() {
    companion object {
        @Volatile var instance: InputService? = null
        fun require(): InputService = instance ?: throw IllegalStateException("Screen control is off. On the phone, turn on Phone Link screen control in Accessibility settings.")
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onServiceConnected() { instance = this; Hub.permsChanged() }
    override fun onUnbind(intent: Intent?): Boolean { instance = null; Hub.permsChanged(); return super.onUnbind(intent) }
    override fun onDestroy() { if (instance === this) instance = null; super.onDestroy() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> selectionChanged(event)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> windowChanged(event)
        }
    }
    override fun onInterrupt() {}

    private fun screen(display: Int = Display.DEFAULT_DISPLAY): Pair<Int, Int> {
        val m = DisplayMetrics()
        val d = getSystemService(DisplayManager::class.java).getDisplay(display)
            ?: throw IllegalStateException("Display $display is closed.")
        @Suppress("DEPRECATION") d.getRealMetrics(m)
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
        dispatchGesture(GestureDescription.Builder().addStroke(strokeOf(list)).build(), null, null)
    }

    /** One stroke through the points, with the time of the last point as its duration. */
    private fun strokeOf(list: List<Triple<Float, Float, Long>>): GestureDescription.StrokeDescription {
        val first = list[0]
        val path = Path().apply { moveTo(first.first, first.second) }
        for (i in 1 until list.size) path.lineTo(list[i].first, list[i].second)
        if (list.size == 1) path.lineTo(first.first, first.second)
        val duration = (list.last().third - first.third).coerceIn(1, 59_000)
        return GestureDescription.StrokeDescription(path, 0, duration)
    }

    // Accessibility services cannot inject single touch events, so a stroke is sent in parts that continue
    // each other (willContinue). A part is sent only after the previous one completes. Main thread only.

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

    // The last selected text, kept only in memory. While the phone is locked, Android gives no clipboard data to any
    // app or to the shell, so a copy in an app window reaches the Mac as this text (Session "clip.selection").

    private val selLock = Any()
    private var selText: String? = null
    private var selActive = false
    /** Uptime when the selection was last not empty. */
    private var selSeen = 0L

    private fun selectionChanged(e: AccessibilityEvent) {
        var text: CharSequence? = e.text.firstOrNull()
        var s = e.fromIndex
        var end = e.toIndex
        var password = e.isPassword
        if (text == null || s < 0 || end < 0) {
            val n = e.source
            text = n?.text
            s = n?.textSelectionStart ?: -1
            end = n?.textSelectionEnd ?: -1
            password = password || n?.isPassword == true
        }
        val a = minOf(s, end)
        val b = maxOf(s, end)
        val now = SystemClock.uptimeMillis()
        synchronized(selLock) {
            if (!password && text != null && a >= 0 && b > a && b <= text.length) {
                selText = text.subSequence(a, b).toString()
                selActive = true
                selSeen = now
            } else {
                // A copy often clears the selection, so keep the text for a short time.
                if (selActive) selSeen = now
                selActive = false
                if (password) selText = null
            }
        }
    }

    /** The selected text, or the text that was selected in the last few seconds. */
    fun recentSelection(maxAgeMs: Long = 5000): String? = synchronized(selLock) {
        selText?.takeIf { selActive || SystemClock.uptimeMillis() - selSeen <= maxAgeMs }
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

    // Agent tools (Agent.kt): the app in front, the screen as a tree of elements, element actions and screenshots.

    @Volatile var frontClass: String? = null
        private set
    @Volatile private var frontPkg: String? = null

    fun frontPackage(): String? = (try { rootInActiveWindow?.packageName?.toString() } catch (_: Exception) { null }) ?: frontPkg

    private fun windowChanged(e: AccessibilityEvent) {
        val p = e.packageName?.toString() ?: return
        val c = e.className?.toString() ?: return
        // Dialogs and views also send this event. Keep only activities.
        try {
            packageManager.getActivityInfo(ComponentName(p, c), PackageManager.ComponentInfoFlags.of(0))
            frontPkg = p
            frontClass = c
        } catch (_: Exception) {}
    }

    private val nodeLock = Any()
    private var nodes: Map<Int, AccessibilityNodeInfo> = emptyMap()

    /** The elements on the screen. The ids stay valid until the next call. With waitFor, waits until a text shows. */
    fun agentTree(which: String, waitFor: String, timeoutMs: Long, maxNodes: Int, display: Int): JSONObject {
        val start = SystemClock.uptimeMillis()
        val end = start + timeoutMs.coerceIn(0, 120_000)
        // A new app window on the Mac: the app can need some time to show its controls on the new display.
        val settle = if (display != Display.DEFAULT_DISPLAY) start + 4000 else 0L
        while (true) {
            val (o, map) = tree(which, maxNodes.coerceIn(50, 5000), display)
            val found = waitFor.isEmpty() || map.values.any { matches(it, waitFor) }
            val now = SystemClock.uptimeMillis()
            if (map.isEmpty() && waitFor.isEmpty() && now < settle) { Thread.sleep(300); continue }
            if (found || now >= end) {
                synchronized(nodeLock) { nodes = map }
                if (waitFor.isNotEmpty()) o.put("found", found)
                return o
            }
            Thread.sleep(300)
        }
    }

    private fun matches(n: AccessibilityNodeInfo, s: String) =
        n.text?.toString()?.contains(s, true) == true || n.contentDescription?.toString()?.contains(s, true) == true

    private fun typeName(t: Int) = when (t) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "app"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "keyboard"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "divider"
        AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY -> "magnification"
        else -> "other"
    }

    private fun tree(which: String, max: Int, display: Int): Pair<JSONObject, Map<Int, AccessibilityNodeInfo>> {
        val map = HashMap<Int, AccessibilityNodeInfo>()
        val (w, h) = screen(display)
        val out = JSONArray()
        val budget = intArrayOf(max)
        // An app window on the Mac has its own virtual display.
        val list = try {
            if (display == Display.DEFAULT_DISPLAY) windows.orEmpty() else windowsOnAllDisplays.get(display).orEmpty()
        } catch (_: Exception) { emptyList() }
        for (win in list.sortedByDescending { it.layer }) {
            if (win.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue
            if (which == "active" && !win.isActive && win.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            val root = win.root ?: continue
            val kids = JSONArray()
            walk(root, kids, map, budget, 0)
            out.put(json("type" to typeName(win.type), "title" to win.title?.toString(), "package" to root.packageName?.toString(),
                "active" to win.isActive, "elements" to kids))
        }
        if (out.length() == 0 && display == Display.DEFAULT_DISPLAY) rootInActiveWindow?.let { root ->
            val kids = JSONArray()
            walk(root, kids, map, budget, 0)
            out.put(json("type" to "app", "package" to root.packageName?.toString(), "active" to true, "elements" to kids))
        }
        val o = json("screen" to JSONArray(listOf(w, h)), "windows" to out)
        if (display == Display.DEFAULT_DISPLAY) o.put("front", frontPackage()) else o.put("display", display)
        if (budget[0] <= 0) o.put("truncated", true)
        return o to map
    }

    private fun walk(n: AccessibilityNodeInfo, out: JSONArray, map: HashMap<Int, AccessibilityNodeInfo>, budget: IntArray, depth: Int) {
        if (depth > 80 || budget[0] <= 0 || !n.isVisibleToUser) return
        val text = n.text?.toString()?.takeIf { it.isNotBlank() }
        val desc = n.contentDescription?.toString()?.takeIf { it.isNotBlank() }
        val hint = n.hintText?.toString()?.takeIf { it.isNotBlank() }
        val keep = text != null || desc != null || hint != null ||
            n.isClickable || n.isLongClickable || n.isEditable || n.isScrollable || n.isCheckable
        var target = out
        var o: JSONObject? = null
        if (keep) {
            budget[0]--
            val id = map.size + 1
            map[id] = n
            val r = Rect()
            n.getBoundsInScreen(r)
            val e = json("id" to id, "class" to (n.className?.toString()?.substringAfterLast('.') ?: "View"),
                "bounds" to JSONArray(listOf(r.left, r.top, r.right, r.bottom)))
            if (text != null) e.put("text", if (n.isPassword) "(password)" else text.take(300))
            if (desc != null) e.put("desc", desc.take(300))
            if (hint != null && hint != text) e.put("hint", hint.take(100))
            n.viewIdResourceName?.substringAfter(":id/")?.let { e.put("res", it) }
            val f = JSONArray()
            if (n.isClickable) f.put("clickable")
            if (n.isLongClickable) f.put("long_clickable")
            if (n.isEditable) f.put("editable")
            if (n.isScrollable) f.put("scrollable")
            if (n.isCheckable) f.put(if (n.isChecked) "checked" else "unchecked")
            if (n.isSelected) f.put("selected")
            if (n.isFocused) f.put("focused")
            if (!n.isEnabled) f.put("disabled")
            if (f.length() > 0) e.put("flags", f)
            out.put(e)
            o = e
            target = JSONArray()
        }
        for (i in 0 until n.childCount) n.getChild(i)?.let { walk(it, target, map, budget, depth + 1) }
        if (o != null && target.length() > 0) o.put("children", target)
    }

    private fun ancestor(n: AccessibilityNodeInfo, test: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        var c: AccessibilityNodeInfo? = n
        var d = 0
        while (c != null && d++ < 25) { if (test(c)) return c; c = c.parent }
        return null
    }

    private fun center(n: AccessibilityNodeInfo): Pair<Float, Float> {
        val r = Rect()
        n.getBoundsInScreen(r)
        return r.exactCenterX() to r.exactCenterY()
    }

    private fun textArgs(t: String) = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, t) }

    private fun nodeAction(n: AccessibilityNodeInfo, action: String, a: JSONObject, display: Int): Boolean = when (action) {
        "click", "tap" -> ancestor(n) { it.isClickable }?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            ?: center(n).let { (x, y) -> stroke(listOf(Triple(x, y, 0L), Triple(x, y, 60L)), display); true }
        "long_click", "long_press" -> ancestor(n) { it.isLongClickable }?.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
            ?: center(n).let { (x, y) -> stroke(listOf(Triple(x, y, 0L), Triple(x, y, 800L)), display); true }
        "focus" -> n.performAction(AccessibilityNodeInfo.ACTION_FOCUS) || n.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
        "set_text" -> n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, textArgs(a.optString("text")))
        "clear" -> n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, textArgs(""))
        "scroll_forward", "scroll_down" -> ancestor(n) { it.isScrollable }?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD) ?: false
        "scroll_backward", "scroll_up" -> ancestor(n) { it.isScrollable }?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD) ?: false
        "select" -> n.performAction(AccessibilityNodeInfo.ACTION_SELECT)
        "expand" -> n.performAction(AccessibilityNodeInfo.ACTION_EXPAND)
        "collapse" -> n.performAction(AccessibilityNodeInfo.ACTION_COLLAPSE)
        "dismiss" -> n.performAction(AccessibilityNodeInfo.ACTION_DISMISS)
        "copy" -> n.performAction(AccessibilityNodeInfo.ACTION_COPY)
        "paste" -> n.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        "cut" -> n.performAction(AccessibilityNodeInfo.ACTION_CUT)
        "show_on_screen" -> n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SHOW_ON_SCREEN.id)
        else -> throw IllegalStateException("Unknown element action \"$action\".")
    }

    /** Does a gesture in screen pixels and waits until it ends. Not on the main thread. */
    private fun stroke(list: List<Triple<Float, Float, Long>>, display: Int) {
        val (w, h) = screen(display)
        val pts = list.map { Triple(it.first.coerceIn(0f, w - 1f), it.second.coerceIn(0f, h - 1f), it.third) }
        val l = CountDownLatch(1)
        var ok = false
        main.post {
            live = null
            val sent = dispatchGesture(GestureDescription.Builder().setDisplayId(display).addStroke(strokeOf(pts)).build(),
                object : GestureResultCallback() {
                    override fun onCompleted(d: GestureDescription?) { ok = true; l.countDown() }
                    override fun onCancelled(d: GestureDescription?) { l.countDown() }
                }, main)
            if (!sent) l.countDown()
        }
        l.await(pts.last().third + 5000, TimeUnit.MILLISECONDS)
        if (!ok) throw IllegalStateException("The phone did not do the gesture.")
    }

    private fun px(a: JSONObject, k: String): Float =
        if (a.has(k)) a.getDouble(k).toFloat() else throw IllegalStateException("Give \"$k\" in screen pixels.")

    fun agentAct(a: JSONObject): JSONObject {
        val action = a.getString("action")
        val display = a.optInt("display", Display.DEFAULT_DISPLAY)
        fun stroke(list: List<Triple<Float, Float, Long>>) = stroke(list, display)
        if (a.has("element")) {
            val id = a.getInt("element")
            val n = synchronized(nodeLock) { nodes[id] } ?: throw IllegalStateException("No element $id. Read the screen again with screen_read.")
            if (!n.refresh()) throw IllegalStateException("Element $id is not on the screen now. Read the screen again with screen_read.")
            if (!nodeAction(n, action, a, display)) throw IllegalStateException("The element did not accept the action \"$action\".")
            return json("done" to true)
        }
        when (action) {
            "tap" -> { val x = px(a, "x"); val y = px(a, "y"); stroke(listOf(Triple(x, y, 0L), Triple(x, y, 60L))) }
            "double_tap" -> {
                val x = px(a, "x"); val y = px(a, "y")
                stroke(listOf(Triple(x, y, 0L), Triple(x, y, 40L)))
                Thread.sleep(60)
                stroke(listOf(Triple(x, y, 0L), Triple(x, y, 40L)))
            }
            "long_press" -> { val x = px(a, "x"); val y = px(a, "y"); stroke(listOf(Triple(x, y, 0L), Triple(x, y, a.optLong("duration", 800)))) }
            "swipe" -> stroke(listOf(Triple(px(a, "x"), px(a, "y"), 0L), Triple(px(a, "x2"), px(a, "y2"), a.optLong("duration", 300).coerceAtLeast(50))))
            "drag" -> {
                val x = px(a, "x"); val y = px(a, "y")
                val hold = 700L
                stroke(listOf(Triple(x, y, 0L), Triple(x, y, hold), Triple(px(a, "x2"), px(a, "y2"), hold + a.optLong("duration", 800).coerceAtLeast(100))))
            }
            "back", "home", "recents", "notifications", "quick_settings", "lock", "power", "screenshot" -> global(action)
            "key" -> {
                val k = a.getString("key")
                if (k != "escape" && focusedInput() == null) throw IllegalStateException("No text field has the focus.")
                key(k)
            }
            "type" -> {
                if (focusedInput() == null) throw IllegalStateException("No text field has the focus. Tap a text field first.")
                typeText(a.getString("text"))
            }
            else -> throw IllegalStateException("Unknown action \"$action\".")
        }
        return json("done" to true)
    }

    /** Android allows one screenshot each second. */
    fun agentScreenshot(maxSide: Int, png: Boolean, quality: Int, display: Int): JSONObject {
        var bmp: Bitmap? = null
        var err: Int? = null
        for (attempt in 0..2) {
            val l = CountDownLatch(1)
            takeScreenshot(display, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(r: ScreenshotResult) {
                    try {
                        val hb = r.hardwareBuffer
                        bmp = Bitmap.wrapHardwareBuffer(hb, r.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
                        hb.close()
                    } catch (e: Exception) { Log.w("InputService", "screenshot: $e") }
                    l.countDown()
                }
                override fun onFailure(code: Int) { err = code; l.countDown() }
            })
            l.await(5, TimeUnit.SECONDS)
            if (bmp != null || err != ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT) break
            err = null
            Thread.sleep(1100)
        }
        val b = bmp ?: throw IllegalStateException(when (err) {
            ERROR_TAKE_SCREENSHOT_SECURE_WINDOW -> "The app on the screen does not allow screenshots."
            ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS -> "On the phone, turn Phone Link screen control off and on again in Accessibility settings."
            else -> "The phone did not take a screenshot."
        })
        val s = minOf(1f, maxSide.coerceIn(200, 4000).toFloat() / maxOf(b.width, b.height))
        val out = if (s < 1f) Bitmap.createScaledBitmap(b, (b.width * s).toInt().coerceAtLeast(1), (b.height * s).toInt().coerceAtLeast(1), true) else b
        val bytes = ByteArrayOutputStream()
        out.compress(if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, quality.coerceIn(30, 100), bytes)
        return json("mime" to if (png) "image/png" else "image/jpeg", "data" to Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP),
            "width" to out.width, "height" to out.height, "screenWidth" to b.width, "screenHeight" to b.height)
    }
}
