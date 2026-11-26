package com.mdobak.phonelink

import android.animation.ValueAnimator
import android.content.pm.ActivityInfo
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.KeyEvent
import android.view.Menu
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.Magnifier
import android.widget.PopupMenu
import android.widget.PopupWindow
import android.widget.ProgressBar
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Trackpad mode moves the Mac cursor relatively; touch mode clicks under the finger.
 * Tap the top edge or swipe down with three fingers to open the toolbar.
 */
class RemoteDesktopActivity : UiActivity(), RemoteDesktop.Listener {
    private enum class G { NONE, EDGE, ONE, DRAG_WAIT, DRAG, TDRAG, LONG, TWO, PINCH, SCROLL, PAN, TAP2, THREE, TAP3, DONE }

    private lateinit var root: FrameLayout
    private lateinit var video: TextureView
    /** Hides the video until it is interactive. The video view itself stays visible, else Android gives it no surface. */
    private lateinit var cover: View
    private lateinit var input: InputSurface
    private lateinit var toolbar: LinearLayout
    private lateinit var handle: View
    private lateinit var hint: TextView
    private lateinit var modeButton: ImageButton
    private lateinit var keyboardButton: ImageButton
    private lateinit var displayButton: ImageButton
    private lateinit var overlay: LinearLayout
    private lateinit var overlaySpinner: ProgressBar
    private lateinit var overlayTitle: TextView
    private lateinit var overlayText: TextView
    private lateinit var overlayAction: Button
    private lateinit var keysScroll: HorizontalScrollView
    private val modViews = arrayOfNulls<TextView>(4)
    private val modNames = arrayOf("Command", "Option", "Control", "Shift")

    private val handler = Handler(Looper.getMainLooper())
    private var videoSurface: Surface? = null
    private var visible = false
    private var unlocked = false
    private var started = false
    private var hasVideo = false
    private var timedOut = false
    private var shownOnce = false
    private var lastSession: Session? = null
    private var trackpad = true
    private var quality = "auto"
    private var displayId: Long? = null

    private val vp = RemoteViewport()
    private var lastZoom = 2.5f
    private var imeH = 0
    private var imeVisible = false
    private var topInset = 0
    private var animator: ValueAnimator? = null
    private val matrix = Matrix()

    private var g = G.NONE
    private var downX = 0f; private var downY = 0f; private var downT = 0L
    private var lastX = 0f; private var lastY = 0f; private var lastT = 0L
    private var moved = false
    private var lastTapT = 0L; private var lastTapX = 0f; private var lastTapY = 0f; private var lastTapClicks = 1
    private var startDist = 1f; private var startCx = 0f; private var startCy = 0f
    private var lastCx = 0f; private var lastCy = 0f; private var startZoom = 1f
    private var rawX = 0f; private var rawY = 0f
    private var multiDownT = 0L
    private var lastTwoTapT = 0L
    private var rightX = 0f; private var rightY = 0f
    private var leftHeld = false
    private var touchHeld = false
    private var vt: VelocityTracker? = null
    private var magnifier: Magnifier? = null
    private var momVx = 0f; private var momVy = 0f; private var momLast = 0L
    private var momActive = false
    private var mouseClicks = 1; private var mouseLastPress = 0L; private var mouseLastButton = ""
    private val slop by lazy { ViewConfiguration.get(this).scaledTouchSlop.toFloat() }

    private val keys = RemoteKeyboard(handler, live = { interactive() }, modsChanged = { updateMods() })

    private var toolbarShown = false
    private var popupOpen = false
    private val hideToolbar = Runnable { setToolbar(false) }
    private val hideHint = Runnable { hint.animate().alpha(0f).setDuration(200).start() }
    private val longPress = Runnable { onLongPress() }
    private val pendingRight = Runnable { rightClick(rightX, rightY) }
    private val connectTimeout = Runnable { if (RemoteDesktop.state == "connecting") { timedOut = true; render() } }
    private val hubListener: () -> Unit = { onHubChanged() }

    private val prefs by lazy { getSharedPreferences("remote_desktop", MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setDecorFitsSystemWindows(false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        trackpad = prefs.getString("mode", "trackpad") == "trackpad"
        quality = prefs.getString("quality", "auto") ?: "auto"

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        video = TextureView(this).apply {
            isOpaque = false
            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                    val s = Surface(st)
                    videoSurface = s
                    if (started) RemoteDesktop.attach(s) // Else begin() attaches it.
                    applyTransform()
                }
                override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) = applyTransform()
                override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                    RemoteDesktop.detach()
                    videoSurface?.release()
                    videoSurface = null
                    return true
                }
                override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
            }
        }
        root.addView(video, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        cover = View(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(cover, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        input = InputSurface()
        root.addView(input, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        buildKeysBar()
        buildToolbar()
        buildOverlay()

        root.setOnApplyWindowInsetsListener { _, insets -> onInsets(insets); insets }
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
            if (r - l != or - ol || b - t != ob - ot) relayout()
        }
        setContentView(root)
        hideSystemBars()
        onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, OnBackInvokedCallback {
            if (!interactive() || toolbarShown) finish() else showToolbar()
        })
        render()
    }

    override fun onStart() {
        super.onStart()
        visible = true
        RemoteGate.unlock(this, "Control your Mac from this phone", {
            unlocked = true
            if (visible) begin()
        }, { finish() })
    }

    override fun onStop() {
        visible = false
        end()
        RemoteGate.left()
        super.onStop()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        magnifier?.dismiss()
        vt?.recycle()
        vt = null
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun begin() {
        if (started) return
        started = true
        RemoteDesktop.listener = this
        Hub.addListener(hubListener)
        lastSession = Hub.session
        // end() stopped the decoder, but the surface may still be valid.
        videoSurface?.let { RemoteDesktop.attach(it) }
        startStream()
    }

    private fun end() {
        if (!started) return
        started = false
        stopMomentum()
        releaseHeld()
        keys.releaseMods()
        handler.removeCallbacks(connectTimeout)
        RemoteDesktop.stop()
        // Do not hold a hardware decoder while in the background.
        RemoteDesktop.detach()
        if (RemoteDesktop.listener === this) RemoteDesktop.listener = null
        Hub.removeListener(hubListener)
        hasVideo = false
    }

    private fun onHubChanged() {
        val s = Hub.session
        if (s === lastSession) return
        lastSession = s
        if (started && s != null) startStream() else render()
    }

    /** 2x the long side of the phone screen keeps zoomed text sharp. */
    private fun streamParams(): Pair<Int, Int> {
        val b = windowManager.maximumWindowMetrics.bounds
        val long = max(b.width(), b.height())
        return when (quality) {
            "fast" -> min(long, 1920) to 60
            "balanced" -> min(long * 3 / 2, 2560) to 60
            "sharp" -> min(long * 2, 2880) to 30
            else -> min(long * 2, 2880) to 60
        }
    }

    private fun startStream() {
        val (size, fps) = streamParams()
        hasVideo = false
        timedOut = false
        RemoteDesktop.start(displayId, quality, size, size, fps)
        handler.removeCallbacks(connectTimeout)
        handler.postDelayed(connectTimeout, 10_000)
        render()
    }

    override fun onRemoteState() {
        if (!started) return
        if (RemoteDesktop.state != "connecting") { timedOut = false; handler.removeCallbacks(connectTimeout) }
        if (RemoteDesktop.state != "streaming") { hasVideo = false; keys.forgetHeldKeys() }
        RemoteDesktop.display?.let { displayId = it }
        if (!hasVideo && RemoteDesktop.width > 0 && RemoteDesktop.height > 0) setVideoSize(RemoteDesktop.width.toFloat(), RemoteDesktop.height.toFloat())
        render()
    }

    override fun onCursor() {
        if (started && trackpad && g != G.PINCH && animator?.isRunning != true) followCursor()
    }

    override fun onVideoSize(width: Int, height: Int) {
        if (!started || width <= 0 || height <= 0) return
        setVideoSize(width.toFloat(), height.toFloat())
        if (!hasVideo && RemoteDesktop.state == "streaming") {
            hasVideo = true
            render()
            if (!shownOnce) { shownOnce = true; showToolbar(); showHint(if (trackpad) "Trackpad" else "Touch") }
        }
    }

    private fun interactive() = started && hasVideo && RemoteDesktop.state == "streaming"

    private fun render() {
        if (!::overlay.isInitialized) return
        val st = RemoteDesktop.state
        val mac = Hub.session?.macName ?: "your Mac"
        var title = ""
        var text = ""
        var spin = false
        var action: String? = null
        when {
            !unlocked -> {}
            Hub.session == null || st == "offline" -> {
                title = "Mac not connected"
                text = "Open Phone Link on your Mac."
                spin = true
            }
            st == "disabled" -> {
                title = "Remote Desktop is off"
                text = "Turn it on in Phone Link Settings > Remote Access on your Mac."
                action = "Try again"
            }
            st == "needsPermission" -> {
                val names = RemoteDesktop.missing.map {
                    when (it) { "screenRecording" -> "Screen Recording"; "accessibility" -> "Accessibility"; else -> it }
                }
                title = "Allow access on your Mac"
                text = "In System Settings > Privacy & Security, allow " +
                    names.ifEmpty { listOf("Screen Recording", "Accessibility") }.joinToString(" and ") + " for Phone Link."
                action = "Try again"
            }
            st == "stopped" -> {
                title = "Screen sharing stopped"
                text = RemoteDesktop.message.ifEmpty { "$mac stopped sharing its screen." }
                action = "Start again"
            }
            st == "streaming" && hasVideo -> {}
            timedOut -> {
                title = "No answer from $mac"
                text = "Update Phone Link on your Mac, then try again."
                action = "Try again"
            }
            else -> {
                title = "Connecting to $mac"
                spin = true
            }
        }
        val show = title.isNotEmpty()
        overlay.visibility = if (show) View.VISIBLE else View.GONE
        overlaySpinner.visibility = if (spin) View.VISIBLE else View.GONE
        overlayTitle.text = title
        overlayText.text = text
        overlayText.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
        overlayAction.visibility = if (action != null) View.VISIBLE else View.GONE
        overlayAction.text = action ?: ""
        cover.visibility = if (interactive()) View.GONE else View.VISIBLE
        handle.visibility = if (interactive() && !toolbarShown) View.VISIBLE else View.GONE
        if (!interactive()) { setToolbar(false); hideLoupe() }
        displayButton.visibility = if (RemoteDesktop.displays.size > 1) View.VISIBLE else View.GONE
        modeButton.setImageResource(if (trackpad) R.drawable.ic_rd_mouse else R.drawable.ic_rd_touch)
        modeButton.contentDescription = if (trackpad) "Switch to touch" else "Switch to trackpad"
        modeButton.tooltipText = modeButton.contentDescription
    }

    private fun pill(colorInt: Int, radius: Int) = GradientDrawable().apply { setColor(colorInt); cornerRadius = dp(radius).toFloat() }

    private fun buildOverlay() {
        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(40), dp(24), dp(40), dp(24))
        }
        overlaySpinner = ProgressBar(this).apply {
            isIndeterminate = true
            indeterminateTintList = ColorStateList.valueOf(getColor(android.R.color.system_accent1_200))
        }
        overlay.addView(overlaySpinner, LinearLayout.LayoutParams(dp(36), dp(36)).apply { bottomMargin = dp(20) })
        overlayTitle = TextView(this).apply {
            textSize = 22f
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
        }
        overlay.addView(overlayTitle)
        overlayText = TextView(this).apply {
            textSize = 15f
            setTextColor(0xB3FFFFFF.toInt())
            gravity = Gravity.CENTER
            setLineSpacing(0f, 1.15f)
            setPadding(0, dp(8), 0, 0)
        }
        overlay.addView(overlayText, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        })
        overlayAction = darkButton("Try again", true) { startStream() }
        overlay.addView(overlayAction, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)).apply { topMargin = dp(24) })
        overlay.addView(darkButton("Close", false) { finish() }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48)).apply { topMargin = dp(8) })
        root.addView(overlay, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    }

    private fun darkButton(text: String, filled: Boolean, onClick: () -> Unit) = Button(this, null, 0, 0).apply {
        this.text = text
        isAllCaps = false
        textSize = 15f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(if (filled) getColor(android.R.color.system_accent1_900) else getColor(android.R.color.system_accent1_200))
        background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), if (filled) pill(getColor(android.R.color.system_accent1_200), 24) else null, pill(Color.WHITE, 24))
        gravity = Gravity.CENTER
        includeFontPadding = false
        setPadding(dp(24), 0, dp(24), 0)
        minWidth = dp(120); minimumWidth = dp(120)
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    private fun buildToolbar() {
        toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = pill(0xE6202124.toInt(), 28)
            setPadding(dp(6), dp(4), dp(6), dp(4))
            elevation = dp(6).toFloat()
            visibility = View.GONE
            alpha = 0f
        }
        tool(R.drawable.ic_close, "Close") { finish() }
        modeButton = tool(R.drawable.ic_rd_mouse, "Input mode") { toggleMode() }
        keyboardButton = tool(R.drawable.ic_rd_keyboard, "Keyboard") { toggleKeyboard() }
        displayButton = tool(R.drawable.ic_rd_display, "Display") { showDisplays(it) }
        tool(R.drawable.ic_rd_tune, "Quality") { showQuality(it) }
        tool(R.drawable.ic_rd_fit, "Zoom to fit") { animateZoom(1f, vp.areaW / 2, vp.areaH / 2) }
        tool(R.drawable.ic_rd_more, "Mac actions") { showSystem(it) }
        root.addView(toolbar, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(12) })

        handle = View(this).apply { background = pill(0x80FFFFFF.toInt(), 3); visibility = View.GONE }
        root.addView(handle, FrameLayout.LayoutParams(dp(40), dp(5), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(6) })

        hint = TextView(this).apply {
            textSize = 15f
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = pill(0xCC202124.toInt(), 20)
            setPadding(dp(18), dp(10), dp(18), dp(10))
            alpha = 0f
        }
        root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    }

    private fun tool(icon: Int, label: String, onClick: (View) -> Unit): ImageButton {
        val b = ImageButton(this).apply {
            setImageResource(icon)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = RippleDrawable(ColorStateList.valueOf(0x40FFFFFF), null, pill(Color.WHITE, 24))
            contentDescription = label
            tooltipText = label
            setOnClickListener { v ->
                v.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                scheduleHide()
                onClick(v)
            }
        }
        toolbar.addView(b, LinearLayout.LayoutParams(dp(48), dp(48)))
        return b
    }

    private fun showToolbar() { setToolbar(true); scheduleHide() }

    private fun scheduleHide() {
        handler.removeCallbacks(hideToolbar)
        if (!popupOpen) handler.postDelayed(hideToolbar, 3000)
    }

    private fun setToolbar(show: Boolean) {
        if (show && !interactive()) return
        if (toolbarShown == show) return
        toolbarShown = show
        toolbar.animate().cancel()
        if (show) {
            toolbar.visibility = View.VISIBLE
            toolbar.translationY = -dp(16).toFloat()
            toolbar.animate().alpha(1f).translationY(0f).setDuration(180).start()
            handle.visibility = View.GONE
        } else {
            handler.removeCallbacks(hideToolbar)
            toolbar.animate().alpha(0f).translationY(-dp(16).toFloat()).setDuration(180).withEndAction { toolbar.visibility = View.GONE }.start()
            if (interactive()) handle.visibility = View.VISIBLE
        }
    }

    private fun toggleToolbar() = if (toolbarShown) setToolbar(false) else showToolbar()

    private fun showHint(text: String) {
        hint.text = text
        hint.animate().cancel()
        hint.animate().alpha(1f).setDuration(150).start()
        handler.removeCallbacks(hideHint)
        handler.postDelayed(hideHint, 1200)
    }

    private fun toggleMode() {
        releaseHeld()
        trackpad = !trackpad
        prefs.edit().putString("mode", if (trackpad) "trackpad" else "touch").apply()
        showHint(if (trackpad) "Trackpad" else "Touch")
        render()
    }

    private fun menu(anchor: View, build: (Menu) -> Unit, pick: (Int) -> Unit) {
        val p = PopupMenu(this, anchor)
        build(p.menu)
        p.setOnMenuItemClickListener { pick(it.itemId); true }
        p.setOnDismissListener { popupOpen = false; scheduleHide() }
        popupOpen = true
        handler.removeCallbacks(hideToolbar)
        p.show()
    }

    private val qualities = listOf("auto" to "Automatic", "fast" to "Fast", "balanced" to "Balanced", "sharp" to "Sharp")

    private fun showQuality(anchor: View) = menu(anchor, { m ->
        qualities.forEachIndexed { i, (k, name) -> m.add(1, i, i, name).isChecked = k == quality }
        m.setGroupCheckable(1, true, true)
    }) { i ->
        quality = qualities[i].first
        prefs.edit().putString("quality", quality).apply()
        val (size, fps) = streamParams()
        RemoteDesktop.setQuality(quality, size, size, fps)
    }

    private fun showDisplays(anchor: View) {
        val list = RemoteDesktop.displays
        menu(anchor, { m ->
            list.forEachIndexed { i, d -> m.add(1, i, i, d.name + if (d.main) " (main)" else "").isChecked = d.id == (displayId ?: RemoteDesktop.display) }
            m.setGroupCheckable(1, true, true)
        }) { i ->
            val d = list.getOrNull(i) ?: return@menu
            if (d.id == displayId) return@menu
            displayId = d.id
            vp.zoom = 1f
            startStream()
        }
    }

    private val systemActions = listOf(
        "missionControl" to "Mission Control", "appExpose" to "App windows", "launchpad" to "Launchpad",
        "spotlight" to "Spotlight", "playPause" to "Play or pause", "mute" to "Mute", "displaySleep" to "Turn off display",
        "lock" to "Lock screen",
    )

    private fun showSystem(anchor: View) = menu(anchor, { m ->
        systemActions.forEachIndexed { i, (_, name) -> m.add(0, i, i, name) }
    }) { i -> RemoteDesktop.system(systemActions[i].first) }

    private fun toggleKeyboard() {
        val imm = getSystemService(InputMethodManager::class.java)
        if (imeVisible) {
            imm.hideSoftInputFromWindow(input.windowToken, 0)
        } else {
            input.requestFocus()
            imm.showSoftInput(input, 0)
        }
    }

    private fun buildKeysBar() {
        keysScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFillViewport = true
            setBackgroundColor(color(R.color.bg))
            visibility = View.GONE
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        keysScroll.addView(row, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
        fun add(v: View) = row.addView(v, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
            marginStart = dp(2); marginEnd = dp(2)
        })
        add(keyView("esc", "Escape").apply { setOnClickListener { haptic(it); keys.typeKey(MacKeys.ESCAPE) } })
        add(keyView("tab", "Tab").apply { setOnClickListener { haptic(it); keys.typeKey(MacKeys.TAB) } })
        val symbols = arrayOf("⌘", "⌥", "⌃", "⇧")
        for (i in 0..3) {
            val v = keyView(symbols[i], modNames[i]).apply { textSize = 18f; setOnClickListener { haptic(it); keys.tapMod(i) } }
            modViews[i] = v
            add(v)
        }
        add(repeatKey("←", "Left", MacKeys.LEFT))
        add(repeatKey("↑", "Up", MacKeys.UP))
        add(repeatKey("↓", "Down", MacKeys.DOWN))
        add(repeatKey("→", "Right", MacKeys.RIGHT))
        add(keyView("•••", "More keys").apply { setOnClickListener { haptic(it); showMoreKeys() } })
        add(ImageButton(this).apply {
            setImageResource(R.drawable.ic_rd_keyboard_hide)
            imageTintList = ColorStateList.valueOf(color(R.color.on_surface))
            background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 10))
            contentDescription = "Hide keyboard"
            minimumWidth = dp(44)
            setOnClickListener { toggleKeyboard() }
        })
        root.addView(keysScroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52), Gravity.BOTTOM))
        updateMods()
    }

    private fun keyView(label: String, description: String) = TextView(this).apply {
        text = label
        contentDescription = description
        textSize = 15f
        gravity = Gravity.CENTER
        minWidth = dp(44); minimumWidth = dp(44)
        setPadding(dp(8), 0, dp(8), 0)
        setTextColor(color(R.color.on_surface))
        background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), rounded(R.color.surface, 10), null)
        isClickable = true
    }

    private fun repeatKey(label: String, description: String, code: Int) = keyView(label, description).apply {
        textSize = 18f
        var r: Runnable? = null
        setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    haptic(v)
                    keys.typeKey(code, consume = false)
                    val rep = object : Runnable { override fun run() { keys.typeKey(code, consume = false); handler.postDelayed(this, 45) } }
                    r = rep
                    handler.postDelayed(rep, 400)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    r?.let { handler.removeCallbacks(it) }
                    r = null
                    keys.consumeMods()
                }
            }
            true
        }
    }

    private fun haptic(v: View) { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) }

    private fun updateMods() {
        for (i in 0..3) {
            val v = modViews[i] ?: continue
            val state = keys.modState(i)
            val (bg, fg) = when (state) {
                1 -> R.color.primary_container to R.color.on_primary_container
                2 -> R.color.primary to R.color.on_primary
                else -> R.color.surface to R.color.on_surface
            }
            v.background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), rounded(bg, 10), null)
            v.setTextColor(color(fg))
            v.paint.isUnderlineText = state == 2
            v.contentDescription = modNames[i] + when (state) { 1 -> ", on for the next key"; 2 -> ", locked"; else -> "" }
            v.invalidate()
        }
    }

    private fun showMoreKeys() {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(R.color.surface, 24)
            elevation = dp(8).toFloat()
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }
        lateinit var popup: PopupWindow
        val keepOpen = setOf("⌘Tab")
        fun line(vararg keys: Pair<String, () -> Unit>) {
            val r = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for ((label, act) in keys) {
                r.addView(keyView(label, label).apply {
                    background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), rounded(R.color.bg, 10), null)
                    textSize = 14f
                    setOnClickListener { haptic(it); act(); if (label !in keepOpen) popup.dismiss() }
                }, LinearLayout.LayoutParams(0, dp(44), 1f).apply { setMargins(dp(3), dp(3), dp(3), dp(3)) })
            }
            box.addView(r, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        fun fkey(n: Int) = ("F" + (n + 1)) to { keys.typeKey(MacKeys.F[n]) }
        line(fkey(0), fkey(1), fkey(2), fkey(3), fkey(4), fkey(5))
        line(fkey(6), fkey(7), fkey(8), fkey(9), fkey(10), fkey(11))
        line("⌦" to { keys.typeKey(MacKeys.FORWARD_DELETE) }, "Home" to { keys.typeKey(MacKeys.HOME) }, "End" to { keys.typeKey(MacKeys.END) },
            "PgUp" to { keys.typeKey(MacKeys.PAGE_UP) }, "PgDn" to { keys.typeKey(MacKeys.PAGE_DOWN) })
        line("⌘C Copy" to { keys.shortcut(8) }, "⌘V Paste" to { keys.shortcut(9) }, "⌘Z Undo" to { keys.shortcut(6) })
        line("⌘Tab" to { keys.cmdTab() }, "Spotlight" to { RemoteDesktop.system("spotlight") })
        line("Mission Control" to { RemoteDesktop.system("missionControl") }, "Lock" to { RemoteDesktop.system("lock") })
        popup = PopupWindow(box, min(root.width - dp(16), dp(440)), ViewGroup.LayoutParams.WRAP_CONTENT, false).apply {
            isOutsideTouchable = true
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            elevation = dp(8).toFloat()
            inputMethodMode = PopupWindow.INPUT_METHOD_NOT_NEEDED
            setOnDismissListener { keys.cmdTabUp() }
        }
        popup.showAtLocation(root, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL, 0, imeH + dp(60))
    }

    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (!interactive()) return super.dispatchKeyEvent(e)
        // A mouse sends Back for the right button; onMouse handles it.
        if (e.isFromSource(InputDevice.SOURCE_MOUSE) && e.keyCode == KeyEvent.KEYCODE_BACK) return true
        val dev = e.device
        val physical = dev != null && !dev.isVirtual && dev.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
        if (!physical || e.action == KeyEvent.ACTION_MULTIPLE) return super.dispatchKeyEvent(e)
        if (e.keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE) {
            if (e.action == KeyEvent.ACTION_DOWN && e.repeatCount == 0) RemoteDesktop.system("playPause")
            return true
        }
        return keys.hardwareKey(e) || super.dispatchKeyEvent(e)
    }

    private fun onInsets(insets: WindowInsets) {
        val ime = insets.getInsets(WindowInsets.Type.ime()).bottom
        imeVisible = insets.isVisible(WindowInsets.Type.ime()) && ime > 0
        imeH = if (imeVisible) ime else 0
        topInset = insets.getInsetsIgnoringVisibility(WindowInsets.Type.displayCutout()).top
        keysScroll.visibility = if (imeVisible && interactive()) View.VISIBLE else View.GONE
        (keysScroll.layoutParams as FrameLayout.LayoutParams).bottomMargin = imeH
        keysScroll.layoutParams = keysScroll.layoutParams
        (toolbar.layoutParams as FrameLayout.LayoutParams).topMargin = topInset + dp(8)
        toolbar.layoutParams = toolbar.layoutParams
        (handle.layoutParams as FrameLayout.LayoutParams).topMargin = topInset + dp(6)
        handle.layoutParams = handle.layoutParams
        keyboardButton.setImageResource(if (imeVisible) R.drawable.ic_rd_keyboard_hide else R.drawable.ic_rd_keyboard)
        keyboardButton.contentDescription = if (imeVisible) "Hide keyboard" else "Show keyboard"
        if (!imeVisible) hideSystemBars()
        relayout()
    }

    private fun bottomUsed() = if (imeVisible) imeH + dp(52) else 0

    private fun setVideoSize(w: Float, h: Float) {
        if (vp.setVideoSize(w, h)) applyTransform()
    }

    private fun relayout() {
        val w = root.width.toFloat()
        val h = (root.height - bottomUsed()).toFloat()
        if (w <= 0f || h <= 0f) return
        vp.setArea(w, h)
        if (trackpad) followCursor()
        applyTransform()
    }

    private fun rubber(v: Float, l: Float): Float = l + ((v - l) * 0.35f).coerceIn(-dp(96).toFloat(), dp(96).toFloat())

    private fun applyTransform() {
        val vw = video.width.toFloat(); val vh = video.height.toFloat()
        if (vw <= 0f || vh <= 0f || vp.areaW <= 0f) return
        matrix.setScale(vp.cw() / vw, vp.ch() / vh)
        matrix.postTranslate(vp.ox, vp.oy)
        video.setTransform(matrix)
    }

    private fun macPerPx(): Float {
        val d = RemoteDesktop.displays.firstOrNull { it.id == RemoteDesktop.display }
        val pts = d?.width?.takeIf { it > 0 } ?: RemoteDesktop.width.takeIf { it > 0 } ?: 1512
        return pts / vp.cw()
    }

    /** In trackpad mode while zoomed, keeps the Mac cursor in view. */
    private fun followCursor() {
        if (vp.follow(RemoteDesktop.cursorX, RemoteDesktop.cursorY)) applyTransform()
    }

    private fun animateTo(z: Float, tx: Float, ty: Float) {
        animator?.cancel()
        val z0 = vp.zoom; val x0 = vp.ox; val y0 = vp.oy
        if (abs(z - z0) < 0.001f && abs(tx - x0) < 0.5f && abs(ty - y0) < 0.5f) { vp.zoom = z; vp.ox = tx; vp.oy = ty; applyTransform(); return }
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 280
            interpolator = DecelerateInterpolator(1.5f)
            addUpdateListener {
                val f = it.animatedValue as Float
                vp.zoom = z0 + (z - z0) * f; vp.ox = x0 + (tx - x0) * f; vp.oy = y0 + (ty - y0) * f
                applyTransform()
            }
            start()
        }
    }

    private fun animateZoom(z: Float, fx: Float, fy: Float) {
        val (tx, ty) = vp.zoomOffsets(z, fx, fy)
        animateTo(z, tx, ty)
    }

    private fun settle() = animateZoom(vp.zoom.coerceIn(1f, 6f), lastCx, lastCy)

    private fun toggleZoom(fx0: Float, fy0: Float) {
        var fx = fx0; var fy = fy0
        if (trackpad) { fx = vp.screenX(RemoteDesktop.cursorX); fy = vp.screenY(RemoteDesktop.cursorY) }
        if (vp.zoom > 1.05f) { lastZoom = vp.zoom; animateZoom(1f, fx, fy) } else animateZoom(lastZoom.coerceIn(1.5f, 6f), fx, fy)
    }

    /** Reads gestures and receives text from the on-screen keyboard. */
    private inner class InputSurface : View(this@RemoteDesktopActivity) {
        init { isFocusable = true; isFocusableInTouchMode = true }
        override fun onCheckIsTextEditor() = true
        override fun onCreateInputConnection(out: EditorInfo): InputConnection {
            out.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
            out.initialSelStart = 0
            out.initialSelEnd = 0
            return keys.inputConnection(this)
        }
        override fun onTouchEvent(e: MotionEvent): Boolean = onTouch(e)
        override fun onGenericMotionEvent(e: MotionEvent): Boolean = onMouse(e) || super.onGenericMotionEvent(e)
    }

    private fun tick() { input.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK) }

    private fun isEdge(x: Float, y: Float) =
        !toolbarShown && y < topInset + dp(22) && (trackpad || abs(x - root.width / 2f) < dp(64))

    private fun centroid(e: MotionEvent, skip: Int = -1): Pair<Float, Float> {
        var sx = 0f; var sy = 0f; var n = 0
        for (i in 0 until e.pointerCount) { if (i == skip) continue; sx += e.getX(i); sy += e.getY(i); n++ }
        return if (n == 0) 0f to 0f else sx / n to sy / n
    }

    private fun spacing(e: MotionEvent): Float =
        if (e.pointerCount < 2) 1f else max(1f, hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1)))

    private fun onTouch(e: MotionEvent): Boolean {
        if (e.isFromSource(InputDevice.SOURCE_MOUSE)) { mouseTouch(e); return true }
        if (!interactive()) return true
        if (e.actionMasked == MotionEvent.ACTION_DOWN) { vt?.recycle(); vt = VelocityTracker.obtain() }
        vt?.addMovement(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> down(e)
            MotionEvent.ACTION_POINTER_DOWN -> pointerDown(e)
            MotionEvent.ACTION_MOVE -> move(e)
            MotionEvent.ACTION_POINTER_UP -> pointerUp(e)
            MotionEvent.ACTION_UP -> { up(e); vt?.recycle(); vt = null }
            MotionEvent.ACTION_CANCEL -> { handler.removeCallbacks(longPress); releaseHeld(); hideLoupe(); g = G.NONE; vt?.recycle(); vt = null }
        }
        return true
    }

    private fun down(e: MotionEvent) {
        stopMomentum()
        animator?.cancel()
        downX = e.x; downY = e.y; downT = e.eventTime
        lastX = downX; lastY = downY; lastT = downT
        moved = false
        if (toolbarShown) setToolbar(false)
        if (isEdge(downX, downY)) { g = G.EDGE; return }
        g = if (trackpad) {
            if (downT - lastTapT < 300 && hypot(downX - lastTapX, downY - lastTapY) < dp(80)) G.DRAG_WAIT else G.ONE
        } else {
            handler.postDelayed(longPress, 450)
            G.ONE
        }
    }

    private fun pointerDown(e: MotionEvent) {
        handler.removeCallbacks(longPress)
        when (g) {
            G.DRAG -> { RemoteDesktop.button("up"); leftHeld = false }
            G.TDRAG -> { RemoteDesktop.pointer(vp.normX(lastX), vp.normY(lastY), "up"); touchHeld = false; hideLoupe() }
            G.LONG -> hideLoupe()
            else -> {}
        }
        val (cx, cy) = centroid(e)
        if (e.pointerCount == 2 && g != G.THREE && g != G.TAP3 && g != G.DONE) {
            g = G.TWO
            multiDownT = e.eventTime
            startCx = cx; startCy = cy; lastCx = cx; lastCy = cy
            startDist = spacing(e); startZoom = vp.zoom
            rawX = vp.ox; rawY = vp.oy
        } else if (e.pointerCount >= 3 && g != G.DONE) {
            if (g != G.THREE) multiDownT = e.eventTime
            g = G.THREE
            startCx = cx; startCy = cy; moved = false
        }
    }

    private fun move(e: MotionEvent) {
        when (g) {
            G.EDGE -> if (e.y - downY > dp(24)) { showToolbar(); g = G.DONE } else if (hypot(e.x - downX, e.y - downY) > slop * 2) g = G.DONE
            G.ONE -> if (trackpad) {
                if (!moved && hypot(e.x - downX, e.y - downY) > slop / 2) moved = true
                if (moved) relMove(e)
            } else if (hypot(e.x - downX, e.y - downY) > slop) {
                handler.removeCallbacks(longPress)
                moved = true
                g = G.TDRAG
                val nx = vp.normX(downX); val ny = vp.normY(downY)
                RemoteDesktop.pointer(nx, ny, "move")
                RemoteDesktop.pointer(nx, ny, "down")
                touchHeld = true
                RemoteDesktop.pointer(vp.normX(e.x), vp.normY(e.y), "move")
                showLoupe(e.x, e.y)
            }
            G.DRAG_WAIT -> if (hypot(e.x - downX, e.y - downY) > slop / 2) {
                moved = true
                RemoteDesktop.button("down")
                leftHeld = true
                g = G.DRAG
                relMove(e)
            }
            G.DRAG -> relMove(e)
            G.TDRAG, G.LONG -> { RemoteDesktop.pointer(vp.normX(e.x), vp.normY(e.y), "move"); showLoupe(e.x, e.y) }
            G.TWO, G.PINCH, G.SCROLL, G.PAN -> twoMove(e)
            G.THREE -> {
                val (_, cy) = centroid(e)
                if (cy - startCy > dp(60)) { showToolbar(); g = G.DONE }
                else if (abs(cy - startCy) > slop * 2) moved = true
            }
            else -> {}
        }
        lastX = e.x; lastY = e.y; lastT = e.eventTime
    }

    private fun relMove(e: MotionEvent) {
        val dx = e.x - lastX; val dy = e.y - lastY
        if (dx == 0f && dy == 0f) return
        val dt = max(1L, e.eventTime - lastT).toFloat()
        val speed = hypot(dx, dy) / dt / resources.displayMetrics.density   // dp per ms
        val gain = 1f + (speed - 0.2f).coerceIn(0f, 2f) * 1.2f
        val k = macPerPx() * gain
        RemoteDesktop.moveBy(dx * k, dy * k)
    }

    private fun twoMove(e: MotionEvent) {
        if (e.pointerCount < 2) return
        val (cx, cy) = centroid(e)
        val d = spacing(e)
        if (g == G.TWO) {
            if (abs(d - startDist) > dp(28)) {
                g = G.PINCH
                startDist = d; startZoom = vp.zoom
                lastCx = cx; lastCy = cy
                return
            } else if (hypot(cx - startCx, cy - startCy) > slop * 1.5f) {
                g = if (!trackpad && vp.zoom > 1.01f) G.PAN else G.SCROLL
                if (g == G.SCROLL) RemoteDesktop.scroll(0f, 0f, "began")
                rawX = vp.ox; rawY = vp.oy
                lastCx = cx; lastCy = cy
                return
            } else return
        }
        when (g) {
            G.PINCH -> {
                val px = (lastCx - vp.ox) / vp.cw(); val py = (lastCy - vp.oy) / vp.ch()
                vp.zoom = (startZoom * d / startDist).coerceIn(0.8f, 7f)
                vp.ox = cx - px * vp.cw(); vp.oy = cy - py * vp.ch()
                applyTransform()
            }
            G.SCROLL -> {
                val k = macPerPx()
                RemoteDesktop.scroll((cx - lastCx) * k, (cy - lastCy) * k, "changed")
            }
            G.PAN -> {
                rawX += cx - lastCx; rawY += cy - lastCy
                vp.ox = rubber(rawX, vp.limitX(rawX)); vp.oy = rubber(rawY, vp.limitY(rawY))
                applyTransform()
            }
            else -> {}
        }
        lastCx = cx; lastCy = cy
    }

    private fun pointerUp(e: MotionEvent) {
        when (g) {
            G.TWO -> g = if (e.eventTime - multiDownT < 300) G.TAP2 else G.DONE
            G.PINCH, G.PAN -> { settle(); g = G.DONE }
            G.SCROLL -> { endScroll(e); g = G.DONE }
            G.THREE -> g = if (e.eventTime - multiDownT < 350 && !moved) G.TAP3 else G.DONE
            else -> {}
        }
    }

    private fun up(e: MotionEvent) {
        handler.removeCallbacks(longPress)
        val now = e.eventTime
        when (g) {
            G.EDGE -> if (hypot(e.x - downX, e.y - downY) < slop) toggleToolbar()
            G.ONE -> if (trackpad) {
                if (!moved && now - downT < 300) {
                    RemoteDesktop.button("down"); RemoteDesktop.button("up")
                    tick()
                    lastTapT = now; lastTapX = e.x; lastTapY = e.y
                }
            } else {
                val clicks = if (now - lastTapT < 350 && hypot(downX - lastTapX, downY - lastTapY) < dp(24)) min(lastTapClicks + 1, 3) else 1
                val nx = vp.normX(downX); val ny = vp.normY(downY)
                RemoteDesktop.pointer(nx, ny, "move")
                RemoteDesktop.pointer(nx, ny, "down", "left", clicks)
                RemoteDesktop.pointer(nx, ny, "up", "left", clicks)
                tick()
                lastTapClicks = clicks; lastTapT = now; lastTapX = downX; lastTapY = downY
            }
            G.DRAG_WAIT -> {
                if (!moved) { RemoteDesktop.button("down", "left", 2); RemoteDesktop.button("up", "left", 2); tick() }
                lastTapT = 0
            }
            G.DRAG -> { RemoteDesktop.button("up"); leftHeld = false; lastTapT = 0 }
            G.TDRAG -> { RemoteDesktop.pointer(vp.normX(e.x), vp.normY(e.y), "up"); touchHeld = false; hideLoupe() }
            G.LONG -> { hideLoupe(); rightClick(e.x, e.y) }
            G.TAP2 -> twoFingerTap(now)
            G.TAP3 -> {
                if (trackpad) { RemoteDesktop.button("down", "middle"); RemoteDesktop.button("up", "middle") }
                else {
                    val nx = vp.normX(startCx); val ny = vp.normY(startCy)
                    RemoteDesktop.pointer(nx, ny, "move"); RemoteDesktop.pointer(nx, ny, "down", "middle"); RemoteDesktop.pointer(nx, ny, "up", "middle")
                }
                tick()
            }
            G.PINCH, G.PAN -> settle()
            G.SCROLL -> endScroll(e)
            else -> {}
        }
        g = G.NONE
    }

    private fun onLongPress() {
        if (g != G.ONE || moved || trackpad) return
        g = G.LONG
        input.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        RemoteDesktop.pointer(vp.normX(lastX), vp.normY(lastY), "move")
        showLoupe(lastX, lastY)
    }

    private fun twoFingerTap(now: Long) {
        if (now - lastTwoTapT < 350) {
            handler.removeCallbacks(pendingRight)
            lastTwoTapT = 0
            toggleZoom(startCx, startCy)
            return
        }
        lastTwoTapT = now
        rightX = startCx; rightY = startCy
        // A second two-finger tap toggles zoom and cancels this right click.
        handler.removeCallbacks(pendingRight)
        handler.postDelayed(pendingRight, 280)
    }

    private fun rightClick(x: Float, y: Float) {
        if (!interactive()) return
        if (trackpad) {
            RemoteDesktop.button("down", "right"); RemoteDesktop.button("up", "right")
        } else {
            val nx = vp.normX(x); val ny = vp.normY(y)
            RemoteDesktop.pointer(nx, ny, "move")
            RemoteDesktop.pointer(nx, ny, "down", "right")
            RemoteDesktop.pointer(nx, ny, "up", "right")
        }
        tick()
    }

    private fun releaseHeld() {
        if (leftHeld) { RemoteDesktop.button("up"); leftHeld = false }
        if (touchHeld) { RemoteDesktop.pointer(vp.normX(lastX), vp.normY(lastY), "up"); touchHeld = false }
        if (g == G.SCROLL) RemoteDesktop.scroll(0f, 0f, "ended")
    }

    private fun endScroll(e: MotionEvent) {
        RemoteDesktop.scroll(0f, 0f, "ended")
        val t = vt ?: return
        t.computeCurrentVelocity(1000)
        var vx = 0f; var vy = 0f
        for (i in 0 until e.pointerCount) { vx += t.getXVelocity(e.getPointerId(i)); vy += t.getYVelocity(e.getPointerId(i)) }
        vx /= e.pointerCount; vy /= e.pointerCount
        if (hypot(vx, vy) < dp(250)) return
        momVx = vx; momVy = vy; momLast = SystemClock.uptimeMillis()
        momActive = true
        handler.postDelayed(momentum, 16)
    }

    private val momentum = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val dt = (now - momLast).coerceIn(1L, 50L)
            momLast = now
            val decay = Math.pow(0.996, dt.toDouble()).toFloat()
            momVx *= decay; momVy *= decay
            if (hypot(momVx, momVy) < dp(30) || !interactive()) { stopMomentum(); return }
            val k = macPerPx() * dt / 1000f
            RemoteDesktop.scroll(momVx * k, momVy * k, "momentum")
            handler.postDelayed(this, 16)
        }
    }

    private fun stopMomentum() {
        handler.removeCallbacks(momentum)
        if (momActive) { momActive = false; RemoteDesktop.scroll(0f, 0f, "ended") }
    }

    private fun showLoupe(x: Float, y: Float) {
        val m = magnifier ?: Magnifier.Builder(input)
            .setSize(dp(128), dp(128))
            .setCornerRadius(dp(64).toFloat())
            .setInitialZoom(2f)
            .setDefaultSourceToMagnifierOffset(0, -dp(112))
            .build().also { magnifier = it }
        m.show(x, y)
    }

    private fun hideLoupe() { magnifier?.dismiss() }

    private fun buttonName(b: Int) = when (b) {
        MotionEvent.BUTTON_PRIMARY -> "left"
        MotionEvent.BUTTON_SECONDARY -> "right"
        MotionEvent.BUTTON_TERTIARY -> "middle"
        else -> null
    }

    private fun onMouse(e: MotionEvent): Boolean {
        if (!e.isFromSource(InputDevice.SOURCE_MOUSE)) return false
        if (!interactive()) return true
        val nx = vp.normX(e.x); val ny = vp.normY(e.y)
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE -> RemoteDesktop.pointer(nx, ny, "move")
            MotionEvent.ACTION_BUTTON_PRESS -> {
                val b = buttonName(e.actionButton) ?: return true
                val now = SystemClock.uptimeMillis()
                mouseClicks = if (b == mouseLastButton && now - mouseLastPress < 400) min(mouseClicks + 1, 3) else 1
                mouseLastPress = now; mouseLastButton = b
                RemoteDesktop.pointer(nx, ny, "down", b, mouseClicks)
            }
            MotionEvent.ACTION_BUTTON_RELEASE -> {
                val b = buttonName(e.actionButton) ?: return true
                RemoteDesktop.pointer(nx, ny, "up", b, mouseClicks)
            }
            MotionEvent.ACTION_SCROLL -> {
                val v = e.getAxisValue(MotionEvent.AXIS_VSCROLL); val h = e.getAxisValue(MotionEvent.AXIS_HSCROLL)
                RemoteDesktop.scroll(-h * 40f, v * 40f, "none")
            }
            else -> return false
        }
        return true
    }

    /** Mouse motion with a button down arrives as a touch event. */
    private fun mouseTouch(e: MotionEvent) {
        if (!interactive()) return
        if (e.actionMasked == MotionEvent.ACTION_MOVE) RemoteDesktop.pointer(vp.normX(e.x), vp.normY(e.y), "move")
    }
}
