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
    private var mouseMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MeetingController()
        let panel = IslandPanel.make(
            rootView: IslandView(state: controller.state, meter: controller.meter, controller: controller)
        )
        panel.orderFrontRegardless()
        self.panel = panel

        // Status pulau jarang berubah; cukup perbarui menu dan area klik setelah perubahan diterapkan.
        cancellable = controller.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuTitle()
                self?.updateMousePassthrough()
            }
        }

        // Pantau gerak kursor (tanpa izin khusus) agar klik di luar pulau tembus ke aplikasi lain.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
        updateMousePassthrough()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        setUpStatusItem()
        hotKey = HotKey { [weak self] in
            Task { @MainActor in self?.controller.toggle() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func updateMousePassthrough() {
        guard let panel, let controller else { return }
        panel.updateMousePassthrough(islandSize: controller.state.islandSize)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Notes")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mulai Catat  (⌃⌥M)", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Buka folder notulen", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Buat juga Word (.docx)", action: #selector(toggleDocx), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Transkrip live", action: #selector(toggleLive), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Meeting Notes v\(Config.version)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        updateMenuTitle()
    }

    private func updateMenuTitle() {
        guard let items = statusItem?.menu?.items, let first = items.first else { return }
        for item in items {
            if item.action == #selector(toggleDocx) {
                item.state = controller.state.exportDocx ? .on : .off
            } else if item.action == #selector(toggleLive) {
                item.state = controller.state.liveTranscript ? .on : .off
            }
        }
        switch controller.state.phase {
        case .recording: first.title = "Selesai & Susun MoM  (⌃⌥M)"
        case .processing: first.title = "Sedang memproses…"
        default: first.title = "Mulai Catat  (⌃⌥M)"
        }
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func openFolder() { controller.openFolder() }
    @objc private func toggleDocx() { controller.state.exportDocx.toggle() }
    @objc private func toggleLive() { controller.state.liveTranscript.toggle() }
    @objc private func screenChanged() { panel?.place() }
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
