import Foundation

/// USB file copy with "adb pull" and "adb push". Much faster than the Wi-Fi link.
enum AdbFiles {
    /// Below this size adb is not faster than the Wi-Fi link.
    static let minSize: Int64 = 8 * 1024 * 1024

    private static let defaultDir = "/storage/emulated/0/Download/Phone Link"

    enum Outcome: Equatable {
        case done(String)
        case failed
        case cancelled
    }

    /// Copies a photo or video from the media store with no app on the phone.
    /// Blocks; do not call on the main thread.
    static func readMedia(serial: String, id: Int64, to local: URL) -> Bool {
        guard let adb = AdbManager.path else { return false }
        for uri in ["content://media/external/images/media/\(id)", "content://media/external/file/\(id)"] {
            guard FileManager.default.createFile(atPath: local.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: local) else { return false }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", serial, "exec-out", "content", "read", "--uri", uri]
            p.standardOutput = h
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            guard (try? p.run()) != nil else { try? h.close(); return false }
            if done.wait(timeout: .now() + 120) == .timedOut {
                // terminationStatus throws while the process runs, so wait for the exit.
                p.terminate()
                done.wait()
            }
            try? h.close()
            // "content" reports errors as text, e.g. "Error while accessing provider".
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
            let reader = try? FileHandle(forReadingFrom: local)
            let head = (try? reader?.read(upToCount: 64)) ?? Data()
            try? reader?.close()
            let text = String(decoding: head, as: UTF8.self)
            if p.terminationStatus == 0, size > 64, !text.hasPrefix("Error"), !text.contains("Exception") { return true }
        }
        try? FileManager.default.removeItem(at: local)
        return false
    }

    static func pull(serial: String, remote: String, to local: URL, job: AdbProcess,
                     progress: @escaping (Int64) -> Void) -> Outcome {
        let r = job.run(["-s", serial, "pull", remote, local.path]) {
            if let n = (try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? NSNumber {
                progress(n.int64Value)
            }
        }
        if job.cancelled { return .cancelled }
        guard let r, r.status == 0, FileManager.default.fileExists(atPath: local.path) else { return .failed }
        return .done(local.path)
    }

    /// Uses the same naming as the phone app: "name (1).ext" when taken, and a hidden part file during the copy.
    /// Then adds the file to the media store. A nil dir means Download/Phone Link.
    static func push(serial: String, local: URL, dir: String?, name: String, job: AdbProcess,
                     progress: @escaping (Int64) -> Void) -> Outcome {
        let d = dir ?? defaultDir
        let qd = AdbManager.quote(d)

        // The base/extension split must match Transfers.kt.
        let dot = name.lastIndex(of: ".")
        let ext = dot.map { name.hasPrefix(".") ? "" : String(name[$0...]) } ?? ""
        let base = dot.map { String(name[..<$0]) } ?? name
        let script = (dir == nil ? "mkdir -p \(qd); " : "")
            + "d=\(qd); [ -d \"$d\" ] || exit 3; f=\"$d\"/\(AdbManager.quote(name)); i=1; "
            + "while [ -e \"$f\" ]; do f=\"$d\"/\(AdbManager.quote(base))\" ($i)\"\(AdbManager.quote(ext)); i=$((i+1)); done; echo \"$f\""
        guard let r = job.run(["-s", serial, "shell", script], timeout: 15) else { return job.cancelled ? .cancelled : .failed }
        guard r.status == 0,
              let final = r.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { !$0.isEmpty }),
              final.hasPrefix(d + "/") else { return .failed }
        let finalName = String(final.dropFirst(d.count + 1))
        let tmp = d + "/." + finalName + ".phonelink-part"

        var lastPoll = Date.distantPast
        let pushed = job.run(["-s", serial, "push", local.path, tmp]) {
            guard Date().timeIntervalSince(lastPoll) >= 1 else { return }
            lastPoll = Date()
            if let s = AdbManager.shell(serial, ["stat -c %s " + AdbManager.quote(tmp)], timeout: 3), s.status == 0,
               let n = Int64(s.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                progress(n)
            }
        }
        func removePart() -> Outcome {
            let cancelled = job.cancelled
            DispatchQueue.global(qos: .utility).async { _ = AdbManager.shell(serial, ["rm -f " + AdbManager.quote(tmp)], timeout: 10) }
            return cancelled ? .cancelled : .failed
        }
        guard let pushed, pushed.status == 0, !job.cancelled else { return removePart() }

        // Do not replace a file that appeared in the meantime.
        let mv = job.run(["-s", serial, "shell", "[ -e \(AdbManager.quote(final)) ] && exit 4; mv \(AdbManager.quote(tmp)) \(AdbManager.quote(final))"], timeout: 15)
        guard let mv, mv.status == 0 else { return removePart() }

        // Failure here is harmless.
        _ = AdbManager.shell(serial, ["content call --uri content://media/external/file --method scan_file --arg " + AdbManager.quote(final)], timeout: 15)
        return .done(final)
    }
}
