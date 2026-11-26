import AppKit
import CryptoKit
import SwiftUI

/// macOS shows one Dock icon per process, so each phone app window gets a small helper app (a "shim")
/// with the phone app's name and icon. They talk over distributed notifications.
final class DockShims: NSObject {
    static let shared = DockShims()
    static let settingKey = "appDockIcons"
    private static let prefix = "com.mdobak.phonelink.dock."

    private final class Entry {
        weak var window: NSWindow?
        var label: String?
        var icon: NSImage?
        var bigIcon: NSImage?
        var bigIconAsked = false
        var pending: DispatchWorkItem?
        var running: String?
        var building = false
    }

    private var entries: [String: Entry] = [:]
    /// Shims stopped on purpose (for a rebuild). Their exit does not close the window.
    private var expectedEnds = Set<String>()
    private var enabled = UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    private let work = DispatchQueue(label: "dock-shims", qos: .utility)

    private override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onFocus(_:)), name: .init(Self.prefix + "focus"), object: nil)
        dnc.addObserver(self, selector: #selector(onClose(_:)), name: .init(Self.prefix + "closeRequest"), object: nil)
        dnc.addObserver(self, selector: #selector(onClose(_:)), name: .init(Self.prefix + "quit"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onTerminate(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onDefaults), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onWindowClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        // Stop shims left by an earlier run, e.g. after a crash.
        stopAll()
    }

    // MARK: Window events

    func update(pkg: String, window: NSWindow?, label: String?, icon: NSImage?) {
        guard !pkg.isEmpty else { return }
        let e = entries[pkg] ?? Entry()
        entries[pkg] = e
        if let window { e.window = window }
        if let label { e.label = label }
        if let icon, e.icon == nil { e.icon = icon }
        if pkg == AppStream.desktopID { e.label = "Phone Desktop" }
        e.window?.miniwindowImage = pkg == AppStream.desktopID ? Self.desktopIcon(size: 128) : e.icon.map { Self.dockIcon(from: $0, size: 128) }
        if !e.bigIconAsked, pkg != AppStream.desktopID, AdbAgent.shared.ready {
            e.bigIconAsked = true
            AdbAgent.shared.request(["t": "icon", "pkg": pkg, "size": 256]) { [weak self] r in
                guard let self, let e = self.entries[pkg],
                      let img = (r?["png"] as? String).flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)) else { return }
                e.bigIcon = img
                self.schedule(pkg)
            }
        }
        schedule(pkg)
    }

    func closed(pkg: String) {
        guard let e = entries.removeValue(forKey: pkg) else { return }
        e.pending?.cancel()
        post("close", pkg)
    }

    private func focus(pkg: String) {
        guard let w = entries[pkg]?.window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stopAll() {
        post("closeAll", nil)
    }

    func dockMenu() -> NSMenu? {
        let open = entries.filter { $0.value.window != nil }
            .sorted { ($0.value.label ?? $0.key).localizedStandardCompare($1.value.label ?? $1.key) == .orderedAscending }
        guard !open.isEmpty else { return nil }
        let m = NSMenu()
        for (pkg, e) in open {
            let item = NSMenuItem(title: e.label ?? pkg, action: #selector(menuFocus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pkg
            let img = pkg == AppStream.desktopID ? Self.desktopIcon(size: 32) : e.icon.map { Self.dockIcon(from: $0, size: 32) }
            img?.size = NSSize(width: 16, height: 16)
            item.image = img
            m.addItem(item)
        }
        return m
    }

    @objc private func menuFocus(_ item: NSMenuItem) {
        if let pkg = item.representedObject as? String { focus(pkg: pkg) }
    }

    // MARK: Notifications

    @objc private func onFocus(_ n: Notification) {
        guard let pkg = n.object as? String else { return }
        DispatchQueue.main.async { self.focus(pkg: pkg) }
    }

    @objc private func onClose(_ n: Notification) {
        guard let pkg = n.object as? String else { return }
        DispatchQueue.main.async { self.entries[pkg]?.window?.performClose(nil) }
    }

    @objc private func onTerminate(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, id.hasPrefix(Self.prefix) else { return }
        DispatchQueue.main.async {
            if self.expectedEnds.remove(id) != nil { return }
            // The user quit the shim, or it stopped. Close its window.
            guard let e = self.entries.first(where: { Self.bundleID($0.key) == id })?.value, e.running != nil else { return }
            e.running = nil
            e.window?.close()
        }
    }

    @objc private func onWindowClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let pkg = entries.first(where: { $0.value.window === w })?.key else { return }
        closed(pkg: pkg)
    }

    @objc private func onDefaults() {
        // UserDefaults can post this on any thread; entries is main-thread state.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.onDefaults() }
            return
        }
        let now = UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
        guard now != enabled else { return }
        enabled = now
        if now {
            entries.keys.forEach(schedule)
        } else {
            for (pkg, e) in entries where e.running != nil {
                e.running = nil
                expectedEnds.insert(Self.bundleID(pkg))
                post("close", pkg)
            }
        }
    }

    private func post(_ name: String, _ pkg: String?) {
        DistributedNotificationCenter.default().postNotificationName(.init(Self.prefix + name), object: pkg, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Shim bundles

    private static var helperURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PhoneLinkDockShim")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    private static var dockFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Link/Dock", isDirectory: true)
    }

    private static func idPart(_ pkg: String) -> String {
        let s = String(pkg.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" })
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private static func bundleID(_ pkg: String) -> String { prefix + idPart(pkg) }

    private func schedule(_ pkg: String) {
        guard let e = entries[pkg] else { return }
        e.pending?.cancel()
        guard enabled, Self.helperURL != nil, e.window != nil else { return }
        let desk = pkg == AppStream.desktopID
        let ready = desk || (e.label != nil && e.icon != nil && (e.bigIcon != nil || !e.bigIconAsked))
        let w = DispatchWorkItem { [weak self] in self?.launch(pkg) }
        e.pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (ready ? 0.3 : 4), execute: w)
    }

    private func launch(_ pkg: String) {
        guard enabled, let e = entries[pkg], e.window != nil, !e.building, let helper = Self.helperURL else { return }
        let desk = pkg == AppStream.desktopID
        let label = desk ? "Phone Desktop" : (e.label ?? pkg)
        let source = e.bigIcon ?? e.icon
        let iconData = desk ? Data("desktop-1".utf8) : (source?.tiffRepresentation ?? Data())
        let attrs = try? FileManager.default.attributesOfItem(atPath: helper.path)
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        var h = SHA256()
        // Bump "style" when the icon drawing changes so old bundles are rebuilt.
        h.update(data: Data("style 2|\(label)|\(version)|\((attrs?[.size] as? NSNumber)?.intValue ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|".utf8))
        h.update(data: iconData)
        let fp = h.finalize().map { String(format: "%02x", $0) }.joined()
        if e.running == fp { return }

        let id = Self.bundleID(pkg)
        let wasRunning = e.running != nil || !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        e.building = true
        let icns: Data?
        if desk {
            icns = Self.icns { Self.desktopIcon(size: $0) }
        } else if let source {
            icns = Self.icns { Self.dockIcon(from: source, size: $0) }
        } else {
            icns = Self.icns { Self.desktopIcon(size: $0, symbol: "app") }
        }
        work.async {
            let app = Self.makeBundle(pkg: pkg, id: id, label: label, fingerprint: fp, icns: icns, helper: helper)
            DispatchQueue.main.async {
                e.building = false
                guard let app, self.enabled, self.entries[pkg] === e, e.window != nil else { return }
                if wasRunning {
                    // Stop the old shim first; it has the old name or icon.
                    self.expectedEnds.insert(id)
                    self.post("close", pkg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.open(app, pkg: pkg, fingerprint: fp) }
                } else {
                    self.open(app, pkg: pkg, fingerprint: fp)
                }
            }
        }
    }

    private func open(_ app: URL, pkg: String, fingerprint: String) {
        guard let e = entries[pkg], e.window != nil else { return }
        e.running = fingerprint
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.addsToRecentItems = false
        c.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: app, configuration: c) { _, error in
            if let error {
                NSLog("A Dock icon did not start: %@", error.localizedDescription)
                DispatchQueue.main.async { if self.entries[pkg]?.running == fingerprint { self.entries[pkg]?.running = nil } }
            }
        }
    }

    /// Runs on the work queue.
    private static func makeBundle(pkg: String, id: String, label: String, fingerprint: String, icns: Data?, helper: URL) -> URL? {
        let fm = FileManager.default
        let folder = dockFolder.appendingPathComponent(idPart(pkg), isDirectory: true)
        // The file name is what the Dock and the app switcher show.
        var name = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") || name.isEmpty { name = idPart(pkg) }
        let app = folder.appendingPathComponent(name + ".app", isDirectory: true)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        if let d = NSDictionary(contentsOf: plistURL), d["PhoneLinkFingerprint"] as? String == fingerprint { return app }

        do {
            try? fm.removeItem(at: folder)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: helper, to: contents.appendingPathComponent("MacOS/PhoneLinkDockShim"))
            if let icns { try icns.write(to: contents.appendingPathComponent("Resources/AppIcon.icns")) }
            let plist: [String: Any] = [
                "CFBundleExecutable": "PhoneLinkDockShim",
                "CFBundleIdentifier": id,
                "CFBundleName": label,
                "CFBundleDisplayName": label,
                "CFBundleIconFile": "AppIcon",
                "CFBundlePackageType": "APPL",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0",
                "LSMultipleInstancesProhibited": true,
                "NSHighResolutionCapable": true,
                "NSPrincipalClass": "NSApplication",
                "PhoneLinkPackage": pkg,
                "PhoneLinkHost": Bundle.main.bundleIdentifier ?? "com.mdobak.phonelink",
                "PhoneLinkFingerprint": fingerprint,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", app.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            // Register with Launch Services so the Dock does not show a cached icon.
            LSRegisterURL(app as CFURL, true)
            return app
        } catch {
            NSLog("Cannot make a Dock icon bundle: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: Icons

    /// Fits a phone app icon to the macOS icon grid (824 pt square in a 1024 pt canvas).
    private static func dockIcon(from src: NSImage, size: Int) -> NSImage {
        render(size: size) { rect in
            guard let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let img = NSImage(cgImage: cg, size: .zero)
            if let fit = shapeFit(cg) {
                // Android icons are masked (circle, squircle). Scale up so the background fills the square.
                fit.fill.draw(in: rect, angle: -90)
                let side = rect.width * fit.scale
                img.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                         from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                // No plain background: put it on white.
                NSColor.white.setFill()
                rect.fill()
                img.draw(in: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    /// Finds the shape background and the scale that makes it cover the macOS square.
    /// nil if the icon has no plain background at its edges.
    private static func shapeFit(_ cg: CGImage) -> (fill: NSGradient, scale: CGFloat)? {
        let rep = NSBitmapImageRep(cgImage: cg)
        let n = rep.pixelsWide
        guard n >= 16, rep.pixelsHigh == n else { return nil }
        let c = CGFloat(n - 1) / 2
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: min(n - 1, max(0, Int(x.rounded()))), y: min(n - 1, max(0, Int(y.rounded()))))?.usingColorSpace(.sRGB)
        }
        /// In icon widths.
        func reach(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat? {
            let len = (dx * dx + dy * dy).squareRoot()
            var t = c * len
            while t > 0 {
                let x = c + dx / len * t, y = c + dy / len * t
                if (pixel(x, y)?.alphaComponent ?? 0) > 0.95 { return t / CGFloat(n) }
                t -= 0.5
            }
            return nil
        }
        guard let axis = [reach(0, -1), reach(0, 1), reach(-1, 0), reach(1, 0)].compactMap({ $0 }).min(),
              let diag = [reach(-1, -1), reach(1, -1), reach(-1, 1), reach(1, 1)].compactMap({ $0 }).min(),
              axis > 0.3, diag > 0.3 else { return nil }
        // Colors just inside the shape edge: top, bottom, left, right, then the four corners.
        var p: [NSColor] = []
        let inA = (axis - 0.025) * CGFloat(n), inD = (diag - 0.025) * CGFloat(n) / 2.squareRoot()
        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] as [(CGFloat, CGFloat)] {
            if let s = pixel(c + dx * inA, c + dy * inA) { p.append(s) }
        }
        for (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
            if let s = pixel(c + dx * inD, c + dy * inD) { p.append(s) }
        }
        guard p.count == 8, p.allSatisfy({ $0.alphaComponent > 0.95 }) else { return nil }
        func near(_ a: NSColor, _ b: NSColor, _ limit: CGFloat = 0.15) -> Bool {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < limit
        }
        // Allow a vertical gradient: left and right must match, and each corner must match its top or bottom side.
        // Otherwise the edges show a picture, not a plain background.
        guard near(p[2], p[3]), near(p[4], p[5]), near(p[6], p[7]), near(p[0], p[4], 0.2), near(p[1], p[6], 0.2) else { return nil }
        // The gradient fills the corners.
        let scale = min(0.5 / axis * 1.01, 1.3)
        guard let fill = NSGradient(colors: [p[0], p[2], p[1]], atLocations: [0, 0.5, 1], colorSpace: .sRGB)
                ?? NSGradient(starting: p[0], ending: p[1]) else { return nil }
        return (fill, scale)
    }

    private static func desktopIcon(size: Int, symbol: String = "rectangle.on.rectangle") -> NSImage {
        render(size: size) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 1),
                       ending: NSColor(srgbRed: 0.04, green: 0.36, blue: 0.9, alpha: 1))?.draw(in: rect, angle: -90)
            let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = sym.size
                let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
                sym.draw(in: r)
            }
        }
    }

    private static func render(size: Int, content: (NSRect) -> Void) -> NSImage {
        let s = CGFloat(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = NSSize(width: s, height: s)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let k = s / 1024
        let rect = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 185.4 * k, yRadius: 185.4 * k)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
        sh.shadowOffset = NSSize(width: 0, height: -10 * k)
        sh.shadowBlurRadius = 20 * k
        sh.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        content(rect)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: s, height: s))
        img.addRepresentation(rep)
        return img
    }

    private static func icns(_ make: (Int) -> NSImage) -> Data? {
        let types: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
                                      ("ic08", 256), ("ic13", 256), ("ic09", 512), ("ic14", 512), ("ic10", 1024)]
        var cache: [Int: Data] = [:]
        var body = Data()
        for (type, size) in types {
            if cache[size] == nil {
                guard let rep = make(size).representations.first as? NSBitmapImageRep,
                      let png = rep.representation(using: .png, properties: [:]) else { return nil }
                cache[size] = png
            }
            let png = cache[size]!
            body.append(Data(type.utf8))
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var out = Data("icns".utf8)
        out.append(bigEndian(UInt32(body.count + 8)))
        out.append(body)
        return out
    }

    private static func bigEndian(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
}

struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { AccessorView(found: found) }
    func updateNSView(_ v: NSView, context: Context) {}

    private final class AccessorView: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { self.found(w) } }
        }
    }
}
