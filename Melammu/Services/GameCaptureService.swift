import Foundation
import CoreGraphics
import AppKit

// Writes BGRA snap file consumed by Wine's wine_capture_window_pixels_bgra.
// File format: [UInt32 width][UInt32 height][UInt32 stride_bytes] + raw BGRA pixels (top-down).
//
// On macOS 26, all display capture APIs except ScreenCaptureKit are removed.
// SCK does not enumerate Wine's CAMetalLayer windows and its display capture
// sees through the Metal layer to the compositor behind it.
// The only working capture path is screencapture -W (user-initiated window click).
// This class therefore provides no automatic timer — callers supply the image
// (e.g. from the HUD screenshot button) via writeSnap(from:).
final class GameCaptureService: @unchecked Sendable {
    static let snapPath = "/tmp/melammu_snap.bgra"
    /// Persistent snap directory: survives reboots.  d3d9 falls back here when /tmp is empty.
    static let persistentSnapDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".melammu_snaps")
    }()

    private let targetPID: pid_t

    init(pid: pid_t) { targetPID = pid }

    func start() {}

    func stop() {
        // snap ファイルは残す（次のゲーム起動でも使えるように）
    }

    /// Write a CGImage to the snap file for Wine to consume as a save thumbnail.
    func writeSnap(from image: CGImage) {
        writeBGRA(image: image)
    }

    /// Copy the current snap to a per-slot path so Wine can inject it for a specific save slot.
    /// Writes to both /tmp (live session) and the persistent directory (~/.melammu_snaps/).
    func writePerSlotSnap(slot: UInt) {
        let src = URL(fileURLWithPath: Self.snapPath)
        let slotName = "melammu_snap_\(String(format: "%03d", slot)).bgra"

        // /tmp (current session)
        let dst = URL(fileURLWithPath: "/tmp/\(slotName)")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)

        // Persistent directory
        ensurePersistentSnapDir()
        let pDst = Self.persistentSnapDir.appendingPathComponent(slotName)
        try? FileManager.default.removeItem(at: pDst)
        try? FileManager.default.copyItem(at: src, to: pDst)
    }

    private func ensurePersistentSnapDir() {
        Self.ensurePersistentSnapDirStatic()
    }

    static func ensurePersistentSnapDirStatic() {
        try? FileManager.default.createDirectory(
            at: persistentSnapDir,
            withIntermediateDirectories: true)
    }

    private func writeBGRA(image: CGImage) {
        let width = image.width
        let height = image.height
        let rowBytes = width * 4

        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixels, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: rowBytes, space: cs,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                            | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        for i in Swift.stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 0xFF }

        var w32 = UInt32(width), h32 = UInt32(height), s32 = UInt32(rowBytes)
        var data = Data(bytes: &w32, count: 4)
        data.append(Data(bytes: &h32, count: 4))
        data.append(Data(bytes: &s32, count: 4))
        data.append(contentsOf: pixels)
        try? data.write(to: URL(fileURLWithPath: Self.snapPath), options: .atomic)
    }
}
