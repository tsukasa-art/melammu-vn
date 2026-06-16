import Foundation
import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ViewMode: String, Hashable {
    case grid, list
}

@MainActor
@Observable
final class LibraryViewModel {
    var games: [Game] = []
    var viewMode: ViewMode = .grid
    var lastLaunchedGame: Game?
    var screenshotToken: Int = 0
    var snapToken: Int = 0
    // A→B 移行の進捗（nil=非実行）。UI のオーバーレイ表示用。
    var migrationStatus: String?
    // 連続移行キュー（右クリックで次々積める）。
    private var migrationQueue: [Game] = []
    private var migrationRunning = false
    private var migrationResults: [(name: String, ok: Bool, error: String?)] = []

    private let hud = HUDPanel()
    private var captureService: GameCaptureService?
    private var gameTerminationObserver: (any NSObjectProtocol)?
    private var saveDirWatcher: DispatchSourceFileSystemObject?
    // Debounce state — accessed only on debounceQueue (not MainActor).
    private let debounceQueue = DispatchQueue(label: "melammu.save.debounce")
    private var saveDebounceWork: DispatchWorkItem?
    private var currentGamePID: pid_t?
    private var currentWineProcess: Process?   // new-style direct launch
    private var appTerminationObserver: (any NSObjectProtocol)?
    private var hudHotkeyMonitor: Any?
    private var hiddenWindows: [NSWindow] = []

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        load()
        reconnectToRunningGame()
        cleanupOrphanWinePrefixes()
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Quitting Melammu must take the running game with it — otherwise
            // its wine processes are orphaned. kill(-pgid) only catches the
            // launcher group; wineserver detaches (setsid), so the
            // authoritative kill is prefix-scoped `wineserver -k`, run
            // synchronously here so it completes before the app exits.
            guard let self else { return }
            if let pid = self.currentGamePID { kill(-pid, SIGKILL) }
            let game = self.lastLaunchedGame
            let prefix = game?.prefixURL ?? game.map {
                $0.wrapperURL.appendingPathComponent("Contents/SharedSupport/prefix")
            }
            if let prefix, FileManager.default.fileExists(atPath: prefix.path) {
                InstallerService.killWineServer(prefix: prefix)
            }
        }
    }


    // If a Wine game is already running when Melammu launches/rebuilds,
    // start the capture service. Wine child processes are not registered in
    // NSWorkspace, so we use CGWindowList to find the game window directly.
    private func reconnectToRunningGame() {
        var log = "reconnect called\n"
        defer { try? log.write(toFile: "/tmp/melammu_reconnect.txt", atomically: true, encoding: .utf8) }

        guard let list = CGWindowListCopyWindowInfo(
            CGWindowListOption.optionAll, kCGNullWindowID) as? [[String: Any]]
        else { log += "CGWindowList failed\n"; return }

        // Use the PID saved when the game was last launched directly.
        let savedPID = pid_t(UserDefaults.standard.integer(forKey: "melammu.lastGamePID"))
        guard savedPID > 0, kill(savedPID, 0) == 0 else {
            log += "no saved PID or process dead\n"; return
        }
        log += "reconnecting to saved PID=\(savedPID)\n"

        let foundPID = savedPID
        startCaptureService(pid: foundPID)

        // Match running process to a library game and show HUD.
        let game: Game?
        if let app = NSRunningApplication(processIdentifier: foundPID),
           let bundleURL = app.bundleURL {
            game = games.first { $0.wrapperURL == bundleURL }
                ?? games.first { bundleURL.path.hasPrefix($0.wrapperPath) }
        } else {
            game = games.first
        }
        if let game {
            lastLaunchedGame = game
            hud.show(
                gameName: game.name,
                onScreenshot: { self.takeSnap(for: game) },
                onSaveToGallery: { self.saveScreenshotToGallery(for: game) },
                onForceQuit: { self.forceQuit() },
                onDismiss: { self.hud.hide() }
            )
            registerHUDHotkey()
        }
    }

    // Orphan sweep at launch: a game that froze and was force-killed (or a
    // Melammu crash) leaves wine service processes behind that never exit on
    // their own (measured 100+ before this existed). Targets are derived
    // exclusively from Melammu-managed prefixes — library (B) entries plus
    // library-unreferenced leftovers under Games/ — and killed via
    // prefix-scoped `wineserver -k`, so (A) wrappers and foreign prefixes
    // are structurally unreachable. Best-effort: a prefix whose dir was
    // deleted while processes ran can't be resolved anymore and is left to
    // the user.
    private func cleanupOrphanWinePrefixes() {
        var prefixes: [URL] = []
        var seen = Set<String>()
        for game in games where !game.isLegacy {
            if let p = game.prefixURL, seen.insert(p.path).inserted { prefixes.append(p) }
        }
        let gamesBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu/Games", isDirectory: true)
        if let dirs = try? FileManager.default.contentsOfDirectory(at: gamesBase, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let p = dir.appendingPathComponent("prefix")
                if FileManager.default.fileExists(atPath: p.path), seen.insert(p.path).inserted {
                    prefixes.append(p)
                }
            }
        }
        // Don't touch the game we just reconnected to
        let activePrefix = currentGamePID != nil ? lastLaunchedGame?.prefixURL?.path : nil
        let targets = prefixes.filter {
            $0.path != activePrefix && InstallerService.wineServerSocketExists(prefix: $0)
        }
        guard !targets.isEmpty else { return }
        Task.detached(priority: .utility) {
            for prefix in targets {
                InstallerService.killWineServer(prefix: prefix)
            }
            NSLog("Melammu: cleaned up \(targets.count) orphan wine prefix(es)")
        }
    }

    func scan() {
        let found = GameScanner.scan()
        let existing = Set(games.map { $0.wrapperPath })
        let newGames = found
            .filter { !existing.contains($0.path) }
            .map { Game(name: $0.deletingPathExtension().lastPathComponent, wrapperPath: $0.path) }
        guard !newGames.isEmpty else { return }
        games.append(contentsOf: newGames)
        save()
    }

    /// 更新ボタン: in-place（Downloads 等から直起動の）レガシーエントリを管理フォルダへ
    /// 先行移行し、ライブラリを「入っている＝管理フォルダ済み」へ収束させる。
    /// 旧 `scan()`（~/Applications/Melammu の A ラッパー再走査）は**呼ばない**——
    /// ユーザーが削除した A/Sikarugir を区別なく再登録してしまうため（A は廃止方向）。
    /// 方針: managed folder policy。
    func refreshLibrary() {
        migrateAllInPlace()
    }

    /// in-place（`needsFullCopyMigration`）エントリをすべて先行フルコピー移行する。
    /// プレイ時でなく事前に済ませることで、起動時のコピー待ちを無くす。原本は非破壊。
    func migrateAllInPlace() {
        guard !migrationRunning else { return }
        let targets = games.filter { $0.needsFullCopyMigration }
        guard !targets.isEmpty else { return }
        migrationRunning = true
        let backup = saveURL.deletingLastPathComponent()
            .appendingPathComponent("library.json.bak-inplace-migrate")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: saveURL, to: backup)
        Task { @MainActor in
            var done = 0
            for game in targets {
                done += 1
                let head = "(\(done)/\(targets.count)) "
                migrationStatus = "\(head)「\(game.name)」を管理フォルダへ取り込み中…"
                do {
                    let migrated = try await MigrationService().migrateInPlace(game) { _, detail in
                        Task { @MainActor in self.migrationStatus = "\(head)「\(game.name)」\(detail)" }
                    }
                    if let idx = self.games.firstIndex(where: { $0.id == game.id }) {
                        self.games[idx] = migrated
                    }
                    self.save()
                } catch {
                    NSLog("Melammu: in-place 移行失敗 \(game.name): \(error.localizedDescription)")
                }
            }
            self.migrationRunning = false
            self.migrationStatus = nil
        }
    }

    func add(url: URL) {
        guard url.pathExtension == "app",
              !games.contains(where: { $0.wrapperPath == url.path }) else { return }
        games.append(Game(name: url.deletingPathExtension().lastPathComponent, wrapperPath: url.path))
        save()
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        save()
    }

    var isGameRunning: Bool { currentGamePID != nil }

    /// Managed ((B)) games: removes game data, prefix, and saves from disk.
    /// Legacy ((A)) wrapper games: unregisters only — the .app stays.
    func delete(_ game: Game) {
        // Refuse while this game is running (UI disables the item too)
        guard !(isGameRunning && lastLaunchedGame?.id == game.id) else { return }
        if !game.isLegacy {
            // Stop any lingering wine processes of this prefix before
            // pulling the directory out from under them
            if let prefix = game.prefixURL {
                InstallerService.killWineServer(prefix: prefix)
            }
            if let dir = game.gameDir {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir))
                // External-volume layout <root>/Melammu/Games/<id>/gamedata —
                // remove the per-game <id> dir
                if let dataDir = game.gameDataURL, !dataDir.path.hasPrefix(dir + "/") {
                    try? FileManager.default.removeItem(at: dataDir.deletingLastPathComponent())
                }
            }
        }
        if let cover = game.customCoverPath { try? FileManager.default.removeItem(atPath: cover) }
        if let banner = game.customBannerPath { try? FileManager.default.removeItem(atPath: banner) }
        games.removeAll { $0.id == game.id }
        save()
    }

    func install(_ game: Game) {
        guard !games.contains(where: { $0.id == game.id }) else { return }
        games.append(game)
        save()
    }

    func launch(_ game: Game) {
        // Never stack two games: fully tear down any currently running one
        // first. Without this, launching B while A is still up (or relaunching
        // after a hang) leaves a second set of wine processes orphaned.
        if currentGamePID != nil { terminateRunningGame() }
        lastLaunchedGame = game
        if game.isLegacy {
            launchLegacy(game)
        } else if game.needsFullCopyMigration {
            migrateInPlaceThenLaunch(game)
        } else {
            launchDirect(game)
        }
    }

    /// in-place（Downloads 等の絶対 exePath）エントリを、起動前に管理フォルダへ
    /// フルコピー移行してから起動する。原本は読むだけ（非破壊）。移行後 library を
    /// 更新し、以後は管理フォルダから起動する。
    /// 方針: managed folder policy。
    private func migrateInPlaceThenLaunch(_ game: Game) {
        guard !migrationRunning else { return }
        migrationRunning = true
        // 安全策: library.json をバックアップ
        let backup = saveURL.deletingLastPathComponent()
            .appendingPathComponent("library.json.bak-inplace-migrate")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: saveURL, to: backup)
        Task { @MainActor in
            migrationStatus = "「\(game.name)」を管理フォルダへ取り込み中…"
            do {
                let migrated = try await MigrationService().migrateInPlace(game) { _, detail in
                    Task { @MainActor in self.migrationStatus = "「\(game.name)」\(detail)" }
                }
                if let idx = self.games.firstIndex(where: { $0.id == game.id }) {
                    self.games[idx] = migrated
                }
                self.save()
                self.migrationRunning = false
                self.migrationStatus = nil
                self.lastLaunchedGame = migrated
                self.launchDirect(migrated)
            } catch {
                self.migrationRunning = false
                self.migrationStatus = nil
                let a = NSAlert()
                a.messageText = "管理フォルダへの取り込みに失敗しました"
                a.informativeText = error.localizedDescription
                a.alertStyle = .warning
                a.runModal()
            }
        }
    }

    private func registerHUDHotkey() {
        hudHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection([.command, .shift]) == [.command, .shift] else { return }
            let key = event.charactersIgnoringModifiers?.lowercased()
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch key {
                case "h":
                    // Toggle the HUD (in case it's hidden behind the game).
                    if self.hud.isVisible { self.hud.hide() } else { self.hud.orderFront() }
                case "k":
                    // Force-quit the game even when it has frozen and grabbed
                    // the screen (e.g. fullscreen hang). This is a GLOBAL
                    // monitor, so it fires while the game — not Melammu — is
                    // frontmost. wineserver -k signals the (responsive) wine
                    // server, so it works regardless of the game being hung.
                    self.forceQuit()
                default:
                    break
                }
            }
        }
    }

    private func unregisterHUDHotkey() {
        if let m = hudHotkeyMonitor { NSEvent.removeMonitor(m); hudHotkeyMonitor = nil }
    }

    private func hideMainWindow() {
        hiddenWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible && !$0.isMiniaturized }
        hiddenWindows.forEach { $0.miniaturize(nil) }
    }

    private func showMainWindow() {
        hiddenWindows.forEach { $0.deminiaturize(nil) }
        hiddenWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }

    // Resolves the WINEPREFIX of the running game for both pipelines:
    // (B) direct-launch games carry it on the model; (A) legacy wrappers keep
    // it inside the .app bundle. The bundled wineserver can -k either prefix
    // (the kill target is resolved from the prefix's server socket, not from
    // which wineserver binary issues it).
    private func runningGamePrefix() -> URL? {
        guard let game = lastLaunchedGame else { return nil }
        if let p = game.prefixURL { return p }
        let wrapped = game.wrapperURL.appendingPathComponent("Contents/SharedSupport/prefix")
        return FileManager.default.fileExists(atPath: wrapped.path) ? wrapped : nil
    }

    /// Fully tears down the running game and ALL of its wine processes, then
    /// clears tracking state. Safe to call when nothing is running.
    ///
    /// `wineserver -k` is authoritative: it reaches every process of the prefix
    /// (services.exe / winedevice / plugplay / the game) via the prefix's
    /// server socket, independent of Unix process groups. kill(-pgid) alone is
    /// not enough — wineserver calls setsid() and leaves the launch group, so
    /// the services it manages would otherwise be orphaned. kill(-pgid) stays
    /// as a fast backstop for the launcher process itself. State is cleared
    /// first so the launch terminationHandler's delayed sweep becomes a no-op.
    private func terminateRunningGame() {
        let prefix = runningGamePrefix()
        let pgid = currentGamePID

        captureService?.stop()
        captureService = nil
        currentGamePID = nil
        currentWineProcess = nil
        saveDirWatcher?.cancel()
        saveDirWatcher = nil
        unregisterHUDHotkey()
        hud.close()
        UserDefaults.standard.removeObject(forKey: "melammu.lastGamePID")

        if let pgid { kill(-pgid, SIGKILL) }
        if let prefix { InstallerService.killWineServer(prefix: prefix) }
    }

    // Force-quit the running game. Reachable from the HUD button, the
    // Cmd+Shift+K global hotkey, and the app menu. Internal so the menu
    // command can call it.
    func forceQuit() {
        guard currentGamePID != nil else { return }
        terminateRunningGame()
        showMainWindow()
    }

    private func launchLegacy(_ game: Game) {
        hideMainWindow()
        hud.show(
            gameName: game.name,
            onScreenshot: { self.takeSnap(for: game) },
            onSaveToGallery: { self.saveScreenshotToGallery(for: game) },
            onForceQuit: { self.forceQuit() },
            onDismiss: { self.hud.hide() }
        )
        registerHUDHotkey()
        NSWorkspace.shared.openApplication(
            at: game.wrapperURL,
            configuration: .init()
        ) { [weak self] app, _ in
            guard let self, let app else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                app.activate()
                self.startCaptureService(pid: pid)
            }
        }
    }

    private func launchDirect(_ game: Game) {
        let useWine64 = game.engineProfile.requiresWine64
        // engine/ゲーム別ランタイム: ゲーム個別上書き > エンジン既定。現状は全タイトル
        // 既定 B（Sikarugir(A) ランタイム同梱は廃止＝一本化）。
        let runtimeSubdir = game.resolvedWineRuntimeSubdir
        guard let wine = InstallerService.findWineURL(wine64: useWine64, runtimeSubdir: runtimeSubdir) else { return }
        guard let prefix = game.prefixURL, let exeURL = game.gameExeURL else { return }
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            // Game data may live on an external volume that isn't mounted
            let alert = NSAlert()
            alert.messageText = "ゲームデータが見つかりません"
            alert.informativeText = "\(exeURL.path)\n\n外部ドライブに保存した場合は、接続されているか確認してください。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Gatekeeper 対策: ネット DL ゲームの検疫属性 (com.apple.quarantine) を除去。
        // 残っていると wine の exec マップ時に「マルウェア検証不可」ダイアログで起動できない。
        InstallerService.stripQuarantine(at: exeURL.deletingLastPathComponent())

        hideMainWindow()
        hud.show(
            gameName: game.name,
            onScreenshot: { self.takeSnap(for: game) },
            onSaveToGallery: { self.saveScreenshotToGallery(for: game) },
            onForceQuit: { self.forceQuit() },
            onDismiss: { self.hud.hide() }
        )
        registerHUDHotkey()
        let process = Process()
        process.executableURL = wine
        process.arguments = [exeURL.path]
        process.currentDirectoryURL = exeURL.deletingLastPathComponent()
        var env = InstallerService.makeWineEnv(prefix: prefix, wine64: useWine64, runtimeSubdir: runtimeSubdir)
        let displayMode = game.resolvedDisplayMode
        if game.engineProfile.requiresDXVK {
            // prefix に置いた native DXVK を確実に優先させる。reg の DllOverrides は
            // 取り込み未完了 prefix で persist しないことがあるため、起動 env で明示する
            // （env の WINEDLLOVERRIDES が最優先）。dxgi は DXVK を同梱しないので builtin。
            // エンジン別の混在指定があれば優先（例: KiriKiri Z は d3d9 を wined3d で
            // 軽量化しつつ d3d11 のみ DXVK → "d3d9=b;d3d11=n,b;dxgi=b"）。
            env["WINEDLLOVERRIDES"] = game.engineProfile.wineDllOverrides ?? "d3d9,d3d11=n,b;dxgi=b"
            // 既存 prefix の自己修復: 既に入っている DXVK DLL に wine builtin 署名が
            // 残っていると native ロードが拒否され wined3d に落ちる。冪等に署名を除去する
            // （再インストール不要で旧 prefix も復活）。
            let sys32 = prefix.appendingPathComponent("drive_c/windows/system32")
            let sysWow = prefix.appendingPathComponent("drive_c/windows/syswow64")
            for dll in ["d3d9.dll", "d3d11.dll", "dxgi.dll"] {
                InstallerService.stripWineBuiltinMarker(at: sys32.appendingPathComponent(dll))
                InstallerService.stripWineBuiltinMarker(at: sysWow.appendingPathComponent(dll))
            }
            // D3D11/DXVK 系（iarsys/artemis 等）は自前のウィンドウを中央寄せする際に
            // wine の非Retina座標を使うため、座標がズレてディスプレイ右外に
            // 飛び「起動したのに見えない」状態になる。表示モードで対処を切り替える:
            //  - .crisp : RetinaMode=y。座標系が合い中央寄せが画面内に収まる＋高精細描画
            //            （固定720pなので等倍≒640pt と小さめ。権限不要）。
            //  - .large : RetinaMode=n（既定の大きいウィンドウ）のまま起動し、起動後に
            //            アクセシビリティ経由でウィンドウを画面内へ移動（WindowMover）。
            InstallerService.setRetinaMode(displayMode == .crisp, prefix: prefix)
        }
        // CMVS のみ: 同梱 wine の d3d9 セーブサムネ捕捉を有効化（既定は OFF＝stock 動作）。
        // 他エンジンで有効化すると毎フレーム back-buffer 捕捉が描画を壊す（KiriKiri Z 白画面の主因）。
        if game.engineProfile.enablesCmvsCapture {
            env["MELAMMU_CMVS_THUMBS"] = "1"
        }
        process.environment = env
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stale-handler guard: if a newer game has taken over (e.g. we
                // killed this one via terminateRunningGame to launch another),
                // this handler must NOT touch the current game's HUD/state.
                // The replacement already swept this prefix synchronously.
                guard self.currentWineProcess === proc else { return }
                self.captureService?.stop()
                self.captureService = nil
                self.currentGamePID = nil
                self.currentWineProcess = nil
                self.saveDirWatcher?.cancel()
                self.saveDirWatcher = nil
                self.unregisterHUDHotkey()
                self.hud.close()
                UserDefaults.standard.removeObject(forKey: "melammu.lastGamePID")
                self.showMainWindow()
                // Ghost-process sweep: when the game exe dies (crash or quit),
                // wine service processes (services.exe/winedevice/plugplay)
                // linger and never exit on their own. Give wine a moment to
                // settle, confirm no relaunch happened, then kill this
                // prefix's server — and only this prefix's.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.currentGamePID == nil else { return }
                    InstallerService.killWineServer(prefix: prefix)
                }
            }
        }

        do {
            try process.run()
        } catch {
            hud.close()
            showMainWindow()
            return
        }

        let pid = process.processIdentifier
        // Create a dedicated process group (PGID = pid) so kill(-pid, SIGKILL)
        // takes out wineserver, winedevice, and the game exe in one shot.
        setpgid(pid, pid)
        currentGamePID = pid
        currentWineProcess = process
        // Persist PGID (= pid) so a kill tool can reach it even after a crash.
        UserDefaults.standard.set(Int(pid), forKey: "melammu.lastGamePID")
        startCaptureService(pid: pid)
        startSaveDirWatcher(forNewGame: game, prefix: prefix)
    }

    private func startSaveDirWatcher(forNewGame game: Game, prefix: URL) {
        guard let exeDir = game.gameExeURL?.deletingLastPathComponent() else { return }
        // Try common save directory names relative to the exe
        let candidates = ["save", "Save", "savedata", "SaveData"]
            .map { exeDir.appendingPathComponent($0) }
        guard let saveDir = candidates.first(where: { opendir($0.path) != nil }) else { return }
        // Cache it so reconnectToRunningGame can find it next session
        try? saveDir.path.write(toFile: "/tmp/melammu_savedir_cache.txt",
                                atomically: true, encoding: .utf8)
        startWatcherAt(saveDir: saveDir)
    }

    func setCover(for game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .gif]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let dest = coverDir.appendingPathComponent(game.id.uuidString + "." + src.pathExtension)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)

        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx].customCoverPath = dest.path
            save()
        }
    }

    /// カバー未設定ゲームのプレースホルダー色をパレット順に1つ進める（永続化）。
    func cyclePlaceholderColor(for game: Game) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        let current = games[idx].placeholderColorIndex
            ?? PlaceholderPalette.defaultIndex(for: games[idx].name)
        games[idx].placeholderColorIndex = (current + 1) % PlaceholderPalette.hues.count
        save()
    }

    /// A（Sikarugir ラッパー）ゲームを B（ネイティブ取り込み）移行キューへ積む。
    /// 右クリックで次々積める（順次実行）。A の .app は読むだけ（非破壊）。完了後も A は残る。
    func migrateToNative(_ legacy: Game) {
        guard legacy.isLegacy, !legacy.wrapperPath.isEmpty else { return }
        guard !migrationQueue.contains(where: { $0.id == legacy.id }) else { return }  // 二重投入防止
        migrationQueue.append(legacy)
        if !migrationRunning { startMigrationQueue() }
    }

    private func startMigrationQueue() {
        migrationRunning = true
        migrationResults = []
        // 安全策: バッチ開始時に library.json をバックアップ
        let backup = saveURL.deletingLastPathComponent()
            .appendingPathComponent("library.json.bak-migrate")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: saveURL, to: backup)

        Task { @MainActor in
            while !migrationQueue.isEmpty {
                let legacy = migrationQueue.removeFirst()
                let suffix = { self.migrationQueue.isEmpty ? "" : "（残り\(self.migrationQueue.count)件）" }
                migrationStatus = "「\(legacy.name)」を移行中…\(suffix())"
                do {
                    let migrated = try await MigrationService()
                        .migrate(wrapperApp: URL(fileURLWithPath: legacy.wrapperPath)) { _, detail in
                            Task { @MainActor in
                                self.migrationStatus = "「\(legacy.name)」\(detail)\(suffix())"
                            }
                        }
                    self.games.append(migrated)
                    self.save()
                    migrationResults.append((legacy.name, true, nil))
                } catch {
                    migrationResults.append((legacy.name, false, error.localizedDescription))
                }
            }
            migrationRunning = false
            migrationStatus = nil

            let ok = migrationResults.filter { $0.ok }.map { $0.name }
            let ng = migrationResults.filter { !$0.ok }
            let a = NSAlert()
            a.alertStyle = ng.isEmpty ? .informational : .warning
            a.messageText = "ネイティブ移行が完了しました（成功 \(ok.count) / 失敗 \(ng.count)）"
            var info = ""
            if !ok.isEmpty { info += "成功: " + ok.joined(separator: "、") + "\n" }
            if !ng.isEmpty { info += "失敗: " + ng.map { "\($0.name)（\($0.error ?? "")）" }.joined(separator: "、") + "\n" }
            info += "元の Sikarugir 版はそのまま残しています。"
            a.informativeText = info
            a.runModal()
        }
    }

    /// DXVK ゲームのウィンドウ表示モードを切り替える（次回起動から反映）。
    func setDisplayMode(_ mode: Game.DisplayMode, for game: Game) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx].displayMode = mode.rawValue
        save()
        // prefix の RetinaMode を即同期しておく（次回起動を待たずに整合）。
        // large 時の画面外問題は同梱 wine の Mac ドライバ側クランプ修正で吸収するので
        // ここでの追加権限・後処理は不要。
        if let prefix = games[idx].prefixURL {
            InstallerService.setRetinaMode(mode == .crisp, prefix: prefix)
        }
    }

    static let latestSnapPNG = "/tmp/melammu_latest_snap.png"

    func takeSnap(for game: Game) {
        let wasHUDVisible = hud.isVisible
        hud.hide()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(150))

            if let img = await self.captureDisplaySCK() {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.writeSnapBGRA(img)
                    let rep = NSBitmapImageRep(cgImage: img)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: Self.latestSnapPNG))
                    }
                    if wasHUDVisible { self.hud.orderFront() }
                    self.snapToken += 1
                }
            } else {
                await MainActor.run { [weak self] in if wasHUDVisible { self?.hud.orderFront() } }
            }
        }
    }

    // SCK display-level capture: captures the GPU compositor output for the entire display,
    // which includes Metal/CAMetalLayer windows that window-level capture sees through.
    private func captureDisplaySCK() async -> CGImage? {
        var log = ""
        defer { try? log.write(toFile: "/tmp/melammu_sck_debug.txt", atomically: true, encoding: .utf8) }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log = "SCShareableContent failed: \(error)"; return nil
        }

        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let gameWin = content.windows
            .filter { win in
                guard let app = win.owningApplication else { return false }
                guard app.processID != selfPID else { return false }
                guard win.frame.width >= 400, win.frame.height >= 300 else { return false }
                return app.applicationName.lowercased().contains("wine")
            }
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })

        log = "gameWin: \(String(describing: gameWin?.frame))\n"

        guard let display = content.displays.first(where: { d in
            gameWin.map { d.frame.intersects($0.frame) } ?? true
        }) ?? content.displays.first else {
            log += "no display"; return nil
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        // Render only the game app's pixels — menu bar / system overlays are excluded.
        let filter: SCContentFilter
        if let gameApp = gameWin?.owningApplication {
            filter = SCContentFilter(display: display, including: [gameApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width  = Int(display.frame.width  * scale)
        config.height = Int(display.frame.height * scale)

        do {
            let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            log += "display capture OK \(full.width)x\(full.height)\n"

            guard let win = gameWin else { return full }

            // Convert SCK screen-coordinate window frame → image pixel rect.
            let sx = CGFloat(full.width)  / display.frame.width
            let sy = CGFloat(full.height) / display.frame.height
            let x  = (win.frame.minX - display.frame.minX) * sx
            let y  = (win.frame.minY - display.frame.minY) * sy
            let w  = win.frame.width  * sx
            let h  = win.frame.height * sy

            // Crop macOS title bar from top.
            let titlePx = h - w * 9 / 16
            let contentY = (titlePx > 5 && titlePx < 200) ? y + titlePx : y
            let contentH = (titlePx > 5 && titlePx < 200) ? h - titlePx  : h
            let crop = CGRect(x: x, y: contentY, width: w, height: contentH)
            log += "crop: \(crop)\n"
            return full.cropping(to: crop) ?? full
        } catch {
            log += "display capture failed: \(error)"; return nil
        }
    }

    private func writeSnapBGRA(_ img: CGImage) {
        let w = img.width, h = img.height, stride = w * 4
        var pixels = [UInt8](repeating: 0, count: h * stride)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: stride, space: cs,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        // Flip Y so snap.bgra row 0 = visual top (Y-correct, D3D9 convention).
        // CGContext is Y-up by default; without this transform row 0 = visual bottom.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        var data = Data()
        var w32 = UInt32(w), h32 = UInt32(h), s32 = UInt32(stride)
        withUnsafeBytes(of: &w32) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h32) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &s32) { data.append(contentsOf: $0) }
        data.append(contentsOf: pixels)
        try? data.write(to: URL(fileURLWithPath: GameCaptureService.snapPath))
    }

    // Legacy: read Wine-written snap.bgra (kept for reference).
    private func loadSnapBGRAasCGImage() -> CGImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: GameCaptureService.snapPath)),
              data.count >= 12 else { return nil }
        let w      = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        let h      = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        let stride = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
        guard w > 0, h > 0, stride >= w * 4, data.count >= 12 + h * stride else { return nil }
        let pixels = data.subdata(in: 12..<(12 + h * stride))
        guard let provider = CGDataProvider(data: pixels as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                               | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    func saveScreenshotToGallery(for game: Game) {
        let src = URL(fileURLWithPath: Self.latestSnapPNG)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dir = screenshotsDir(for: game)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let dest = dir.appendingPathComponent(formatter.string(from: Date()) + ".png")
        try? FileManager.default.copyItem(at: src, to: dest)
        screenshotToken += 1
    }

    func screenshots(for game: Game) -> [URL] {
        let dir = screenshotsDir(for: game)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func revealScreenshots(for game: Game) {
        let dir = screenshotsDir(for: game)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// ゲームが保存されているフォルダ。(B) ネイティブは取り込んだゲームデータ（無ければ Games/<id>）、
    /// (A) レガシーは .app ラッパー。
    func gameStorageURL(_ game: Game) -> URL? {
        if game.isLegacy {
            return game.wrapperPath.isEmpty ? nil : game.wrapperURL
        }
        return game.gameDataURL ?? game.gameDir.map { URL(fileURLWithPath: $0) }
    }

    /// 保存フォルダを Finder で表示（親ウインドウ内で選択状態にする）。
    func revealGameFolder(_ game: Game) {
        guard let url = gameStorageURL(game),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var coverDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu/Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var bannerDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu/Banners", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func setBanner(for game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .gif]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let dest = bannerDir.appendingPathComponent(game.id.uuidString + "." + src.pathExtension)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)

        if let idx = games.firstIndex(where: { $0.id == game.id }) {
            games[idx].customBannerPath = dest.path
            save()
        }
    }

    private func screenshotsDir(for game: Game) -> URL {
        let safe = game.name.components(separatedBy: .init(charactersIn: "/:")).joined(separator: "-")
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu/\(safe)", isDirectory: true)
    }

    private func startCaptureService(pid appPID: pid_t) {
        captureService?.stop()
        currentGamePID = appPID
        let svc = GameCaptureService(pid: appPID)
        captureService = svc
        svc.start()

        if let prev = gameTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(prev)
        }
        gameTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let terminatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            guard terminatedPID == appPID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureService?.stop()
                self.captureService = nil
                self.currentGamePID = nil
                self.saveDirWatcher?.cancel()
                self.saveDirWatcher = nil
                if let obs = self.gameTerminationObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(obs)
                    self.gameTerminationObserver = nil
                }
                self.showMainWindow()
            }
        }

        // Watch the game's save directory; write per-slot snap + page_base when a slot is saved.
        startSaveDirWatcher(for: appPID)
    }

    private func startSaveDirWatcher(for pid: pid_t) {
        saveDirWatcher?.cancel()
        saveDirWatcher = nil

        // Try to resolve the save dir via NSRunningApplication first,
        // then fall back to searching the known game library (needed when Wine
        // child processes aren't registered as macOS apps, e.g. after reconnect).
        var saveDir: URL?
        var dbg = "startSaveDirWatcher pid=\(pid)\n"

        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleURL = app.bundleURL {
            let candidate = bundleURL
                .appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Program Files")
                .appendingPathComponent(bundleURL.deletingPathExtension().lastPathComponent)
                .appendingPathComponent("save")
            dbg += "nsra candidate: \(candidate.path)\n"
            if let d = opendir(candidate.path) { closedir(d); saveDir = candidate; dbg += "nsra OK\n" }
            else { dbg += "nsra opendir failed\n" }
        } else {
            dbg += "NSRunningApplication failed for pid \(pid)\n"
        }

        // Fallback 1: cached path from last successful launch.
        let saveDirCachePath = "/tmp/melammu_savedir_cache.txt"
        if saveDir == nil,
           let cached = try? String(contentsOfFile: saveDirCachePath, encoding: .utf8),
           let d = opendir(cached) { closedir(d); saveDir = URL(fileURLWithPath: cached); dbg += "cache hit\n" }

        // Fallback 2: search known game library.
        if saveDir == nil {
            dbg += "trying games fallback (\(games.count) games)\n"
            for game in games {
                let candidate = game.wrapperURL
                    .appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Program Files")
                    .appendingPathComponent(game.wrapperURL.deletingPathExtension().lastPathComponent)
                    .appendingPathComponent("save")
                dbg += "  \(candidate.path)\n"
                if let fd = opendir(candidate.path) { closedir(fd); saveDir = candidate; break }
            }
        }

        guard let saveDir else {
            dbg += "no save dir found\n"
            try? dbg.write(toFile: "/tmp/melammu_watcher_dbg.txt", atomically: true, encoding: .utf8)
            return
        }
        try? saveDir.path.write(toFile: saveDirCachePath, atomically: true, encoding: .utf8)
        dbg += "watching: \(saveDir.path)\n"
        try? dbg.write(toFile: "/tmp/melammu_watcher_dbg.txt", atomically: true, encoding: .utf8)
        startWatcherAt(saveDir: saveDir)
    }

    private func startWatcherAt(saveDir: URL) {
        saveDirWatcher?.cancel()
        saveDirWatcher = nil

        guard let fd = opendir(saveDir.path) else { return }
        closedir(fd)

        let dirFD = open(saveDir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceQueue.async { [weak self] in
                guard let self else { return }
                self.saveDebounceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.handleSaveDirectoryChange(saveDir: saveDir)
                }
                self.saveDebounceWork = work
                self.debounceQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        src.setCancelHandler { close(dirFD) }
        src.resume()
        saveDirWatcher = src
    }

    private func handleSaveDirectoryChange(saveDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-5)
        var newestNs: Int64 = 0
        var newestURL: URL?

        for fileURL in files {
            guard fileURL.pathExtension == "dat",
                  fileURL.lastPathComponent.hasPrefix("save"),
                  let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  mtime > cutoff else { continue }

            var sb = stat()
            if lstat(fileURL.path, &sb) == 0 {
                let ns = Int64(sb.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(sb.st_mtimespec.tv_nsec)
                if ns > newestNs {
                    newestNs = ns
                    newestURL = fileURL
                }
            } else if newestURL == nil {
                newestURL = fileURL
            }
        }

        guard let fileURL = newestURL else { return }

        // Retired: CMVS now produces correct thumbnails natively via
        // wine-wukiyo's last-presented back-buffer serve (Windows windowed-present
        // copy semantics).  Post-save .dat patching picked the newest-mtime file,
        // which corrupted companion files (savedel/save8xx/save999), stamped stale
        // frozen snaps onto unrelated slots, and broke overwrite saves.
        _ = fileURL
    }

    // LZSS all-literal encoder (same ring-buffer variant as FUN_140068210).
    // Emits flag byte with n bits set followed by n literal bytes; ~12 % overhead but game accepts it.
    private nonisolated static func lzssCompressAllLiteral(_ src: Data) -> Data {
        var out = Data()
        out.reserveCapacity(src.count + src.count / 8 + 2)
        var i = src.startIndex
        while i < src.endIndex {
            let n = min(8, src.distance(from: i, to: src.endIndex))
            let end = src.index(i, offsetBy: n)
            out.append(UInt8((1 << n) - 1))
            out.append(contentsOf: src[i..<end])
            i = end
        }
        return out
    }

    private nonisolated static func patchDatFileThumbnail(at fileURL: URL, snapData: Data?) {
        var log = "patch: \(fileURL.lastPathComponent)\n"
        defer { try? log.write(toFile: "/tmp/melammu_patch_dbg.txt", atomically: true, encoding: .utf8) }

        guard let dat = try? Data(contentsOf: fileURL) else { log += "read failed\n"; return }
        log += "fileSize=\(dat.count)\n"

        // Validate CSV2 magic
        guard dat.count >= 0x260,
              dat[0] == 0x43, dat[1] == 0x53, dat[2] == 0x56, dat[3] == 0x32
        else { log += "not CSV2\n"; return }

        let cs0 = Int(dat.withUnsafeBytes { $0.load(fromByteOffset: 0x230, as: UInt32.self) })
        let cs1 = Int(dat.withUnsafeBytes { $0.load(fromByteOffset: 0x234, as: UInt32.self) })
        let cs2 = Int(dat.withUnsafeBytes { $0.load(fromByteOffset: 0x238, as: UInt32.self) })
        let blobBase = 0x258
        let blob0End = blobBase + cs0
        let blob1End = blob0End + cs1
        let blob2End = blob1End + cs2
        guard blob2End + 2 <= dat.count else {
            log += "layout OOB cs0=\(cs0) cs1=\(cs1) cs2=\(cs2)\n"; return
        }
        log += "cs0=\(cs0) cs1=\(cs1) cs2=\(cs2)\n"

        // Decode snap BGRA header
        guard let raw = snapData, raw.count >= 12 else { log += "no snap\n"; return }
        let sw = Int(raw.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) })
        let sh = Int(raw.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
        let ss = Int(raw.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
        guard sw > 0, sh > 0, ss >= sw * 4, raw.count >= 12 + sh * ss else {
            log += "snap bad sw=\(sw) sh=\(sh) ss=\(ss)\n"; return
        }

        let pixSlice = raw.subdata(in: 12..<(12 + sh * ss))
        guard let provider = CGDataProvider(data: pixSlice as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srcImg = CGImage(
                  width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: ss, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue:
                      CGBitmapInfo.byteOrder32Little.rawValue |
                      CGImageAlphaInfo.premultipliedFirst.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { log += "srcImg failed\n"; return }

        // Scale to 192×108 thumbnail
        let tw = 192, th = 108
        var px = [UInt8](repeating: 0, count: tw * th * 4)
        guard let sctx = CGContext(
            data: &px, width: tw, height: th,
            bitsPerComponent: 8, bytesPerRow: tw * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                        CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { log += "ctx failed\n"; return }
        sctx.draw(srcImg, in: CGRect(x: 0, y: 0, width: tw, height: th))

        // Build 192×108 24-bpp bottom-up BMP.
        // 192*3 = 576 bytes/row is divisible by 4, so no row padding needed.
        // CGContext writes row 0 as visual top here; BMP row 0 is visual bottom.
        let bmpPixBytes  = tw * th * 3        // 62208
        let bmpTotalBytes = 54 + bmpPixBytes  // 62262
        var bmp = Data(repeating: 0, count: bmpTotalBytes)
        bmp[0] = 0x42; bmp[1] = 0x4D
        bmp.withUnsafeMutableBytes { p in
            p.storeBytes(of: UInt32(bmpTotalBytes).littleEndian, toByteOffset: 2,  as: UInt32.self)
            p.storeBytes(of: UInt32(54).littleEndian,            toByteOffset: 10, as: UInt32.self)
            p.storeBytes(of: UInt32(40).littleEndian,            toByteOffset: 14, as: UInt32.self)
            p.storeBytes(of: UInt32(tw).littleEndian,            toByteOffset: 18, as: UInt32.self)
            p.storeBytes(of: UInt32(th).littleEndian,            toByteOffset: 22, as: UInt32.self)
            p.storeBytes(of: UInt16(1).littleEndian,             toByteOffset: 26, as: UInt16.self)
            p.storeBytes(of: UInt16(24).littleEndian,            toByteOffset: 28, as: UInt16.self)
        }

        var bmpOff = 54
        for bmpRow in 0..<th {
            let row = th - 1 - bmpRow
            let srcBase = row * tw * 4
            for col in 0..<tw {
                let s = srcBase + col * 4
                bmp[bmpOff]     = px[s]
                bmp[bmpOff + 1] = px[s + 1]
                bmp[bmpOff + 2] = px[s + 2]
                bmpOff += 3
            }
        }
        log += "bmp=\(bmp.count)\n"

        let newBlob1 = lzssCompressAllLiteral(bmp)
        log += "lzss=\(newBlob1.count) was=\(cs1)\n"

        // Patch header: total body size, blob-1 comp size, blob-1 raw size
        var hdr = Data(dat[0..<blobBase])
        hdr.withUnsafeMutableBytes { p in
            p.storeBytes(of: UInt32(cs0 + newBlob1.count + cs2).littleEndian, toByteOffset: 0x21C, as: UInt32.self)
            p.storeBytes(of: UInt32(newBlob1.count).littleEndian,              toByteOffset: 0x234, as: UInt32.self)
            p.storeBytes(of: UInt32(bmpTotalBytes).littleEndian,               toByteOffset: 0x248, as: UInt32.self)
        }

        // Reassemble: header + blob0 (unchanged) + newBlob1 + blob2 (unchanged) + checksum (unchanged)
        var result = hdr
        result.append(contentsOf: dat[blobBase..<blob0End])
        result.append(newBlob1)
        result.append(contentsOf: dat[blob1End..<blob2End])
        result.append(contentsOf: dat[blob2End..<(blob2End + 2)])

        do {
            try result.write(to: fileURL)
            log += "write OK size=\(result.count)\n"
        } catch {
            log += "write error: \(error)\n"
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: saveURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([Game].self, from: data) else { return }
        games = decoded
    }
}
