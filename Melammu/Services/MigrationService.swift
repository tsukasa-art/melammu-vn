import Foundation

struct MigrationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A（Sikarugir スタンドアロン .app ラッパー）を B（ネイティブ取り込み）へ移行する。
/// A は **読むだけ（非破壊）**。B は新規 `Games/<uuid>/` に作るので A と物理分離。
/// 既存の full-copy import 手順（InstallerService プリミティブ）を再利用し、
/// 加えてセーブ/設定（AppData ＋ drive_c 直下のゲーム名 Save）を A prefix から運ぶ。
final class MigrationService {
    private let service = InstallerService()

    /// - Returns: 取り込んだ B 用 `Game`（呼び出し側が library へ追加・保存する）。
    func migrate(wrapperApp: URL,
                 gameDataRoot: URL? = nil,
                 progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> Game {
        let fm = FileManager.default

        // 1. Info.plist から exe 相対パスとゲーム名を得る
        let infoURL = wrapperApp.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL),
              let pnp = plist["Program Name and Path"] as? String, !pnp.isEmpty else {
            throw MigrationError(message: "Info.plist の \"Program Name and Path\" が読めません: \(wrapperApp.lastPathComponent)")
        }
        let rel = pnp.hasPrefix("/") ? String(pnp.dropFirst()) : pnp   // "Program Files/<名>/<exe>"
        let exeName = (rel as NSString).lastPathComponent
        let relDir  = (rel as NSString).deletingLastPathComponent      // "Program Files/<名>"
        let driveC = wrapperApp.appendingPathComponent("Contents/SharedSupport/prefix/drive_c")
        // symlink（外部SSD配置）も解決
        let aGameDir = driveC.appendingPathComponent(relDir).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: aGameDir.path) else {
            throw MigrationError(message: "ゲーム本体が見つかりません（外部ドライブ未接続の可能性）: \(aGameDir.path)")
        }
        let name = wrapperApp.deletingPathExtension().lastPathComponent

        // 2. エンジン自動判定（不明は unknown=手動相当）
        let engineID = EngineDetector.detect(directory: aGameDir) ?? EngineProfile.unknown.id
        let profile = EngineProfile.find(engineID)

        // 3. full-copy ＋ prefix（startFolderFlow と同手順）
        let id = UUID()
        let dir = try service.makeGameDir(id: id)
        let dataDir = try service.makeGameDataDir(id: id, root: gameDataRoot)
        do {
            progress(0, "ゲームデータをコピー中…")
            try await service.importGameCopy(from: aGameDir, to: dataDir,
                                             excluding: profile.excludedGameFiles, progress: progress)

            let prefix = dir.appendingPathComponent("prefix")
            progress(1, "prefix を作成中…")
            try await service.createPrefix(at: prefix)
            try? service.installFonts(to: prefix)
            await service.registerJapaneseFonts(to: prefix, profile: profile)
            if profile.requiresDXVK {
                progress(1, "DXVK を導入中…")
                try? await service.installDXVK(to: prefix)
            }

            let winRoot = try service.mapGameDataDrive(prefix: prefix, gameDataDir: dataDir)
            _ = service.rewritePathMemoryFiles(in: dataDir, driveRoot: winRoot)

            // exe は Info.plist の名前で照合（無ければ最大候補）
            let candidates = service.detectExesInFolder(dataDir)
            let selectedExe = candidates.first { $0.lastPathComponent.lowercased() == exeName.lowercased() }
                ?? candidates.first
            guard let exe = selectedExe else {
                throw MigrationError(message: "コピー後に実行ファイルが見つかりません: \(name)")
            }

            try await service.applyEngineProfile(profile, to: prefix)

            // 4. セーブ/設定の移行（AppData ＋ drive_c 直下 Save）。失敗しても本体移行は継続。
            migrateUserData(fromWrapper: wrapperApp, gameName: name, toPrefix: prefix)

            let eid: EngineProfile.ID? = engineID == EngineProfile.unknown.id ? nil : engineID
            return service.buildGame(id: id, name: name, gameDir: dir,
                                     gameDataDir: dataDir, selectedExe: exe, engineID: eid)
        } catch {
            service.rollback(gameDir: dir, gameDataDir: dataDir)
            throw error
        }
    }

    /// in-place エントリ（gameDir 有・絶対 exePath が管理フォルダ外＝原本を
    /// Downloads 等から直起動）を、フルコピー取り込みへ移行する。prefix は既存を
    /// 再利用し、ゲームデータだけ `Games/<id>/gamedata` へコピー＋W: 再マップ＋
    /// パス記憶書換し、exePath を相対化する。既存エントリのメタ（id/名前/カバー/
    /// 表示モード/エンジン/ランタイム上書き）は保持。原本は読むだけ（非破壊）。
    /// 方針: managed folder policy。
    func migrateInPlace(_ game: Game,
                        gameDataRoot: URL? = nil,
                        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> Game {
        let fm = FileManager.default
        guard let exe = game.exePath, exe.hasPrefix("/") else {
            throw MigrationError(message: "既にフルコピー取り込み済みです: \(game.name)")
        }
        guard let gameDirPath = game.gameDir else {
            throw MigrationError(message: "gameDir が無く移行できません: \(game.name)")
        }
        // 原本フォルダ = 絶対 exePath の親（例: ~/Downloads/<名>/）
        let source = URL(fileURLWithPath: exe).deletingLastPathComponent()
        guard fm.fileExists(atPath: source.path) else {
            throw MigrationError(message: "元のゲームフォルダが見つかりません（移動/削除/ドライブ未接続の可能性）: \(source.path)")
        }
        let prefix = URL(fileURLWithPath: gameDirPath).appendingPathComponent("prefix")
        guard fm.fileExists(atPath: prefix.path) else {
            throw MigrationError(message: "prefix が無く移行できません: \(game.name)")
        }
        let exeName = (exe as NSString).lastPathComponent
        let profile = game.engineProfile

        let dataDir = try service.makeGameDataDir(id: game.id, root: gameDataRoot)
        progress(0, "ゲームデータをコピー中…")
        try await service.importGameCopy(from: source, to: dataDir,
                                         excluding: profile.excludedGameFiles, progress: progress)

        let winRoot = try service.mapGameDataDrive(prefix: prefix, gameDataDir: dataDir)
        _ = service.rewritePathMemoryFiles(in: dataDir, driveRoot: winRoot)

        let candidates = service.detectExesInFolder(dataDir)
        let selected = candidates.first { $0.lastPathComponent.lowercased() == exeName.lowercased() }
            ?? candidates.first
        guard let exeURL = selected else {
            throw MigrationError(message: "コピー後に実行ファイルが見つかりません: \(game.name)")
        }
        var rel = exeURL.path
        if rel.hasPrefix(dataDir.path + "/") { rel = String(rel.dropFirst(dataDir.path.count + 1)) }

        var migrated = game
        migrated.gameDataDir = dataDir.path
        migrated.exePath = rel
        return migrated
    }

    // MARK: - セーブ/設定 移行フック

    /// A prefix のユーザーデータを B prefix へコピーする:
    ///  (a) `users/<A>/AppData/{Roaming,Local}` 配下のゲーム/メーカー保存（cs2 setup.xml もここ）
    ///  (b) `drive_c/<ゲーム名>/`（yaneurao titles の Save のような drive_c 直下保存）
    /// wine システム生成物（Microsoft/ 等）は除外。既存 B を上書きしない（マージ）。
    private func migrateUserData(fromWrapper app: URL, gameName: String, toPrefix bPrefix: URL) {
        let fm = FileManager.default
        let aPrefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let aDriveC = aPrefix.appendingPathComponent("drive_c")
        let bDriveC = bPrefix.appendingPathComponent("drive_c")

        guard let aUser = winePrefixUserDir(aDriveC) else { return }
        guard let bUser = winePrefixUserDir(bDriveC) else { return }

        // (a) AppData/{Roaming,Local} の非システムサブツリー
        let skip: Set<String> = ["microsoft", "wine", "temp", "comms", "connecteddevicesplatform",
                                 "packages", "packagecache"]
        for kind in ["Roaming", "Local"] {
            let aAppData = aUser.appendingPathComponent("AppData/\(kind)")
            let bAppData = bUser.appendingPathComponent("AppData/\(kind)")
            guard let children = try? fm.contentsOfDirectory(atPath: aAppData.path) else { continue }
            for child in children where !skip.contains(child.lowercased()) {
                copyMerge(from: aAppData.appendingPathComponent(child),
                          to: bAppData.appendingPathComponent(child))
            }
        }

        // (b) drive_c 直下のゲーム名ディレクトリ（例: yaneurao title/Save）
        let aGameRootDir = aDriveC.appendingPathComponent(gameName)
        if fm.fileExists(atPath: aGameRootDir.path) {
            copyMerge(from: aGameRootDir, to: bDriveC.appendingPathComponent(gameName))
        }
    }

    /// prefix の drive_c/users 配下から実ユーザーディレクトリ（Public でない非 symlink）を返す。
    private func winePrefixUserDir(_ driveC: URL) -> URL? {
        let users = driveC.appendingPathComponent("users")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
        for n in names where n != "Public" {
            let u = users.appendingPathComponent(n)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            // symlink（crossover→Sikarugir 等の互換リンク）は除外
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil
            if exists, isDir.boolValue, !isLink { return u }
        }
        return nil
    }

    /// src を dst へコピー（dst が無ければ親ごと作成）。dst が既存ならスキップ（B を壊さない）。
    private func copyMerge(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if fm.fileExists(atPath: dst.path) { return }   // 既存 B を上書きしない
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: dst)
    }
}
