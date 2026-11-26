package com.mdobak.phonelink

import android.os.Handler
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.InputConnection

/** Modifier keys, Command-Tab switcher and text input for Remote Desktop. Main thread only. */
class RemoteKeyboard(
    private val handler: Handler,
    private val live: () -> Boolean,
    private val modsChanged: () -> Unit,
) {
    private val modNames = arrayOf("cmd", "opt", "ctrl", "shift")
    private val modCodes = intArrayOf(MacKeys.COMMAND, MacKeys.OPTION, MacKeys.CONTROL, MacKeys.SHIFT)
    /** 0 = off, 1 = one time, 2 = locked. */
    private val modState = IntArray(4)
    private val modTapT = LongArray(4)
    /** The Mac has the key of a locked modifier down. */
    private val modHeld = BooleanArray(4)

    fun modState(i: Int) = modState[i]

    /** Off, then one time; a second tap within 400 ms locks; a tap on a locked modifier turns it off. */
    fun tapMod(i: Int) {
        val now = android.os.SystemClock.uptimeMillis()
        modState[i] = when {
            modState[i] == 0 -> 1
            modState[i] == 1 && now - modTapT[i] < 400 -> 2
            else -> 0
        }
        modTapT[i] = now
        syncHeldMods()
        modsChanged()
    }

    /** A locked modifier holds a real key down on the Mac (Command for the app switcher). */
    private fun syncHeldMods() {
        for (i in 0..3) {
            val want = modState[i] == 2 && live()
            if (want != modHeld[i]) {
                modHeld[i] = want
                RemoteDesktop.key(modCodes[i], want, if (want) listOf(modNames[i]) else emptyList())
            }
        }
    }

    fun releaseMods() {
        for (i in 0..3) modState[i] = 0
        syncHeldMods()
        cmdTabUp()
        modsChanged()
    }

    /** The stream stopped and the Mac released all keys itself. */
    fun forgetHeldKeys() {
        for (i in 0..3) modHeld[i] = false
        handler.removeCallbacks(cmdTabRelease)
        cmdTabHeld = false
    }

    private fun activeMods(): MutableSet<String> {
        val s = LinkedHashSet<String>()
        for (i in 0..3) if (modState[i] > 0) s.add(modNames[i])
        return s
    }

    fun consumeMods() {
        var changed = false
        for (i in 0..3) if (modState[i] == 1) { modState[i] = 0; changed = true }
        if (changed) modsChanged()
    }

    // App switcher: Command stays down while the user taps Tab again.

    private var cmdTabHeld = false
    private val cmdTabRelease = Runnable { cmdTabUp() }

    fun cmdTab() {
        if (!live()) return
        if (!cmdTabHeld && !modHeld[0]) { RemoteDesktop.key(MacKeys.COMMAND, true, listOf("cmd")); cmdTabHeld = true }
        RemoteDesktop.press(MacKeys.TAB, listOf("cmd"))
        handler.removeCallbacks(cmdTabRelease)
        if (cmdTabHeld) handler.postDelayed(cmdTabRelease, 1500)
    }

    fun cmdTabUp() {
        handler.removeCallbacks(cmdTabRelease)
        if (cmdTabHeld) { cmdTabHeld = false; RemoteDesktop.key(MacKeys.COMMAND, false, emptyList()) }
    }

    fun typeKey(code: Int, extra: Collection<String> = emptyList(), consume: Boolean = true) {
        if (!live()) return
        val m = activeMods()
        m.addAll(extra)
        RemoteDesktop.press(code, m)
        if (consume) consumeMods()
    }

    fun shortcut(code: Int) {
        if (!live()) return
        RemoteDesktop.press(code, listOf("cmd"))
        consumeMods()
    }

    /** With a modifier on, each character goes as a key (for example Command-C). */
    private fun typeText(s: String) {
        if (!live() || s.isEmpty()) return
        val mods = activeMods()
        if (mods.isNotEmpty()) {
            for (ch in s) {
                val k = MacKeys.forChar(ch.lowercaseChar()) ?: MacKeys.forChar(ch)
                if (k != null) {
                    val m = LinkedHashSet(mods)
                    if (k.second || ch.isUpperCase()) m.add("shift")
                    RemoteDesktop.press(k.first, m)
                } else RemoteDesktop.text(ch.toString())
            }
            consumeMods()
            return
        }
        val sb = StringBuilder()
        for (ch in s) {
            if (ch == '\n' || ch == '\t') {
                RemoteDesktop.text(sb.toString()); sb.setLength(0)
                RemoteDesktop.press(if (ch == '\n') MacKeys.RETURN else MacKeys.TAB, emptyList())
            } else sb.append(ch)
        }
        RemoteDesktop.text(sb.toString())
    }

    private fun softKey(e: KeyEvent) {
        val code = MacKeys.forKeyCode(e.keyCode)
        if (code < 0) {
            val c = e.unicodeChar
            if (c != 0) typeText(String(Character.toChars(c)))
            return
        }
        val extra = MacKeys.mods(e.metaState)
        if (MacKeys.needsShift(e.keyCode)) extra.add("shift")
        typeKey(code, extra)
    }

    /** Returns false if the Mac has no key for it. */
    fun hardwareKey(e: KeyEvent): Boolean {
        val code = MacKeys.forKeyCode(e.keyCode)
        if (code < 0) return false
        val m = MacKeys.mods(e.metaState)
        m.addAll(activeMods())
        if (MacKeys.needsShift(e.keyCode)) m.add("shift")
        RemoteDesktop.key(code, e.action == KeyEvent.ACTION_DOWN, m)
        if (e.action == KeyEvent.ACTION_UP && !KeyEvent.isModifierKey(e.keyCode)) consumeMods()
        return true
    }

    fun inputConnection(v: View): InputConnection = RemoteInput(v)

    /** Composing text goes to the Mac at once; edits send Delete and the new text. */
    private inner class RemoteInput(v: View) : BaseInputConnection(v, false) {
        private var composing = ""

        private fun replace(next: String) {
            var p = 0
            while (p < composing.length && p < next.length && composing[p] == next[p]) p++
            val removed = composing.substring(p)
            repeat(removed.codePointCount(0, removed.length)) { typeKey(MacKeys.DELETE, consume = false) }
            if (next.length > p) typeText(next.substring(p))
            composing = next
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean { replace(text.toString()); composing = ""; return true }
        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean { replace(text.toString()); return true }
        override fun finishComposingText(): Boolean { composing = ""; return true }
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            repeat(beforeLength.coerceAtMost(256)) { typeKey(MacKeys.DELETE, consume = false) }
            repeat(afterLength.coerceAtMost(256)) { typeKey(MacKeys.FORWARD_DELETE, consume = false) }
            consumeMods()
            return true
        }
        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) softKey(event)
            return true
        }
        override fun performEditorAction(actionCode: Int): Boolean { typeKey(MacKeys.RETURN); return true }
        override fun getTextBeforeCursor(n: Int, flags: Int): CharSequence = ""
        override fun getTextAfterCursor(n: Int, flags: Int): CharSequence = ""
    }
}
