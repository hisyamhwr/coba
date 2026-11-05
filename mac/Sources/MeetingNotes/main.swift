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
        updateTopInset()

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

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    private func updateMousePassthrough() {
        guard let panel, let controller else { return }
        let state = controller.state
        panel.updateMousePassthrough(islandSize: state.islandSize, topOffset: state.topOffset, shoulder: state.shoulder)
    }

    /// Tinggi notch kamera layar utama (0 bila tidak ada), agar pill tidak tertutup notch.
    private func updateTopInset() {
        let inset = (NSScreen.main ?? NSScreen.screens.first)?.safeAreaInsets.top ?? 0
        if controller.state.topInset != inset { controller.state.topInset = inset }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Notes")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mulai catat", action: #selector(toggle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Buka folder notulen", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Buat juga Word (.docx)", action: #selector(toggleDocx), keyEquivalent: ""))
        menu.addItem(.separator())
        for source in VideoSource.allCases {
            let item = NSMenuItem(title: source.menuTitle, action: #selector(chooseVideo(_:)), keyEquivalent: "")
            item.representedObject = source.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Audio meeting via Core Audio (eksperimental)", action: #selector(toggleTap), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Peredam derau mic", action: #selector(toggleNoise), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bentuk: Island (menyatu dengan notch)", action: #selector(useIsland),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Bentuk: Pill (melayang)", action: #selector(usePill), keyEquivalent: ""))
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
            } else if item.action == #selector(chooseVideo(_:)) {
                item.state = (item.representedObject as? String) == controller.state.videoSource.rawValue ? .on : .off
            } else if item.action == #selector(toggleTap) {
                item.state = controller.state.coreAudioTap ? .on : .off
            } else if item.action == #selector(toggleNoise) {
                item.state = controller.state.micNoiseReduction ? .on : .off
            } else if item.action == #selector(useIsland) {
                item.state = controller.state.style == .island ? .on : .off
            } else if item.action == #selector(usePill) {
                item.state = controller.state.style == .pill ? .on : .off
            }
        }
        switch controller.state.phase {
        case .recording: first.title = "Selesai & susun MoM"
        case .processing: first.title = "Sedang memproses…"
        default: first.title = "Mulai catat"
        }
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func openFolder() { controller.openFolder() }
    @objc private func toggleDocx() { controller.state.exportDocx.toggle() }
    @objc private func chooseVideo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = VideoSource(rawValue: raw) else { return }
        controller.state.videoSource = source
    }
    @objc private func toggleTap() { controller.state.coreAudioTap.toggle() }
    @objc private func toggleNoise() { controller.state.micNoiseReduction.toggle() }
    @objc private func useIsland() { controller.state.style = .island }
    @objc private func usePill() { controller.state.style = .pill }
    @objc private func screenChanged() {
        panel?.place()
        updateTopInset()
    }
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
