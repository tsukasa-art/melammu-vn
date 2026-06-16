import AppKit
import SwiftUI

@MainActor
final class HUDPanel {
    private var _panel: NSPanel?

    func show(gameName: String, onScreenshot: @escaping () -> Void, onSaveToGallery: @escaping () -> Void, onForceQuit: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        let p: NSPanel
        if let existing = _panel {
            p = existing
        } else {
            p = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hasShadow = false
            _panel = p
        }

        let view = HUDView(gameName: gameName, onScreenshot: onScreenshot, onSaveToGallery: onSaveToGallery, onForceQuit: onForceQuit, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: view)
        p.contentView = hosting
        let size = hosting.fittingSize
        p.setContentSize(size)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24))
        }
        p.orderFront(nil)
    }

    var panel: NSPanel? { _panel }
    var isVisible: Bool { _panel?.isVisible ?? false }
    func hide() { _panel?.orderOut(nil) }
    func orderFront() { _panel?.orderFront(nil) }
    func close() { _panel?.close(); _panel = nil }
}
