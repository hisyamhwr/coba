import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MeetingController!
    private var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MeetingController()
        let panel = IslandPanel.make(rootView: IslandView(state: controller.state, controller: controller))
        panel.resize(to: controller.state.panelSize, animated: false)
        panel.orderFrontRegardless()
        self.panel = panel

        // Ikuti perubahan status; ukuran baru dibaca setelah perubahan diterapkan.
        cancellable = controller.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                panel.resize(to: self.controller.state.panelSize)
                self.updateMenuTitle()
            }
        }

        setUpStatusItem()
        hotKey = HotKey { [weak self] in
            Task { @MainActor in self?.controller.toggle() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Notes")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mulai Catat  (⌃⌥M)", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Buka folder notulen", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Meeting Notes v\(Config.version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func updateMenuTitle() {
        guard let first = statusItem?.menu?.items.first else { return }
        switch controller.state.phase {
        case .recording: first.title = "Selesai & Susun MoM  (⌃⌥M)"
        case .processing: first.title = "Sedang memproses…"
        default: first.title = "Mulai Catat  (⌃⌥M)"
        }
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func openFolder() { controller.openFolder() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// Kode tingkat atas tidak otomatis berjalan di main actor; nyatakan secara eksplisit.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
