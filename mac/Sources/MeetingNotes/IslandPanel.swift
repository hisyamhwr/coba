import AppKit
import SwiftUI

/// Jendela tanpa bingkai berukuran tetap di tengah atas layar (area notch), di atas menu bar dan semua Space.
///
/// Ukurannya tidak pernah berubah: pulau di dalamnya yang beranimasi. Area transparan di sekitar pulau
/// meneruskan klik ke aplikasi di bawahnya (lihat `updateMousePassthrough`).
final class IslandPanel: NSPanel {
    /// Cukup untuk ukuran pulau terbesar (plus "bahu" kiri-kanan, jarak pill dari notch, dan pantulan pegas).
    static let canvas = CGSize(width: 540, height: 290)

    override var canBecomeKey: Bool { true }

    static func make<Content: View>(rootView: Content) -> IslandPanel {
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Perlu agar gerak kursor sampai ke aplikasi ini (untuk menentukan kapan klik tembus).
        panel.acceptsMouseMovedEvents = true
        let host = FirstMouseHostingView(rootView: rootView)
        // Jangan biarkan SwiftUI terus menghitung ulang batas ukuran jendela saat isi berubah (mahal).
        host.sizingOptions = []
        panel.contentView = host
        panel.place()
        return panel
    }

    /// Tempelkan ke tengah atas layar utama (dipanggil lagi bila resolusi/layar berubah).
    func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        setFrame(NSRect(
            x: screen.frame.midX - Self.canvas.width / 2,
            y: screen.frame.maxY - Self.canvas.height,
            width: Self.canvas.width,
            height: Self.canvas.height
        ), display: true)
    }

    /// Terima klik hanya saat kursor berada di atas pulau; di luar itu klik tembus ke aplikasi di bawah.
    /// Untuk pill, celah di atasnya (menu bar) tetap tembus.
    func updateMousePassthrough(islandSize: CGSize, topOffset: CGFloat, shoulder: CGFloat) {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let margin: CGFloat = 8
        let width = islandSize.width + shoulder * 2 + margin * 2
        let bottom = screen.frame.maxY - topOffset - islandSize.height - margin
        let top = topOffset > 0 ? screen.frame.maxY - topOffset + margin : screen.frame.maxY
        let rect = NSRect(x: screen.frame.midX - width / 2, y: bottom, width: width, height: top - bottom)
        let inside = rect.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == inside {
            ignoresMouseEvents = !inside
        }
    }
}

/// Klik pertama langsung diproses walau aplikasi sedang tidak aktif (tanpa klik "membangunkan" dulu).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
