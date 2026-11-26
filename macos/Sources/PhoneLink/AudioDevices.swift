import AudioToolbox
import Combine
import CoreAudio
import Foundation
import SwiftUI

/// Main thread.
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()
    /// Device UIDs. Empty means the system default.
    static let inputKey = "callAudioInput"
    static let outputKey = "callAudioOutput"

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    @Published private(set) var inputs: [Device] = []
    @Published private(set) var outputs: [Device] = []
    private var listening = false

    private init() { refresh() }

    func watch() {
        refresh()
        guard !listening else { return }
        listening = true
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in self?.refresh() }
    }

    func refresh() {
        let all = Self.deviceIDs().filter { !Self.isHidden($0) }
        inputs = all.filter { Self.channels($0, kAudioObjectPropertyScopeInput) > 0 }.compactMap(Self.device)
        outputs = all.filter { Self.channels($0, kAudioObjectPropertyScopeOutput) > 0 }.compactMap(Self.device)
    }

    /// Nil for the system default or a disconnected device.
    private static func id(forUID uid: String?, input: Bool) -> AudioDeviceID? {
        guard let uid, !uid.isEmpty else { return nil }
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid && channels($0, scope) > 0 }
    }

    static func chosen(input: Bool) -> AudioDeviceID? {
        id(forUID: UserDefaults.standard.string(forKey: input ? inputKey : outputKey), input: input)
    }

    static func name(_ id: AudioDeviceID) -> String { string(id, kAudioObjectPropertyName) ?? "Unknown" }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// A chosen device that is disconnected stays in the menu; the system default plays instead.
struct AudioDevicePicker: View {
    let title: String
    let input: Bool
    @ObservedObject private var devices = AudioDevices.shared
    @AppStorage private var selection: String

    init(_ title: String, input: Bool) {
        self.title = title
        self.input = input
        _selection = AppStorage(wrappedValue: "", input ? AudioDevices.inputKey : AudioDevices.outputKey)
    }

    var body: some View {
        let list = input ? devices.inputs : devices.outputs
        Picker(title, selection: $selection) {
            Text("System Default").tag("")
            Divider()
            ForEach(list) { Text($0.name).tag($0.uid) }
            if !selection.isEmpty, !list.contains(where: { $0.uid == selection }) {
                Text("Not Connected").tag(selection)
            }
        }
        .onAppear { devices.watch() }
    }
}

struct AudioDevicesMenu: View {
    var body: some View {
        Menu {
            AudioDevicePicker("Microphone", input: true).pickerStyle(.inline)
            AudioDevicePicker("Speaker", input: false).pickerStyle(.inline)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone and Speaker")
        .accessibilityLabel("Microphone and Speaker")
    }
}
