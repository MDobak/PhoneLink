package com.mdobak.phonelink

import android.app.Activity
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

abstract class UiActivity : Activity() {
    protected lateinit var content: LinearLayout

    protected fun scrollContent(): ScrollView {
        window.setDecorFitsSystemWindows(false)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        return ScrollView(this).apply {
            addView(content)
            clipToPadding = false
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                v.setPadding(bars.left + dp(16), bars.top, bars.right + dp(16), bars.bottom + dp(96))
                insets
            }
        }
    }

    protected fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    protected fun color(id: Int) = getColor(id)

    protected fun label(text: CharSequence, sp: Float, colorId: Int = R.color.on_surface, medium: Boolean = false) = TextView(this).apply {
        this.text = text
        textSize = sp
        setTextColor(color(colorId))
        if (medium) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }

    protected fun rounded(colorId: Int, radius: Int) = GradientDrawable().apply {
        setColor(color(colorId))
        cornerRadius = dp(radius).toFloat()
    }

    protected fun section(title: String?): LinearLayout {
        if (title != null) {
            content.addView(label(title, 14f, R.color.on_surface_variant, medium = true).apply {
                setPadding(dp(20), dp(24), dp(20), dp(8))
            })
        }
        val group = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(R.color.surface, 26)
            clipToOutline = true
        }
        content.addView(group)
        return group
    }

    protected fun divider() = View(this).apply {
        setBackgroundColor(color(R.color.outline))
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { marginStart = dp(68); marginEnd = dp(20) }
    }

    protected fun iconView(res: Int, tint: Int) = ImageView(this).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(color(tint))
        layoutParams = LinearLayout.LayoutParams(dp(24), dp(24)).apply { marginEnd = dp(20) }
    }

    protected fun tonalButton(text: String, onClick: () -> Unit) = Button(this, null, 0, 0).apply {
        this.text = text
        isAllCaps = false
        textSize = 14f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(color(R.color.on_primary_container))
        // 48dp touch target, 40dp visible shape.
        background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)),
            InsetDrawable(rounded(R.color.primary_container, 20), 0, dp(4), 0, dp(4)), null)
        gravity = Gravity.CENTER
        includeFontPadding = false
        minHeight = dp(48)
        minimumHeight = dp(48)
        minWidth = 0
        minimumWidth = 0
        setPadding(dp(18), 0, dp(18), 0)
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    protected fun textButton(text: String, onClick: () -> Unit) = Button(this, null, 0, 0).apply {
        this.text = text
        isAllCaps = false
        textSize = 14f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(color(R.color.primary))
        background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 20))
        gravity = Gravity.CENTER
        includeFontPadding = false
        minHeight = dp(48)
        minimumHeight = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        stateListAnimator = null
        setOnClickListener { onClick() }
    }

    protected fun row(iconRes: Int, title: String, subtitle: String?, trailing: View?,
                      titleColorId: Int = R.color.on_surface, onClick: (() -> Unit)? = null): View {
        val r = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(72)
            setPadding(dp(24), dp(12), dp(16), dp(12))
            if (onClick != null) {
                background = RippleDrawable(ColorStateList.valueOf(color(R.color.outline)), null, rounded(R.color.surface, 0))
                setOnClickListener { onClick() }
            }
        }
        r.addView(iconView(iconRes, R.color.primary))
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        texts.addView(label(title, 17f, titleColorId))
        if (subtitle != null) texts.addView(label(subtitle, 14f, R.color.on_surface_variant).apply { setPadding(0, dp(2), 0, 0) })
        r.addView(texts)
        if (trailing != null) r.addView(trailing, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
            if (trailing is Button) dp(48) else ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(12) })
        return r
    }

    protected fun check(ok: Boolean, action: String, onClick: () -> Unit): View =
        if (ok) ImageView(this).apply {
            setImageResource(R.drawable.ic_check)
            imageTintList = ColorStateList.valueOf(color(R.color.ok))
            contentDescription = "On"
            layoutParams = LinearLayout.LayoutParams(dp(24), dp(24))
        } else tonalButton(action, onClick)

}
