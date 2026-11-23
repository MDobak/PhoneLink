import AppKit

// Dock icon shim. Phone Link copies this app into one bundle per phone app window, with that app's name and icon.
// It shows no window and hands activation back to Phone Link.

let info = Bundle.main.infoDictionary ?? [:]
let pkg = info["PhoneLinkPackage"] as? String ?? ""
let host = info["PhoneLinkHost"] as? String ?? "com.mdobak.phonelink"
let prefix = "com.mdobak.phonelink.dock."

func post(_ name: String) {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name(prefix + name), object: pkg, userInfo: nil, deliverImmediately: true)
}

final class ShimDelegate: NSObject, NSApplicationDelegate {
    /// Phone Link asked us to stop, so do not ask it to close the window.
    var hostAsked = false
    var timer: Timer?
    var lastFocus = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
        // The user only sees this briefly, before Phone Link becomes active.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main

        let dnc = DistributedNotificationCenter.default()
        for name in ["close", "closeAll"] {
            dnc.addObserver(forName: NSNotification.Name(prefix + name), object: name == "close" ? pkg : nil, queue: .main) { [weak self] _ in
                self?.hostAsked = true
                NSApp.terminate(nil)
            }
        }
        // Phone Link can exit without a message (e.g. a crash). Exit too.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            if NSRunningApplication.runningApplications(withBundleIdentifier: host).isEmpty {
                self?.hostAsked = true
                NSApp.terminate(nil)
            }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: host).isEmpty { hostAsked = true; NSApp.terminate(nil) }
    }

    func applicationDidBecomeActive(_ n: Notification) { focus() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        focus()
        return false
    }

    func focus() {
        guard Date().timeIntervalSince(lastFocus) > 0.3 else { return }
        lastFocus = Date()
        post("focus")
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: host)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
            app.activate(from: .current, options: [])
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "").target = self
        return m
    }

    @objc func closeWindow() { post("closeRequest") }

    func applicationWillTerminate(_ n: Notification) {
        if !hostAsked { post("quit") }
    }
}

let app = NSApplication.shared
let delegate = ShimDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
