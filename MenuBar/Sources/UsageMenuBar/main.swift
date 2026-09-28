import AppKit
import SwiftUI
import Combine

/// App menu bar tanpa dock icon. Menampilkan persentase kuota tertinggi dan popup detail.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = UsageModel()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isAlreadyRunning() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "…"
            button.image = Self.gaugeIcon()
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model)
        )

        model.refresh()
        updateTitle()

        // refresh tiap 60 detik (Timer di main run loop -> aman MainActor)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refresh()
            }
        }

        // update judul menu bar saat state berubah
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
    }

    /// Cegah instance kedua jalan bersamaan (mis. buka app 2x dari Finder).
    /// Untuk dev build (`swift run`) bundleIdentifier bisa nil -> anggap tidak duplikat.
    static func isAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleID && app.processIdentifier != myPID
        }
    }

    /// Ikon gauge dari resource bundle. Template agar ikut warna status.
    static func gaugeIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "gauge", withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if let (pct, sev) = model.peakPercent {
            let color: NSColor
            switch sev {
            case .normal: color = .labelColor
            case .warning: color = .systemOrange
            case .critical: color = .systemRed
            }
            button.image = Self.gaugeIcon()
            button.contentTintColor = color
            button.attributedTitle = NSAttributedString(
                string: String(format: "%.0f%%", pct),
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                ]
            )
        } else if model.errorMessage != nil {
            button.image = Self.gaugeIcon()
            button.contentTintColor = .systemOrange
            button.title = "⚠︎"
        } else {
            button.image = Self.gaugeIcon()
            button.contentTintColor = .secondaryLabelColor
            button.title = "—"
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// Entry point. Top-level code di main.swift dijalankan di main thread, jadi
// kita bisa mengasumsikan isolasi MainActor untuk membuat AppDelegate.
let app = NSApplication.shared

// Mode debug: `UsageMenuBar --once` mencetak hasil fetch lalu keluar (tanpa GUI).
if CommandLine.arguments.contains("--once") {
    do {
        let report = try UsageRunner(days: 7).fetch()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(report)
        print(String(data: data, encoding: .utf8) ?? "{}")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Mode debug: `UsageMenuBar --icon` cek apakah ikon resource bisa dimuat.
if CommandLine.arguments.contains("--icon") {
    MainActor.assumeIsolated {
        if let img = AppDelegate.gaugeIcon() {
            print("ikon OK: \(Int(img.size.width))x\(Int(img.size.height)) template=\(img.isTemplate)")
        } else {
            print("ikon GAGAL dimuat")
            exit(1)
        }
    }
    exit(0)
}

// Mode debug: `UsageMenuBar --title` mencetak label menu bar yang akan ditampilkan.
if CommandLine.arguments.contains("--title") {
    MainActor.assumeIsolated {
        let model = UsageModel()
        model.days = 7
        model.refresh()
        // tunggu fetch async selesai (maks 20s)
        let deadline = Date().addingTimeInterval(20)
        while model.report == nil && model.errorMessage == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let (pct, sev) = model.peakPercent {
            let name: String
            switch sev {
            case .normal: name = "hijau"
            case .warning: name = "oranye"
            case .critical: name = "merah"
            }
            print(String(format: "menu bar: %.0f%% (%@)", pct, name))
        } else if let e = model.errorMessage {
            print("menu bar: ⚠︎  (\(e))")
        } else {
            print("menu bar: —")
        }
    }
    exit(0)
}

var appDelegateRef: AppDelegate?
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    appDelegateRef = delegate
    app.delegate = delegate
}
app.run()
