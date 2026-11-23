import Foundation

enum PhonePath: String {
    case app
    /// ShellAgent over USB or Wireless debugging. Needs no app on the phone.
    case shell
}

/// Picks the path for each JSON request. Screen sharing over adb, Remote Desktop, Terminal and file data bypass it.
enum PhoneRouter {
    /// False when no feature may use adb. Then Phone Link sends no adb commands.
    static var usesDebugging: Bool {
        PhoneFeature.allCases.contains { f in f.spec.shell != nil && (f.choice == .auto || f.choice == .shell) }
    }

    /// Types not in the table go to the app only.
    static func feature(_ type: String) -> PhoneFeature? { PhoneFeature.forRequest(type) }

    static func canRetry(_ type: String, from failed: PhonePath) -> Bool {
        guard let f = feature(type), f.choice == .auto else { return false }
        let spec = f.spec
        guard spec.retry else { return false }
        return failed == .app ? spec.shell != nil : spec.app != nil
    }

    static func decide(_ type: String, session: Bool, perms: [String: Bool], shellCan: Bool) -> PhonePath? {
        guard let f = feature(type) else { return session ? .app : nil }
        let s = LinkSnapshot(session: session, perms: perms, debugging: usesDebugging, adbLinked: shellCan,
                             helperCan: { _ in shellCan }, adbScreen: shellCan, callAudio: shellCan)
        return FeatureRouting.route(f, s, lastResort: true).path
    }
}
