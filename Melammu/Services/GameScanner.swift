import Foundation

enum GameScanner {
    nonisolated static let wrappersPath = NSString("~/Applications/Melammu").expandingTildeInPath

    static func scan() -> [URL] {
        let dir = URL(fileURLWithPath: wrappersPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
