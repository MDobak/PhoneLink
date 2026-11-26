package com.mdobak.phonelink

import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.text.TextUtils
import android.text.format.DateUtils
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import android.window.OnBackInvokedDispatcher
import org.json.JSONObject

class MacFilesActivity : UiActivity() {
    private class Place(val name: String, val path: String?)

    /** A place with no path is the list of shared folders. */
    private val stack = ArrayList<Place>()
    private var items: List<RemoteFile> = emptyList()
    private var writable = false
    private var loading = false
    private var error: String? = null
    private lateinit var upload: Button
    private val onTransfers: () -> Unit = { render() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this)
        root.addView(scrollContent())
        upload = Button(this, null, 0, 0).apply {
            text = "Upload"
            isAllCaps = false
            textSize = 15f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setTextColor(color(R.color.on_primary_container))
            background = rounded(R.color.primary_container, 16)
            elevation = dp(3).toFloat()
            setCompoundDrawablesRelativeWithIntrinsicBounds(R.drawable.ic_upload, 0, 0, 0)
            compoundDrawableTintList = ColorStateList.valueOf(color(R.color.on_primary_container))
            compoundDrawablePadding = dp(12)
            gravity = Gravity.CENTER
            includeFontPadding = false
            setPadding(dp(16), 0, dp(20), 0)
            minHeight = dp(56); minimumHeight = dp(56)
            setOnClickListener { pick() }
        }
        root.addView(upload, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(56), Gravity.BOTTOM or Gravity.END))
        upload.setOnApplyWindowInsetsListener { v, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            (v.layoutParams as FrameLayout.LayoutParams).setMargins(0, 0, bars.right + dp(16), bars.bottom + dp(16))
            insets
        }
        setContentView(root)
        open(Place(Hub.session?.macName ?: "Mac", null))
    }

    @Deprecated("Used below API 33")
    override fun onBackPressed() = goBack()

    private fun goBack() {
        if (stack.size > 1) { stack.removeAt(stack.size - 1); load() } else finish()
    }

    override fun onResume() { super.onResume(); Transfers.addListener(onTransfers) }
    override fun onPause() { Transfers.removeListener(onTransfers); super.onPause() }

    private fun open(p: Place) { stack.add(p); load() }

    // Below the root, back goes up one folder. At the root the system handles back (predictive back to home).
    private val backCallback: Any? = if (Build.VERSION.SDK_INT >= 33) android.window.OnBackInvokedCallback { goBack() } else null
    private var backRegistered = false

    private fun updateBack() {
        if (Build.VERSION.SDK_INT < 33) return
        val cb = backCallback as android.window.OnBackInvokedCallback
        val want = stack.size > 1
        if (want && !backRegistered) onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb)
        if (!want && backRegistered) onBackInvokedDispatcher.unregisterOnBackInvokedCallback(cb)
        backRegistered = want
    }

    private fun load() {
        updateBack()
        val place = stack.last()
        loading = true
        error = null
        items = emptyList()
        render()
        val cb = { r: JSONObject ->
            if (stack.lastOrNull() === place) {
                loading = false
                if (r.optString("t") == "fs.error") {
                    error = r.optString("msg")
                } else {
                    val a = r.optJSONArray("items")
                    items = (0 until (a?.length() ?: 0)).map { RemoteFile(a!!.getJSONObject(it)) }
                        .filter { !it.name.startsWith(".") }
                        .sortedWith(compareBy<RemoteFile> { !it.dir }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
                    writable = place.path != null && r.optBoolean("writable")
                }
                render()
            }
        }
        if (place.path == null) Transfers.request("fs.roots", null, cb) else Transfers.request("fs.list", place.path, cb)
    }

    private fun pick() {
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), PICK_FILES)
    }

    @Deprecated("Plain activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES || resultCode != RESULT_OK || data == null) return
        val uris = data.clipData?.let { c -> (0 until c.itemCount).map { c.getItemAt(it).uri } } ?: listOfNotNull(data.data)
        val dir = stack.last().path ?: return
        Transfers.upload(Transfers.open(this, uris), dir)?.let { Toast.makeText(this, it, Toast.LENGTH_SHORT).show() }
    }

    private fun render() {
        content.removeAllViews()
        val place = stack.last()
        upload.visibility = if (writable && !loading && error == null) View.VISIBLE else View.GONE

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        bar.addView(ImageButton(this).apply {
            setImageResource(R.drawable.ic_arrow_back)
            imageTintList = ColorStateList.valueOf(color(R.color.on_surface))
            background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 24))
            contentDescription = "Back"
            setOnClickListener { goBack() }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        content.addView(bar)
        content.addView(label(place.name, 30f).apply {
            setPadding(dp(20), dp(8), dp(20), dp(2))
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        })
        val where = if (place.path == null) "Shared folders"
                    else stack.drop(1).joinToString("  ›  ") { it.name }
        content.addView(label(where, 14f, R.color.on_surface_variant).apply {
            setPadding(dp(20), 0, dp(20), dp(16))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.START
        })

        renderTransfers()

        when {
            Hub.session == null -> message(R.drawable.ic_laptop, "Not connected", "Open Phone Link on your Mac.")
            loading -> content.addView(ProgressBar(this).apply {
                isIndeterminate = true
                indeterminateTintList = ColorStateList.valueOf(color(R.color.primary))
            }, LinearLayout.LayoutParams(dp(40), dp(40)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(48) })
            error != null -> message(R.drawable.ic_folder, "Cannot open this folder", error!!)
            items.isEmpty() && place.path == null ->
                message(R.drawable.ic_folder, "No shared folders", "On your Mac, add folders in Phone Link Settings > Files.")
            items.isEmpty() -> message(R.drawable.ic_folder, "This folder is empty", null)
            else -> {
                val group = section(null)
                val shown = items.take(500)
                shown.forEachIndexed { i, f ->
                    if (i > 0) group.addView(divider())
                    group.addView(fileRow(f))
                }
                if (items.size > shown.size) {
                    content.addView(label("Showing 500 of ${items.size} items", 13f, R.color.on_surface_variant).apply {
                        setPadding(dp(20), dp(12), dp(20), 0)
                    })
                }
            }
        }
    }

    private fun message(icon: Int, title: String, body: String?) {
        content.addView(ImageView(this).apply {
            setImageResource(icon)
            imageTintList = ColorStateList.valueOf(color(R.color.on_surface_variant))
        }, LinearLayout.LayoutParams(dp(48), dp(48)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(56) })
        content.addView(label(title, 20f).apply { gravity = Gravity.CENTER; setPadding(dp(24), dp(16), dp(24), dp(8)) })
        if (body != null) content.addView(label(body, 15f, R.color.on_surface_variant).apply { gravity = Gravity.CENTER; setPadding(dp(32), 0, dp(32), 0) })
    }

    private fun fileRow(f: RemoteFile): View {
        val date = DateUtils.formatDateTime(this, f.mtime, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH)
        val sub = if (f.dir) date else Formatter.formatShortFileSize(this, f.size) + " · " + date
        val trailing = if (f.dir) null else ImageView(this).apply {
            setImageResource(R.drawable.ic_download)
            imageTintList = ColorStateList.valueOf(color(R.color.on_surface_variant))
            contentDescription = "Download"
            layoutParams = LinearLayout.LayoutParams(dp(24), dp(24))
        }
        return row(if (f.dir) R.drawable.ic_folder else R.drawable.ic_file, f.name, if (f.mtime > 0) sub else null, trailing) {
            if (f.dir) open(Place(f.name, f.path))
            else {
                val error = Transfers.download(this, f)
                Toast.makeText(this, error ?: "Downloading to Download/Phone Link", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun renderTransfers() {
        val list = Transfers.items.take(6)
        if (list.isEmpty()) return
        val group = section(null)
        list.forEachIndexed { i, t ->
            if (i > 0) group.addView(divider())
            val box = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            box.addView(label(t.name, 16f).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE })
            val status = when (t.state) {
                Transfers.State.ACTIVE -> (if (t.upload) "Sending" else "Receiving") +
                    (if (t.total > 0) " · " + Formatter.formatShortFileSize(this, t.done) + " of " + Formatter.formatShortFileSize(this, t.total) else "")
                Transfers.State.DONE -> if (t.upload) "Sent" else "Saved in Download/Phone Link"
                Transfers.State.CANCELLED -> "Cancelled"
                Transfers.State.FAILED -> t.error ?: "Failed"
            }
            if (t.active) box.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                max = 1000
                isIndeterminate = t.total <= 0
                progress = if (t.total > 0) (t.done * 1000 / t.total).toInt() else 0
                progressTintList = ColorStateList.valueOf(color(R.color.primary))
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(4)).apply { topMargin = dp(8); bottomMargin = dp(6) })
            box.addView(label(status, 13f, if (t.state == Transfers.State.FAILED) R.color.error else R.color.on_surface_variant))
            val r = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(24), dp(14), dp(12), dp(14))
            }
            r.addView(iconView(if (t.upload) R.drawable.ic_upload else R.drawable.ic_download, R.color.primary))
            r.addView(box)
            if (t.active) r.addView(ImageButton(this).apply {
                setImageResource(R.drawable.ic_close)
                imageTintList = ColorStateList.valueOf(color(R.color.on_surface_variant))
                background = null
                contentDescription = "Cancel"
                setOnClickListener { Transfers.cancel(t) }
            }, LinearLayout.LayoutParams(dp(48), dp(48)))
            group.addView(r)
        }
        if (Transfers.items.none { it.active }) {
            content.addView(textButton("Clear") { Transfers.clearFinished() }.apply { gravity = Gravity.CENTER },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.END })
        } else {
            content.addView(View(this), LinearLayout.LayoutParams(1, dp(12)))
        }
    }

    private companion object {
        const val PICK_FILES = 7
    }
}
