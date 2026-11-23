package com.mdobak.phonelink

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Typeface
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.VibratorManager
import android.text.InputType
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import java.util.Properties
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Shells run on the Mac (RemoteTerminal.swift); TerminalHub keeps the tabs.
 * The emulator and view are vendored Termux code (package com.termux, see third_party/termux/NOTICE).
 */
class TerminalActivity : UiActivity(), TerminalHub.Ui, TerminalViewClient {
    private lateinit var root: LinearLayout
    private lateinit var subtitle: TextView
    private lateinit var tabRow: LinearLayout
    private lateinit var tabScroll: HorizontalScrollView
    private lateinit var tabStrip: LinearLayout
    private lateinit var term: TerminalView
    private lateinit var banner: TextView
    private lateinit var overlay: LinearLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayBody: TextView
    private lateinit var overlayProgress: ProgressBar
    private lateinit var exitBar: LinearLayout
    private lateinit var exitText: TextView
    private lateinit var keyBar: LinearLayout
    private lateinit var ctrlKey: TextView
    private lateinit var altKey: TextView

    /** 0 = off, 1 = next key only, 2 = locked. */
    private var ctrl = 0
    private var alt = 0
    private var fontPx = 0
    private var unlocked = false
    private var visible = false
    private var lastBell = 0L
    private val handler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("terminal", MODE_PRIVATE) }
    private val recheck = Runnable { renderState() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The shell output is private: no screenshots, no recent-apps preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        window.setDecorFitsSystemWindows(false)
        applyColors()
        fontPx = prefs.getInt("fontPx", 0).takeIf { it > 0 } ?: sp(13f)
        setContentView(build())
        root.visibility = View.INVISIBLE
    }

    override fun onStart() {
        super.onStart()
        visible = true
        RemoteGate.unlock(this, "Use Terminal on your Mac", ok = {
            // The prompt can end after onStop, and onStop will not come again to detach.
            if (!visible) return@unlock
            unlocked = true
            root.visibility = View.VISIBLE
            TerminalHub.attach(this)
            tabsChanged()
            renderState()
            handler.postDelayed(recheck, 6500)
            term.requestFocus()
        }, failed = { finish() })
    }

    override fun onStop() {
        visible = false
        RemoteGate.left()
        TerminalHub.detach(this)
        handler.removeCallbacks(recheck)
        unlocked = false
        super.onStop()
    }

    private fun sp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v, resources.displayMetrics).toInt()

    private fun build(): View {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(color(R.color.bg))
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                val ime = insets.getInsets(WindowInsets.Type.ime())
                v.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
                WindowInsets.CONSUMED
            }
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(4), dp(4), 0)
        }
        bar.addView(iconButton(R.drawable.ic_arrow_back, "Back") { finish() }, LinearLayout.LayoutParams(dp(48), dp(48)))
        val titles = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(8), 0, 0, 0) }
        titles.addView(label("Terminal", 20f, medium = true).apply { maxLines = 1 })
        subtitle = label("", 13f, R.color.on_surface_variant).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
        titles.addView(subtitle)
        bar.addView(titles, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(iconButton(R.drawable.ic_clipboard, "Paste") { pasteClipboard() }, LinearLayout.LayoutParams(dp(48), dp(48)))
        root.addView(bar)

        tabRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(4), dp(6))
        }
        tabStrip = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        tabScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFillViewport = false
            addView(tabStrip)
        }
        tabRow.addView(tabScroll, LinearLayout.LayoutParams(0, dp(40), 1f))
        tabRow.addView(iconButton(R.drawable.ic_add, "New tab") { addTab() }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginStart = dp(4) })
        root.addView(tabRow)

        val area = SwipeFrame()
        term = TerminalView(this, null).apply {
            setTerminalViewClient(this@TerminalActivity)
            setTextSize(fontPx)
            setTypeface(Typeface.MONOSPACE)
            isFocusable = true
            isFocusableInTouchMode = true
            setPadding(dp(4), 0, dp(4), 0)
        }
        area.addView(term, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT).apply {
            leftMargin = dp(6); rightMargin = dp(2)
        })
        banner = label("", 13f, R.color.on_primary_container).apply {
            background = rounded(R.color.primary_container, 16)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            visibility = View.GONE
        }
        area.addView(banner, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(8) })

        exitBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(R.color.surface, 24)
            elevation = dp(2).toFloat()
            setPadding(dp(20), dp(4), dp(8), dp(4))
            visibility = View.GONE
        }
        exitText = label("", 15f).apply { maxLines = 3 }
        exitBar.addView(exitText, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        exitBar.addView(textButton("Restart") { current()?.let { TerminalHub.restart(it) } })
        exitBar.addView(textButton("Close") { current()?.let { closeTab(it, ask = false) } })
        area.addView(exitBar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM).apply { setMargins(dp(12), 0, dp(12), dp(12)) })

        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(color(R.color.bg))
            setPadding(dp(32), 0, dp(32), dp(48))
            isClickable = true
            visibility = View.GONE
        }
        overlayProgress = ProgressBar(this).apply {
            isIndeterminate = true
            indeterminateTintList = ColorStateList.valueOf(color(R.color.primary))
        }
        overlay.addView(overlayProgress, LinearLayout.LayoutParams(dp(36), dp(36)).apply { bottomMargin = dp(16) })
        overlayTitle = label("", 20f).apply { gravity = Gravity.CENTER }
        overlay.addView(overlayTitle)
        overlayBody = label("", 15f, R.color.on_surface_variant).apply { gravity = Gravity.CENTER; setPadding(0, dp(8), 0, 0) }
        overlay.addView(overlayBody)
        area.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(area, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        // Swipe this row left or right to change tabs.
        keyBar = KeyBar().apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(color(R.color.surface))
            setPadding(dp(4), dp(2), dp(4), dp(2))
        }
        for (k in listOf("Esc", "Tab", "Ctrl", "Alt", "←", "↑", "↓", "→", "|", "~", "/", "-")) {
            val v = keyView(k)
            if (k == "Ctrl") ctrlKey = v
            if (k == "Alt") altKey = v
            keyBar.addView(v, LinearLayout.LayoutParams(0, dp(44), 1f))
        }
        root.addView(keyBar)
        return root
    }

    private fun iconButton(res: Int, desc: String, onClick: () -> Unit) = ImageButton(this).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(color(R.color.on_surface))
        background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 24))
        contentDescription = desc
        tooltipText = desc
        setOnClickListener { onClick() }
    }

    private fun keyView(k: String): TextView = TextView(this).apply {
        text = k
        gravity = Gravity.CENTER
        isAllCaps = false
        val word = k.length > 1
        textSize = if (word) 13f else 17f
        typeface = if (word) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.MONOSPACE
        setTextColor(color(R.color.on_surface))
        background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 12))
        contentDescription = when (k) { "←" -> "Left"; "→" -> "Right"; "↑" -> "Up"; "↓" -> "Down"; "|" -> "Vertical bar"; "~" -> "Tilde"; "/" -> "Slash"; "-" -> "Hyphen"; else -> k }
        isHapticFeedbackEnabled = true
        if (k in listOf("←", "↑", "↓", "→")) {
            var repeat: Runnable? = null
            setOnTouchListener { v, e ->
                when (e.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.isPressed = true
                        v.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                        extraKey(k)
                        val r = object : Runnable { override fun run() { extraKey(k); handler.postDelayed(this, 60) } }
                        repeat = r
                        handler.postDelayed(r, 400)
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.isPressed = false
                        repeat?.let { handler.removeCallbacks(it) }
                        repeat = null
                    }
                }
                true
            }
        } else {
            setOnClickListener { v ->
                v.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                extraKey(k)
            }
        }
    }

    /** A two-finger swipe changes tabs; a pinch is not a swipe. */
    private inner class SwipeFrame : FrameLayout(this@TerminalActivity) {
        private var sx = 0f; private var sy = 0f; private var span = 0f
        private var tracking = false; private var fired = false

        private fun avgX(e: MotionEvent) = (e.getX(0) + e.getX(1)) / 2
        private fun avgY(e: MotionEvent) = (e.getY(0) + e.getY(1)) / 2
        private fun span(e: MotionEvent) = hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1))

        private fun track(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { tracking = false; fired = false }
                MotionEvent.ACTION_POINTER_DOWN -> if (e.pointerCount == 2) {
                    sx = avgX(e); sy = avgY(e); span = span(e); tracking = true
                }
                MotionEvent.ACTION_MOVE -> if (tracking && !fired && e.pointerCount >= 2) {
                    val dx = avgX(e) - sx
                    val dy = avgY(e) - sy
                    if (abs(dx) > dp(72) && abs(dx) > 2 * abs(dy) && abs(span(e) - span) < dp(48)) {
                        fired = true
                        switchTab(if (dx < 0) 1 else -1)
                    }
                }
                MotionEvent.ACTION_POINTER_UP -> tracking = false
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> tracking = false
            }
            return fired
        }

        override fun onInterceptTouchEvent(e: MotionEvent) = track(e)
        override fun onTouchEvent(e: MotionEvent): Boolean { track(e); return true }
    }

    private inner class KeyBar : LinearLayout(this@TerminalActivity) {
        private var sx = 0f; private var sy = 0f; private var swiping = false

        override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { sx = e.x; sy = e.y; swiping = false }
                MotionEvent.ACTION_MOVE -> if (!swiping && abs(e.x - sx) > dp(24) && abs(e.x - sx) > 1.5f * abs(e.y - sy)) swiping = true
            }
            return swiping
        }

        override fun onTouchEvent(e: MotionEvent): Boolean {
            if (e.actionMasked == MotionEvent.ACTION_UP && swiping) {
                val dx = e.x - sx
                if (abs(dx) > dp(48)) switchTab(if (dx < 0) 1 else -1)
                swiping = false
            }
            return true
        }
    }

    /** The cursor uses the wallpaper accent. */
    private fun applyColors() {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val dark = arrayOf("#3b3f46", "#ef6b73", "#8fc77b", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4",
            "#6b717d", "#f78c94", "#b0dc9c", "#f0d29c", "#8ccaf7", "#d9a0e9", "#80cbd5", "#ffffff")
        val light = arrayOf("#383a42", "#d1373f", "#3e8e3d", "#a46b00", "#2f6fd6", "#a33aa1", "#11819a", "#9a9ca3",
            "#5e626e", "#e5545c", "#4da64b", "#c18401", "#4a86f0", "#bf4dbd", "#1aa0b8", "#c8c9cc")
        val p = Properties()
        val pal = if (night) dark else light
        pal.forEachIndexed { i, c -> p["color$i"] = c }
        p["foreground"] = if (night) "#e6e6e6" else "#24262b"
        p["background"] = String.format("#%06x", color(R.color.bg) and 0xffffff)
        p["cursor"] = String.format("#%06x", color(R.color.primary) and 0xffffff)
        try { TerminalColors.COLOR_SCHEME.updateWith(p) } catch (e: Exception) { Log.w("Terminal", "colors: ${e.message}") }
        TerminalHub.tabs.forEach { it.session.emulator?.mColors?.reset() }
    }

    private fun changeFont(bigger: Boolean) {
        val n = (fontPx + if (bigger) sp(1f).coerceAtLeast(2) else -sp(1f).coerceAtLeast(2)).coerceIn(sp(7f), sp(32f))
        if (n == fontPx) return
        fontPx = n
        term.setTextSize(n)
        prefs.edit().putInt("fontPx", n).apply()
    }

    private fun current(): TerminalHub.Tab? = TerminalHub.find(TerminalHub.currentId)

    private fun addTab() {
        when {
            Hub.session == null -> toast("Not connected to your Mac.")
            TerminalHub.state == "disabled" -> toast("Terminal is off on your Mac.")
            TerminalHub.tabs.size >= TerminalHub.MAX_TABS -> toast("You can open up to ${TerminalHub.MAX_TABS} tabs.")
            else -> TerminalHub.newTab()
        }
    }

    private fun select(t: TerminalHub.Tab) {
        TerminalHub.currentId = t.id
        tabsChanged()
    }

    private fun switchTab(delta: Int) {
        val list = TerminalHub.tabs
        if (list.size < 2) return
        val i = list.indexOfFirst { it.id == TerminalHub.currentId }
        val n = (i + delta).coerceIn(0, list.size - 1)
        if (n != i) {
            term.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
            select(list[n])
        }
    }

    private fun closeTab(t: TerminalHub.Tab, ask: Boolean) {
        val run = {
            TerminalHub.close(t)
            if (TerminalHub.tabs.isEmpty()) finish()
        }
        if (!ask || t.exitCode != null || !t.everOpened) { run(); return }
        AlertDialog.Builder(this)
            .setTitle("Close this tab?")
            .setMessage("The shell and the programs in it stop on your Mac.")
            .setPositiveButton("Close") { _, _ -> run() }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun closeOthers(t: TerminalHub.Tab) {
        AlertDialog.Builder(this)
            .setTitle("Close other tabs?")
            .setMessage("The shells in the other tabs stop on your Mac.")
            .setPositiveButton("Close") { _, _ -> TerminalHub.closeOthers(t) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun rename(t: TerminalHub.Tab) {
        val input = EditText(this).apply {
            setText(t.customTitle ?: t.title)
            setSelectAllOnFocus(true)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            maxLines = 1
        }
        val box = FrameLayout(this).apply { setPadding(dp(24), dp(8), dp(24), 0); addView(input) }
        AlertDialog.Builder(this)
            .setTitle("Rename tab")
            .setView(box)
            .setPositiveButton("Rename") { _, _ -> TerminalHub.rename(t, input.text.toString()) }
            .setNeutralButton("Use shell title") { _, _ -> TerminalHub.rename(t, null) }
            .setNegativeButton("Cancel", null)
            .show()
        input.requestFocus()
    }

    private fun tabMenu(t: TerminalHub.Tab, anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add(0, 1, 0, "Rename")
            menu.add(0, 2, 1, "Close")
            if (TerminalHub.tabs.size > 1) menu.add(0, 3, 2, "Close others")
            setOnMenuItemClickListener {
                when (it.itemId) { 1 -> rename(t); 2 -> closeTab(t, ask = true); 3 -> closeOthers(t) }
                true
            }
            show()
        }
    }

    private fun tabView(t: TerminalHub.Tab, selected: Boolean): View {
        val chip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), 0, if (selected) dp(6) else dp(16), 0)
            background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)),
                if (selected) rounded(R.color.primary_container, 20) else null, rounded(R.color.surface, 20))
            setOnClickListener { if (!selected) select(t) }
            setOnLongClickListener { tabMenu(t, it); true }
            contentDescription = t.title + if (selected) ", selected" else ""
        }
        val exited = t.exitCode != null
        chip.addView(TextView(this).apply {
            text = t.title
            textSize = 14f
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            maxWidth = dp(160)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(color(if (selected) R.color.on_primary_container else R.color.on_surface_variant))
            alpha = if (exited) 0.6f else 1f
        })
        if (selected) chip.addView(ImageButton(this).apply {
            setImageResource(R.drawable.ic_close)
            imageTintList = ColorStateList.valueOf(color(R.color.on_primary_container))
            background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 14))
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(5), dp(5), dp(5), dp(5))
            contentDescription = "Close tab"
            setOnClickListener { closeTab(t, ask = true) }
        }, LinearLayout.LayoutParams(dp(28), dp(28)).apply { marginStart = dp(4) })
        chip.layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36)).apply { marginEnd = dp(4) }
        return chip
    }

    override fun tabsChanged() {
        if (!unlocked) return
        val tabs = TerminalHub.tabs
        if (TerminalHub.find(TerminalHub.currentId) == null) TerminalHub.currentId = tabs.firstOrNull()?.id ?: 0
        val cur = current()
        tabStrip.removeAllViews()
        var selectedView: View? = null
        for (t in tabs) {
            val v = tabView(t, t === cur)
            if (t === cur) selectedView = v
            tabStrip.addView(v)
        }
        selectedView?.let { v -> tabScroll.post { tabScroll.smoothScrollTo(maxOf(0, v.left - dp(48)), 0) } }
        if (cur != null && term.currentSession !== cur.session) {
            term.attachSession(cur.session)
            term.onScreenUpdated()
        } else if (cur != null && cur.session.isInitialized && term.mEmulator !== cur.session.emulator) {
            // The Mac reattached the shell while this screen was away.
            showEmulator(cur)
        }
        renderExit()
        renderState()
    }

    override fun screenUpdated(tab: TerminalHub.Tab) {
        if (unlocked && tab.id == TerminalHub.currentId) term.onScreenUpdated()
    }

    override fun screenReset(tab: TerminalHub.Tab) {
        if (!unlocked || tab.id != TerminalHub.currentId) return
        showEmulator(tab)
        renderExit()
    }

    /** The emulator can change (TerminalSession.recreateEmulator), so always show the current one. */
    private fun showEmulator(tab: TerminalHub.Tab) {
        term.mEmulator = tab.session.emulator
        term.setTopRow(0)
        term.onScreenUpdated()
        term.invalidate()
    }

    override fun stateChanged() { if (unlocked) renderState() }

    override fun bell() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastBell < 300) return
        lastBell = now
        getSystemService(VibratorManager::class.java)?.defaultVibrator
            ?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
    }

    override fun copy(text: String) {
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Terminal", text))
    }

    override fun paste(tab: TerminalHub.Tab) = pasteClipboard()

    private fun pasteClipboard() {
        val t = current() ?: return
        val clip = getSystemService(ClipboardManager::class.java)?.primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        if (text.isNullOrEmpty()) { toast("The clipboard is empty."); return }
        t.session.emulator?.paste(text)
    }

    private fun renderExit() {
        val t = current()
        val code = t?.exitCode
        if (t == null || code == null) { exitBar.visibility = View.GONE; return }
        val head = if (code >= 0) "Process exited (code $code)" else "Process exited"
        exitText.text = if (t.exitMessage != null) "$head\n${t.exitMessage}" else head
        exitBar.visibility = View.VISIBLE
    }

    private fun renderState() {
        if (!unlocked) return
        val s = Hub.session
        subtitle.text = s?.macName?.takeIf { it.isNotEmpty() } ?: "Not connected"
        val hasTabs = TerminalHub.tabs.isNotEmpty()
        val waiting = TerminalHub.state == "unknown"
        val slow = waiting && TerminalHub.askedAt > 0 && System.currentTimeMillis() - TerminalHub.askedAt > 6000
        when {
            TerminalHub.state == "disabled" ->
                showOverlay("Terminal is off", TerminalHub.stateMessage ?: "Turn it on in Phone Link Settings > Remote Access on your Mac.", false)
            s == null && !hasTabs ->
                showOverlay("Mac not connected", "Open Phone Link on your Mac, then open Terminal again.", false)
            slow && !hasTabs ->
                showOverlay("Your Mac does not answer", "Update Phone Link on your Mac, then try again.", false)
            waiting && !hasTabs -> showOverlay("Connecting to your Mac", "", true)
            else -> {
                overlay.visibility = View.GONE
                tabRow.visibility = View.VISIBLE
                keyBar.visibility = View.VISIBLE
            }
        }
        val note = when {
            !hasTabs || TerminalHub.state == "disabled" -> null
            s == null -> "Not connected. Your tabs come back when your Mac connects."
            slow -> "Your Mac does not answer."
            waiting -> "Connecting to your Mac…"
            else -> null
        }
        banner.text = note ?: ""
        banner.visibility = if (note != null) View.VISIBLE else View.GONE
    }

    private fun showOverlay(title: String, body: String, progress: Boolean) {
        overlayTitle.text = title
        overlayBody.text = body
        overlayBody.visibility = if (body.isEmpty()) View.GONE else View.VISIBLE
        overlayProgress.visibility = if (progress) View.VISIBLE else View.GONE
        overlay.visibility = View.VISIBLE
        tabRow.visibility = View.GONE
        keyBar.visibility = View.GONE
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    private fun extraKey(k: String) {
        when (k) {
            "Ctrl" -> { ctrl = (ctrl + 1) % 3; renderMods(); return }
            "Alt" -> { alt = (alt + 1) % 3; renderMods(); return }
        }
        val session: TerminalSession = term.currentSession ?: return
        if (term.mEmulator == null) return
        val mods = (if (ctrl > 0) KeyHandler.KEYMOD_CTRL else 0) or (if (alt > 0) KeyHandler.KEYMOD_ALT else 0)
        when (k) {
            "Esc" -> session.write(27.toChar().toString())
            "Tab" -> term.handleKeyCode(KeyEvent.KEYCODE_TAB, mods)
            "←" -> term.handleKeyCode(KeyEvent.KEYCODE_DPAD_LEFT, mods)
            "→" -> term.handleKeyCode(KeyEvent.KEYCODE_DPAD_RIGHT, mods)
            "↑" -> term.handleKeyCode(KeyEvent.KEYCODE_DPAD_UP, mods)
            "↓" -> term.handleKeyCode(KeyEvent.KEYCODE_DPAD_DOWN, mods)
            else -> term.inputCodePoint(TerminalView.KEY_EVENT_SOURCE_VIRTUAL_KEYBOARD, k.codePointAt(0), ctrl > 0, alt > 0)
        }
        useMods()
    }

    private fun useMods() {
        var changed = false
        if (ctrl == 1) { ctrl = 0; changed = true }
        if (alt == 1) { alt = 0; changed = true }
        if (changed) renderMods()
    }

    private fun renderMods() {
        for ((v, st) in listOf(ctrlKey to ctrl, altKey to alt)) {
            val bg = when (st) { 1 -> rounded(R.color.primary_container, 12); 2 -> rounded(R.color.primary, 12); else -> rounded(R.color.surface, 12) }
            v.background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), bg, rounded(R.color.surface, 12))
            v.setTextColor(color(when (st) { 1 -> R.color.on_primary_container; 2 -> R.color.on_primary; else -> R.color.on_surface }))
            val name = if (v === ctrlKey) "Ctrl" else "Alt"
            v.text = if (st == 2) "$name •" else name
            v.stateDescription = when (st) { 1 -> "On for the next key"; 2 -> "Locked"; else -> "Off" }
        }
    }

    override fun onScale(scale: Float): Float {
        if (scale < 0.9f || scale > 1.1f) {
            changeFont(scale > 1f)
            return 1f
        }
        return scale
    }

    override fun onSingleTapUp(e: MotionEvent) {
        val emu = term.mEmulator
        if (emu != null) {
            val cr = term.getColumnAndRow(e, true)
            val word = emu.screen.getWordAtLocation(cr[0], cr[1])
            val url = word?.let { URL.find(it)?.value?.trimEnd('.', ',', ')', ';', ':', '\'', '"') }
            if (!url.isNullOrEmpty()) { openUrl(url); return }
        }
        term.requestFocus()
        getSystemService(InputMethodManager::class.java)?.showSoftInput(term, 0)
    }

    private fun openUrl(url: String) {
        val full = if (url.startsWith("www.")) "https://$url" else url
        AlertDialog.Builder(this)
            .setTitle("Open link?")
            .setMessage(full)
            .setPositiveButton("Open") { _, _ ->
                try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(full))) } catch (e: Exception) { toast("No app can open this link.") }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    override fun shouldBackButtonBeMappedToEscape() = false
    // Samsung Keyboard and others send keys directly with this input type.
    override fun shouldEnforceCharBasedInput() = true
    override fun shouldUseCtrlSpaceWorkaround() = false
    override fun isTerminalViewSelected() = true
    override fun copyModeChanged(copyMode: Boolean) {}

    override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession?): Boolean {
        if (e.isCtrlPressed && e.isShiftPressed) {
            when (keyCode) {
                KeyEvent.KEYCODE_T -> { addTab(); return true }
                KeyEvent.KEYCODE_W -> { current()?.let { closeTab(it, ask = true) }; return true }
                KeyEvent.KEYCODE_V -> { pasteClipboard(); return true }
                KeyEvent.KEYCODE_C -> { if (term.isSelectingText) { copy(term.selectedText ?: ""); term.stopTextSelectionMode() }; return true }
            }
        }
        if (e.isCtrlPressed && keyCode == KeyEvent.KEYCODE_TAB) { switchTab(if (e.isShiftPressed) -1 else 1); return true }
        if (e.isCtrlPressed && keyCode == KeyEvent.KEYCODE_PAGE_DOWN) { switchTab(1); return true }
        if (e.isCtrlPressed && keyCode == KeyEvent.KEYCODE_PAGE_UP) { switchTab(-1); return true }
        if (!KeyEvent.isModifierKey(keyCode)) handler.post { useMods() }
        return false
    }

    override fun onKeyUp(keyCode: Int, e: KeyEvent) = false
    override fun onLongPress(event: MotionEvent) = false
    override fun readControlKey() = ctrl > 0
    override fun readAltKey() = alt > 0
    override fun readShiftKey() = false
    override fun readFnKey() = false

    override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean {
        handler.post { useMods() }
        return false
    }

    override fun onEmulatorSet() {}
    // Messages can quote terminal text, which is private: log only the length.
    override fun logError(tag: String?, message: String?) { Log.e("Terminal", "$tag: message of ${message?.length ?: 0} characters") }
    override fun logWarn(tag: String?, message: String?) { Log.w("Terminal", "$tag: message of ${message?.length ?: 0} characters") }
    override fun logInfo(tag: String?, message: String?) {}
    override fun logDebug(tag: String?, message: String?) {}
    override fun logVerbose(tag: String?, message: String?) {}
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) { Log.e("Terminal", "$tag: ${e?.javaClass?.name}") }
    override fun logStackTrace(tag: String?, e: Exception?) { Log.e("Terminal", "$tag: ${e?.javaClass?.name}") }

    companion object {
        private val URL = Regex("(https?://|www\\.)[^\\s<>\"'`]+")
    }
}
