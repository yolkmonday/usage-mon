import Foundation

/// Menjalankan CLI `usage-mon --json` dan mengembalikan hasil yang sudah di-decode.
final class UsageRunner {
    enum RunError: LocalizedError {
        case scriptNotFound
        case failed(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "Tidak menemukan script usage-mon"
            case .failed(let msg):
                return "Gagal menjalankan usage-mon: \(msg)"
            case .decode(let msg):
                return "Gagal membaca output JSON: \(msg)"
            }
        }
    }

    let days: Int

    init(days: Int = 7) {
        self.days = days
    }

    /// Cari script usage-mon di beberapa lokasi yang mungkin.
    static func locateScript() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1) relatif terhadap executable: .../MenuBar/.build/<config>/UsageMenuBar
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("usage-mon"))
            dir = dir.deletingLastPathComponent()
        }
        // 2) lokasi default proyek
        let home = fm.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Dev/usage-mon/usage-mon"))
        candidates.append(home.appendingPathComponent("bin/usage-mon"))

        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    func fetch() throws -> UsageReport {
        guard let script = Self.locateScript() else { throw RunError.scriptNotFound }

        let process = Process()
        // Jalankan script: .py -> via python3, selain itu -> langsung (mis. launcher bash)
        if script.pathExtension == "py" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--days", String(days), "--json"]
        } else {
            process.executableURL = script
            process.arguments = ["--days", String(days), "--json"]
        }

        // PATH penting supaya `security` (Keychain) & python3 bisa dipanggil dari app bundle
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw RunError.failed(msg.isEmpty ? "exit \(process.terminationStatus)" : msg)
        }

        do {
            return try JSONDecoder().decode(UsageReport.self, from: data)
        } catch {
            throw RunError.decode(error.localizedDescription)
        }
    }
}
