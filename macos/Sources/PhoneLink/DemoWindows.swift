import AppKit
import SwiftUI

/// Demo only: the menu bar content in a normal window, for captures.
enum DemoWindows {
    static var window: NSWindow?
    static func open() {
        // Demo only: PHONELINK_DEMO_APPEARANCE=light or dark sets the appearance of all windows.
        switch ProcessInfo.processInfo.environment["PHONELINK_DEMO_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // Demo only: PHONELINK_DEMO_MEDIA=1 shows sample media in the Now Playing tile.
        let media = ProcessInfo.processInfo.environment["PHONELINK_DEMO_MEDIA"] == nil ? nil
            : MediaInfo(app: "Spotify", title: "Midnight City", artist: "M83", playing: true, position: 0, duration: 0,
                        canNext: true, canPrevious: true, updated: Date())
        // PHONELINK_DEMO_MENU=0 skips this window, so that the main window stays the key window.
        if ProcessInfo.processInfo.environment["PHONELINK_DEMO_MENU"] != "0" {
            let host = NSHostingView(rootView: MenuBarView(previewMedia: media).environmentObject(PhoneLink.shared).environmentObject(Router.shared)
                .background(.regularMaterial))
            let w = NSWindow(contentRect: NSRect(x: 80, y: 200, width: 340, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Menu Bar Preview"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.makeKeyAndOrderFront(nil)
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch ProcessInfo.processInfo.environment["PHONELINK_DEMO"] {
            case "phone", "call": Router.shared.show(.phone)
            case "notifications": Router.shared.show(.notifications)
            // Demo only: opens the WhatsApp group and the card of its second notification.
            case "notificationsopen": Router.shared.show(.notifications, notification: "n1b")
            case "compose": Router.shared.show(.messages, compose: true)
            case "screen": Router.shared.mirror()
            case "screenswitch":
                Router.shared.show(.messages, thread: 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Router.shared.show(.screen) }
            case "screenwin":
                Router.shared.mirror()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Router.shared.detachScreen() }
            case "files": FileHub.shared.loadDemo(); Router.shared.show(.files)
            case "deletephotos": PhoneLink.shared.loadDemoPhotos(); Router.shared.show(.photos)
            case "device": Router.shared.show(.device)
            case "settings":
                // Select the tab with the launch argument "-settingsTab <tag>" (general, phone, files, screen, remote or
                // debugging). The argument does not change the saved value. PHONELINK_DEMO_SETTINGS_SHEET=features also
                // opens the Connection per Feature sheet in the debugging tab.
                AdbManager.shared.loadDemo()
                // The "showSettingsWindow:" action does not open Settings on macOS 14 and later. Use the SwiftUI action.
                Router.shared.showSettings()
            case "remoteaccess":
                // Demo only: Remote Desktop shows as in use. Use with "-settingsTab remote".
                RemoteDesktopHost.shared.showDemo()
                Router.shared.showSettings()
            default: Router.shared.show(.messages, thread: 1)
            }
        }
    }
}
