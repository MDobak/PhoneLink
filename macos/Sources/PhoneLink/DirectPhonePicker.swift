import SwiftUI

/// Picks a phone to use without the phone app, over USB or Wireless debugging only. Phone Link then connects only to it.
struct DirectPhonePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AdbDevice] = []
    @State private var loaded = false
    @State private var choosing: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Use Without the Phone App").font(.title2.weight(.semibold))
                Text("Use a phone with USB or Wireless debugging only. To send messages and answer calls, install Phone Link on the phone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if AdbManager.path == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Android platform tools are not set up", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text("Set them up in Settings > Connections.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings…") { Router.shared.showSettings("debugging") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Form {
                    Section {
                        if devices.isEmpty {
                            HStack(spacing: 10) {
                                if !loaded { ProgressView().controlSize(.small) }
                                Text(loaded ? "No phones found. Connect a phone with USB or Wireless debugging."
                                            : "Looking for phones…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(devices) { d in row(d) }
                    } header: {
                        Text("Phones Connected to This Mac")
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    Section {
                        DisclosureGroup("How to turn on USB debugging") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("1. On the phone, open Settings > About phone > Software information.")
                                Text("2. Tap Build number seven times.")
                                Text("3. Open Settings > Developer options. Turn on USB debugging.")
                                Text("4. Connect the phone with a USB cable. Then tap Allow on the phone.")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 240)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            while !Task.isCancelled {
                let list = await Task.detached { AdbManager.listDevices() }.value
                devices = list
                loaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private func row(_ d: AdbDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.usb ? "cable.connector" : "wifi")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.displayModel)
                Text(subtitle(d)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if choosing == d.serial {
                ProgressView().controlSize(.small)
            } else {
                Button("Use") { choose(d) }
                    .disabled(d.state != .ready || choosing != nil)
            }
        }
    }

    private func subtitle(_ d: AdbDevice) -> String {
        switch d.state {
        case .ready: d.usb ? "USB cable" : "Wi-Fi"
        case .unauthorized: "Unlock the phone and tap Allow"
        case .offline: "Not available"
        }
    }

    private func choose(_ d: AdbDevice) {
        choosing = d.serial
        error = nil
        AdbManager.shared.useWithoutApp(d) { err in
            choosing = nil
            if let err { error = err } else { dismiss() }
        }
    }
}
