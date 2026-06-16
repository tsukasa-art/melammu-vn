import Foundation

struct Game: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String

    // Legacy: .app wrapper path (non-empty when isLegacy == true)
    var wrapperPath: String = ""

    // New install pipeline
    var gameDir: String?   // ~/Library/Application Support/Melammu/Games/<id>/
    var exePath: String?   // prefix-relative path: drive_c/Program Files/.../game.exe
    // Full-copy import: game files dir, mapped to W:\ via prefix dosdevices.
    // May live on an external volume; exePath is relative to this dir when set.
    var gameDataDir: String?

    var engineID: EngineProfile.ID?
    var customCoverPath: String?
    var customBannerPath: String?
    // カバー未設定時のプレースホルダー色（PlaceholderPalette のインデックス）。
    // nil なら名前から決定的に決まる既定色を使う。
    var placeholderColorIndex: Int?
    var dateAdded: Date = Date()
    // DXVK ゲームのウィンドウ表示モード（"crisp" | "large"）。nil なら既定（crisp）。
    var displayMode: String?
    // このゲームだけ別の同梱 wine ランタイムで起動する上書き（wine-support/<subdir>）。
    // engine 既定より優先。エンジンが同じでもゲームごとに最適ランタイムが違うため
    // （managed folder policy）。検証して個別に opt-in する運用。nil なら engine 既定。
    var wineRuntimeOverride: String?

    enum CodingKeys: String, CodingKey {
        case id, name, wrapperPath, gameDir, exePath, gameDataDir
        case engineID = "engine"   // keeps existing library.json readable
        case customCoverPath, customBannerPath, placeholderColorIndex, dateAdded
        case displayMode, wineRuntimeOverride
    }

    /// DXVK ゲームのウィンドウ表示モード。
    /// large = 非Retina（他ゲームと同じ通常サイズ・大きめ）。既定。画面外に飛ぶ問題は
    ///         同梱 wine の Mac ドライバ側クランプ修正で吸収するので権限不要で画面内に出る。
    /// crisp = RetinaMode=y で等倍くっきり・小さめ（鮮明さ優先したい人向けのオプション）。
    enum DisplayMode: String, CaseIterable {
        case large
        case crisp
    }

    var resolvedDisplayMode: DisplayMode {
        displayMode.flatMap { DisplayMode(rawValue: $0) } ?? .large
    }

    // MARK: - Computed

    var wrapperURL: URL { URL(fileURLWithPath: wrapperPath) }

    var isLegacy: Bool { gameDir == nil }

    /// in-place レガシーエントリ: gameDir はあるが gameDataDir 未設定で exePath が
    /// 絶対パス＝原本を Downloads 等から直起動している（フルコピー未取り込み）。
    /// 起動時に管理フォルダ `Games/<id>/gamedata` へ移行する。
    /// 方針: managed folder policy。
    var needsFullCopyMigration: Bool {
        gameDir != nil && gameDataDir == nil && (exePath?.hasPrefix("/") ?? false)
    }

    var prefixURL: URL? {
        guard let dir = gameDir else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent("prefix")
    }

    var gameDataURL: URL? {
        gameDataDir.map { URL(fileURLWithPath: $0) }
    }

    var gameExeURL: URL? {
        guard let exe = exePath else { return nil }
        // Absolute path: legacy folder-referenced game (pre full-copy import)
        if exe.hasPrefix("/") { return URL(fileURLWithPath: exe) }
        // Full-copy import: relative to the copied game data dir
        if let dataDir = gameDataURL { return dataDir.appendingPathComponent(exe) }
        guard let prefix = prefixURL else { return nil }
        return prefix.appendingPathComponent(exe)
    }

    var engineProfile: EngineProfile {
        engineID.map { EngineProfile.find($0) } ?? .unknown
    }

    /// 起動に使う同梱 wine ランタイムの subdir。ゲーム個別上書き > エンジン既定。
    var resolvedWineRuntimeSubdir: String? {
        wineRuntimeOverride ?? engineProfile.wineRuntimeSubdir
    }
}
