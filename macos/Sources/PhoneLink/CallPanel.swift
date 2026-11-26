import AppKit
import Combine
import SwiftUI

/// A small floating panel at the top right of the screen during a call, like the system call banner.
final class CallPanelController {
    static let shared = CallPanelController()
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    /// The end of a hide animation checks this, so a new call keeps its panel.
    private var visible = false

    func start() {
        subscription = PhoneLink.shared.$call
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in visible ? self?.show() : self?.hide() }
    }

    private func show() {
        visible = true
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 88),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: CallPanelView().environmentObject(PhoneLink.shared))
            host.frame = p.contentRect(forFrameRect: p.frame)
            p.contentView = host
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 14, y: f.maxY - p.frame.height - 14))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
    }

    private func hide() {
        visible = false
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) { [weak self] in
            if self?.visible == false { p.orderOut(nil) }
        }
    }
}

private struct CallPanelView: View {
    @EnvironmentObject private var link: PhoneLink

    var body: some View {
        Group {
            if let call = link.call {
                CallRow(call: call)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 372, height: 88)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
