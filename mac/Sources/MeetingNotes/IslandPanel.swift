import AppKit
import SwiftUI

/// Jendela tanpa bingkai yang menempel di tengah atas layar (area notch), di atas menu bar dan semua Space.
///
/// Sengaja tidak menambah initializer sendiri supaya semua initializer NSPanel diwarisi apa adanya.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static func make<Content: View>(rootView: Content) -> IslandPanel {
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 170, height: 32),
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
        panel.contentView = NSHostingView(rootView: rootView)
        return panel
    }

    func resize(to size: CGSize, animated: Bool = true) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        setFrame(frame, display: true, animate: animated)
    }
}
