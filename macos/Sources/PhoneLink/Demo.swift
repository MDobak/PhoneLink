import AppKit
import SwiftUI

/// Sample data for screenshots: run with PHONELINK_DEMO=1. The names and numbers are invented.
extension PhoneLink {
    static var isDemo: Bool { ProcessInfo.processInfo.environment["PHONELINK_DEMO"] != nil }

    func loadDemo() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func ago(_ m: Int64) -> Int64 { now - m * 60_000 }
        demoApply(
            phone: "Galaxy S24 Ultra", battery: 78,
            threads: [
                ["id": 1, "address": "+1 415 555 0132", "name": "Emma Carter", "snippet": "Great, see you at 7 then! I booked the table by the window.", "date": ago(4), "unread": 1],
                ["id": 2, "address": "+1 415 555 0178", "name": "James Miller", "snippet": "Can you send me the invoice from last week?", "date": ago(95), "unread": 0],
                ["id": 3, "address": "UPS", "snippet": "Your package will arrive today between 2 PM and 6 PM.", "date": ago(300), "unread": 0],
                ["id": 4, "address": "+1 415 555 0101", "name": "Mom", "snippet": "Call me when you are free", "date": ago(1500), "unread": 0],
                ["id": 5, "address": "+1 415 555 0145", "name": "Daniel Brooks", "snippet": "Thanks!", "date": ago(4000), "unread": 0],
            ],
            messages: [
                ["id": 10, "thread": 1, "address": "+1 415 555 0132", "body": "Are we still on for dinner tonight?", "date": ago(40), "type": 1],
                ["id": 11, "thread": 1, "address": "+1 415 555 0132", "body": "Yes! 7 o'clock works for me.", "date": ago(38), "type": 2],
                ["id": 12, "thread": 1, "address": "+1 415 555 0132", "body": "Do you want me to pick you up on the way?", "date": ago(37), "type": 2],
                ["id": 13, "thread": 1, "address": "+1 415 555 0132", "body": "No need, I will take the train.", "date": ago(6), "type": 1],
                ["id": 14, "thread": 1, "address": "+1 415 555 0132", "body": "Great, see you at 7 then! I booked the table by the window.", "date": ago(4), "type": 1],
            ],
            notifications: [
                ["key": "n1", "pkg": "com.whatsapp", "app": "WhatsApp", "title": "Olivia", "text": "Did you see the photos from Saturday? I put all of them in the shared album, the ones from the lake are the best.", "time": ago(2), "actions": [["index": 0, "title": "Reply", "reply": true], ["index": 1, "title": "Mark as read", "reply": false]]],
                ["key": "n1b", "pkg": "com.whatsapp", "app": "WhatsApp", "title": "Family", "text": "Mom: Lunch on Sunday at 2? Bring the cake plate back please.", "time": ago(9), "actions": [["index": 0, "title": "Reply", "reply": true], ["index": 1, "title": "Mark as read", "reply": false]]],
                ["key": "n1c", "pkg": "com.whatsapp", "app": "WhatsApp", "title": "Daniel Brooks", "text": "Sent you the slides.", "time": ago(31), "actions": [["index": 0, "title": "Reply", "reply": true], ["index": 1, "title": "Mark as read", "reply": false]]],
                ["key": "n2", "pkg": "com.google.android.gm", "app": "Gmail", "title": "Your flight is confirmed", "text": "SFO → LIS, Friday 6:40 AM, seat 14C. Check-in opens 24 hours before departure. If you check a bag, show the booking code K7Q2PD at the desk.", "time": ago(18), "actions": [["index": 0, "title": "Archive", "reply": false], ["index": 1, "title": "Reply", "reply": true]]],
                ["key": "n2b", "pkg": "com.google.android.gm", "app": "Gmail", "title": "Lisbon trip", "text": "Sophie added 3 photos to the shared album.", "time": ago(190), "actions": [["index": 0, "title": "Archive", "reply": false]]],
                ["key": "n3", "pkg": "com.revolut.revolut", "app": "Revolut", "title": "Payment", "text": "You paid $12.40 at Blue Bottle Coffee", "time": ago(64), "actions": []],
                ["key": "n4", "pkg": "com.google.android.calendar", "app": "Calendar", "title": "Design review", "text": "Today 3:00 – 4:00 PM · Room 2", "time": ago(120), "actions": [["index": 0, "title": "Snooze", "reply": false], ["index": 1, "title": "Email guests", "reply": false]]],
                ["key": "n5", "pkg": "com.instagram.android", "app": "Instagram", "title": "sophie.t", "text": "liked your photo.", "time": ago(300), "actions": []],
            ],
            contacts: [
                ["name": "Emma Carter", "number": "+1 415 555 0132", "label": "Mobile", "starred": true],
                ["name": "Mom", "number": "+1 415 555 0101", "label": "Mobile", "starred": true],
                ["name": "Daniel Brooks", "number": "+1 415 555 0145", "label": "Work", "starred": false],
                ["name": "James Miller", "number": "+1 415 555 0178", "label": "Mobile", "starred": false],
                ["name": "Sophie Turner", "number": "+1 415 555 0190", "label": "Home", "starred": false],
            ]
        )
        PinnedApps.shared.loadDemo()
        QuickControls.shared.loadDemo()
    }
}

/// Demo only: invented icons, because there is no phone to send the real ones.
struct DemoAppIcon: View {
    let pkg: String
    var size: CGFloat = 32

    private var look: (Color, String) {
        switch pkg {
        case "com.whatsapp": return (.green, "phone.bubble.fill")
        case "com.google.android.gm": return (.red, "envelope.fill")
        case "com.spotify.music": return (Color(white: 0.12), "waveform")
        case "com.google.android.apps.maps": return (.teal, "map.fill")
        case "com.revolut.revolut": return (.indigo, "creditcard.fill")
        case "com.google.android.calendar": return (.blue, "calendar")
        case "com.instagram.android": return (.pink, "camera.fill")
        case "com.netflix.mediaclient": return (.red, "play.tv.fill")
        case "com.duolingo": return (.mint, "graduationcap.fill")
        default: return (.gray, "app.fill")
        }
    }

    var body: some View {
        let (color, symbol) = look
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(color.gradient)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
