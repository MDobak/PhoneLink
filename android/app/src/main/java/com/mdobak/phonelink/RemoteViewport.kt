package com.mdobak.phonelink

import kotlin.math.abs
import kotlin.math.min

/** Fits the Mac video into the area above the keyboard, then zooms and pans it. Units are screen pixels. */
class RemoteViewport {
    var vidW = 16f; private set
    var vidH = 10f; private set
    var areaW = 0f; private set
    var areaH = 0f; private set
    var zoom = 1f
    /** Top-left corner of the video in the area. */
    var ox = 0f
    var oy = 0f

    private fun fit() = if (areaW <= 0f) 1f else min(areaW / vidW, areaH / vidH)

    fun cw(z: Float = zoom) = vidW * fit() * z
    fun ch(z: Float = zoom) = vidH * fit() * z

    /** Nearest offset that keeps the area full. A video smaller than the area stays centered. */
    fun limitX(x: Float, z: Float = zoom): Float { val c = cw(z); return if (c <= areaW) (areaW - c) / 2 else x.coerceIn(areaW - c, 0f) }
    fun limitY(y: Float, z: Float = zoom): Float { val c = ch(z); return if (c <= areaH) (areaH - c) / 2 else y.coerceIn(areaH - c, 0f) }

    fun clamp() { ox = limitX(ox); oy = limitY(oy) }

    fun normX(x: Float) = ((x - ox) / cw()).coerceIn(0f, 1f)
    fun normY(y: Float) = ((y - oy) / ch()).coerceIn(0f, 1f)

    fun screenX(nx: Float) = ox + nx * cw()
    fun screenY(ny: Float) = oy + ny * ch()

    /** Keeps the center point in place. Returns false if nothing changed. */
    fun setVideoSize(w: Float, h: Float): Boolean {
        if (abs(w / h - vidW / vidH) < 0.001f && w == vidW) return false
        val cx = if (areaW > 0) (areaW / 2 - ox) / cw() else 0.5f
        val cy = if (areaH > 0) (areaH / 2 - oy) / ch() else 0.5f
        vidW = w; vidH = h
        if (areaW > 0) { ox = areaW / 2 - cx * cw(); oy = areaH / 2 - cy * ch() }
        clamp()
        return true
    }

    /** Keeps the center point in place. */
    fun setArea(w: Float, h: Float) {
        if (areaW > 0f) {
            val cx = (areaW / 2 - ox) / cw(); val cy = (areaH / 2 - oy) / ch()
            areaW = w; areaH = h
            ox = areaW / 2 - cx * cw(); oy = areaH / 2 - cy * ch()
        } else { areaW = w; areaH = h }
        clamp()
    }

    /** Moves the video so (nx, ny) is not in the outer 15 % of the area. Returns true if it moved. */
    fun follow(nx: Float, ny: Float): Boolean {
        if (zoom <= 1.01f || areaW <= 0f) return false
        val px = screenX(nx); val py = screenY(ny)
        val mx = areaW * 0.15f; val my = areaH * 0.15f
        var x = ox; var y = oy
        if (px < mx) x += mx - px else if (px > areaW - mx) x -= px - (areaW - mx)
        if (py < my) y += my - py else if (py > areaH - my) y -= py - (areaH - my)
        x = limitX(x); y = limitY(y)
        if (x == ox && y == oy) return false
        ox = x; oy = y
        return true
    }

    fun zoomOffsets(z: Float, fx: Float, fy: Float): Pair<Float, Float> {
        val px = (fx - ox) / cw(); val py = (fy - oy) / ch()
        return limitX(fx - px * cw(z), z) to limitY(fy - py * ch(z), z)
    }
}
