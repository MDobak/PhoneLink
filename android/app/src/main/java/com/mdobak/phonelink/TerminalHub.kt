package com.mdobak.phonelink

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import org.json.JSONObject

/**
 * Terminal tabs. Each tab has a TerminalSession connected to a shell on the Mac.
 * Tabs live as long as the process, not the activity. All state is on the main thread.
 */
object TerminalHub : TerminalSessionClient {
    const val MAX_TABS = 8
    private const val SCROLLBACK = 10_000
    private const val TAG = "TerminalHub"

    class Tab(val id: Int) {
        lateinit var session: TerminalSession
        var shell = "zsh"
        var macTitle: String? = null
        var customTitle: String? = null
        var openSent = false
        var opened = false
        var everOpened = false
        var exitCode: Int? = null
        var exitMessage: String? = null
        var cols = 0
        var rows = 0
        val title: String
            get() = customTitle ?: session.title?.trim()?.takeIf { it.isNotEmpty() } ?: macTitle ?: shell
    }

    interface Ui {
        fun tabsChanged()
        fun screenUpdated(tab: Tab)
        fun screenReset(tab: Tab)
        fun stateChanged()
        fun bell()
        fun copy(text: String)
        fun paste(tab: Tab)
    }

    val tabs = ArrayList<Tab>()
    /** "unknown" until the Mac answers, then "ok" or "disabled". */
    var state = "unknown"
        private set
    var stateMessage: String? = null
        private set
    var askedAt = 0L
        private set
    private var ui: Ui? = null
    var currentId = 0

    private var listed = false
    private var linked: Session? = null
    private var size: IntArray? = null
    private var lastId = 0
    private var hubListening = false
    private val main = Handler(Looper.getMainLooper())
    private val onHub: () -> Unit = { sync() }

    fun handle(m: JSONObject) { main.post { onMessage(m) } }

    /** Called on the session read thread: do not block. */
    fun onOutput(id: Int, data: ByteArray, off: Int, len: Int) {
        val b = data.copyOfRange(off, off + len)
        main.post { find(id)?.session?.appendOutput(b, b.size) }
    }

    fun linkClosed() { main.post { resetLink() } }

    fun attach(u: Ui) {
        ui = u
        if (!hubListening) { Hub.addListener(onHub); hubListening = true }
        sync()
    }

    fun detach(u: Ui) { if (ui === u) ui = null }

    fun find(id: Int) = tabs.firstOrNull { it.id == id }

    fun newTab(): Tab? {
        if (tabs.size >= MAX_TABS) return null
        val t = addTab(nextId())
        currentId = t.id
        tryOpen(t)
        ui?.tabsChanged()
        return t
    }

    fun close(t: Tab) {
        if (t.openSent && t.exitCode == null) Hub.session?.send(json("t" to "term.close", "id" to t.id))
        val i = tabs.indexOf(t)
        tabs.remove(t)
        if (currentId == t.id) currentId = tabs.getOrNull(maxOf(0, i - 1))?.id ?: 0
        ui?.tabsChanged()
    }

    fun closeOthers(keep: Tab) { tabs.filter { it !== keep }.forEach { close(it) } }

    fun rename(t: Tab, name: String?) {
        t.customTitle = name?.trim()?.takeIf { it.isNotEmpty() }
        ui?.tabsChanged()
    }

    fun restart(t: Tab) {
        t.exitCode = null
        t.exitMessage = null
        t.openSent = false
        t.opened = false
        t.session.recreateEmulator()
        t.session.setRunning()
        ui?.screenReset(t)
        tryOpen(t)
        ui?.tabsChanged()
    }

    /** After a reconnect, asks the Mac for the shells that are still open. */
    private fun sync() {
        val s = Hub.session
        if (s !== linked) {
            resetLink()
            linked = s
        }
        if (s != null && askedAt == 0L) {
            askedAt = System.currentTimeMillis()
            s.send(json("t" to "term.list"))
        }
        ui?.stateChanged()
    }

    private fun onMessage(m: JSONObject) {
        when (m.optString("t")) {
            "term.state" -> {
                state = m.optString("state", "ok")
                stateMessage = m.optString("message").takeIf { it.isNotEmpty() }
                if (state == "disabled") {
                    // The Mac stopped all shells.
                    tabs.clear()
                    currentId = 0
                    listed = false
                } else if (!listed && Hub.session != null && System.currentTimeMillis() - askedAt > 2000) {
                    askedAt = 0L
                    sync()
                }
                ui?.tabsChanged()
                ui?.stateChanged()
            }
            "term.list" -> onList(m)
            "term.opened" -> {
                val t = find(m.optInt("id")) ?: return
                t.opened = true
                t.everOpened = true
                t.exitCode = null
                t.exitMessage = null
                t.shell = m.optString("shell", t.shell).ifEmpty { "zsh" }
                t.session.setRunning()
                if (m.optBoolean("reattached")) {
                    // The Mac resends recent output: start from an empty screen.
                    t.session.recreateEmulator()
                    ui?.screenReset(t)
                }
                ui?.tabsChanged()
            }
            "term.exit" -> {
                val t = find(m.optInt("id")) ?: return
                markExited(t, m.optInt("code"), m.optString("message").takeIf { it.isNotEmpty() })
            }
        }
    }

    private fun onList(m: JSONObject) {
        state = "ok"
        stateMessage = null
        listed = true
        val a = m.optJSONArray("tabs")
        val alive = HashSet<Int>()
        for (i in 0 until (a?.length() ?: 0)) {
            val o = a!!.getJSONObject(i)
            if (!o.optBoolean("alive", true)) continue
            val id = o.optInt("id")
            if (id <= 0) continue
            alive.add(id)
            val t = find(id) ?: addTab(id)
            t.macTitle = o.optString("title").takeIf { it.isNotEmpty() }
            t.exitCode = null
            t.openSent = false
            t.opened = false
        }
        // Tabs the Mac does not have: their shells stopped while the phone was away.
        for (t in tabs) {
            if (t.id !in alive && t.everOpened && t.exitCode == null) {
                markExited(t, null, "The shell on the Mac stopped while the phone was not connected.")
            }
        }
        if (tabs.isEmpty()) addTab(nextId())
        if (find(currentId) == null) currentId = tabs.first().id
        tabs.sortBy { it.id }
        tabs.forEach { tryOpen(it) }
        ui?.tabsChanged()
        ui?.stateChanged()
    }

    private fun markExited(t: Tab, code: Int?, message: String?) {
        val exitCode = code ?: -1
        t.exitCode = exitCode
        t.exitMessage = message
        t.opened = false
        t.openSent = false
        t.session.setExited(exitCode)
        val line = StringBuilder("\r\n\u001b[0m\u001b[2m")
        if (message != null) line.append(message).append(' ')
        line.append(if (code != null && code >= 0) "[Process exited (code $code)]" else "[Process exited]")
        line.append("\u001b[0m\r\n")
        val b = line.toString().toByteArray()
        t.session.appendOutput(b, b.size)
        ui?.tabsChanged()
    }

    private fun nextId(): Int {
        lastId = maxOf(lastId, tabs.maxOfOrNull { it.id } ?: 0) + 1
        return lastId
    }

    private fun addTab(id: Int): Tab {
        lastId = maxOf(lastId, id)
        val t = Tab(id)
        t.session = TerminalSession(object : TerminalSession.Transport {
            override fun write(data: ByteArray, offset: Int, count: Int) {
                if (t.opened) Hub.session?.sendTerminal(t.id, data, offset, count)
            }
            override fun resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
                onResize(t, columns, rows, cellWidthPixels, cellHeightPixels)
            }
        }, SCROLLBACK, this)
        tabs.add(t)
        // All tabs share one view, so a new tab can take the current size.
        size?.let { t.session.updateSize(it[0], it[1], it[2], it[3]) }
        return t
    }

    private fun onResize(t: Tab, cols: Int, rows: Int, cw: Int, ch: Int) {
        size = intArrayOf(cols, rows, cw, ch)
        val changed = cols != t.cols || rows != t.rows
        t.cols = cols
        t.rows = rows
        if (t.openSent && changed) Hub.session?.send(json("t" to "term.resize", "id" to t.id, "cols" to cols, "rows" to rows))
        else tryOpen(t)
        for (o in tabs.toList()) if (o !== t && !o.session.isInitialized) o.session.updateSize(cols, rows, cw, ch)
    }

    private fun tryOpen(t: Tab) {
        val s = Hub.session ?: return
        if (t.openSent || t.exitCode != null || !listed || state != "ok" || !t.session.isInitialized || t.cols <= 0) return
        t.openSent = true
        s.send(json("t" to "term.open", "id" to t.id, "cols" to t.cols, "rows" to t.rows))
    }

    private fun resetLink() {
        linked = null
        listed = false
        askedAt = 0L
        state = "unknown"
        stateMessage = null
        for (t in tabs) { t.opened = false; t.openSent = false }
        ui?.stateChanged()
    }

    private fun tabOf(s: TerminalSession?) = tabs.firstOrNull { it.session === s }

    override fun onTextChanged(changedSession: TerminalSession) { tabOf(changedSession)?.let { ui?.screenUpdated(it) } }
    override fun onTitleChanged(changedSession: TerminalSession) { ui?.tabsChanged() }
    override fun onSessionFinished(finishedSession: TerminalSession) {}
    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) { if (text != null) ui?.copy(text) }
    override fun onPasteTextFromClipboard(session: TerminalSession?) { tabOf(session)?.let { ui?.paste(it) } }
    override fun onBell(session: TerminalSession) { ui?.bell() }
    override fun onColorsChanged(session: TerminalSession) { tabOf(session)?.let { ui?.screenUpdated(it) } }
    override fun onTerminalCursorStateChange(state: Boolean) {}
    override fun setTerminalShellPid(session: TerminalSession, pid: Int) {}
    override fun getTerminalCursorStyle(): Int? = null
    // Messages can quote terminal output, which is private: log only the length.
    override fun logError(tag: String?, message: String?) { Log.e(TAG, "$tag: message of ${message?.length ?: 0} characters") }
    override fun logWarn(tag: String?, message: String?) { Log.w(TAG, "$tag: message of ${message?.length ?: 0} characters") }
    override fun logInfo(tag: String?, message: String?) {}
    override fun logDebug(tag: String?, message: String?) {}
    override fun logVerbose(tag: String?, message: String?) {}
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) { Log.e(TAG, "$tag: ${e?.javaClass?.name}") }
    override fun logStackTrace(tag: String?, e: Exception?) { Log.e(TAG, "$tag: ${e?.javaClass?.name}") }
}
