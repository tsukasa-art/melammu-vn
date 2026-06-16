import Foundation

@Observable
final class InstallViewModel {
    var installerURL: URL?
    var gameFolderURL: URL?
    var gameName: String = ""
    var selectedEngineID: EngineProfile.ID = EngineProfile.unknown.id
    let session = InstallSession()

    // Game-data storage root for full-copy imports. nil = internal default
    // (~/Library/Application Support/Melammu/Games). Persisted so the next
    // import reuses the last choice. Only game data goes here — the prefix
    // always stays internal (symlinks don't survive exFAT).
    static let gameDataRootKey = "melammu.gameDataRoot"
    var gameDataRootPath: String? = UserDefaults.standard.string(forKey: gameDataRootKey) {
        didSet {
            if let path = gameDataRootPath {
                UserDefaults.standard.set(path, forKey: Self.gameDataRootKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.gameDataRootKey)
            }
        }
    }

    var gameDataRootURL: URL? { gameDataRootPath.map { URL(fileURLWithPath: $0) } }

    var storageDisplayName: String {
        let url = gameDataRootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = gameDataRootPath == nil ? "内蔵ストレージ" : url.lastPathComponent
        if let free = try? url.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey]
           ).volumeAvailableCapacityForImportantUsage {
            return "\(name)（空き \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))）"
        }
        return name
    }

    private let service = InstallerService()
    private var gameID: UUID?
    private var gameDir: URL?
    private var gameDataDir: URL?
    private let onInstall: (Game) -> Void

    init(onInstall: @escaping (Game) -> Void) {
        self.onInstall = onInstall
    }

    // MARK: - Setup

    func setInstaller(_ url: URL) {
        installerURL = url
        gameFolderURL = nil
        let parent = url.deletingLastPathComponent().lastPathComponent
        gameName = parent.isEmpty ? url.deletingPathExtension().lastPathComponent : parent
        if let detected = EngineDetector.detect(installerURL: url) {
            selectedEngineID = detected
        }
    }

    func setFolder(_ url: URL) {
        gameFolderURL = url
        installerURL = nil
        gameName = url.lastPathComponent
        if let detected = EngineDetector.detect(folderURL: url) {
            selectedEngineID = detected
        }
    }

    // MARK: - Flow

    func startInstall() async {
        if let folderURL = gameFolderURL {
            await startFolderFlow(folderURL)
        } else if installerURL != nil {
            await startInstallerFlow()
        }
    }

    private func startInstallerFlow() async {
        guard let installerURL else { return }
        let id = UUID()
        gameID = id

        do {
            session.step = .creatingPrefix
            let dir = try service.makeGameDir(id: id)
            gameDir = dir
            let prefix = dir.appendingPathComponent("prefix")

            try await service.createPrefix(at: prefix)

            let profile = EngineProfile.find(selectedEngineID)
            session.step = .installingFonts
            try? service.installFonts(to: prefix)
            await service.registerJapaneseFonts(to: prefix, profile: profile)

            if profile.requiresDXVK {
                session.step = .installingDXVK
                try? await service.installDXVK(to: prefix)
            }
            if profile.requiresLAVFilters {
                try? await service.installLAVFilters(to: prefix)
            }

            session.step = .runningInstaller
            try await service.runInstaller(at: installerURL, prefix: prefix)

            session.step = .detectingExe
            let candidates = service.detectGameExes(in: prefix)
            session.candidateExes = candidates

            if candidates.count == 1 {
                session.selectedExe = candidates[0]
                try await finalize()
            } else {
                session.step = .choosingExe
            }
        } catch {
            if let dir = gameDir { service.rollback(gameDir: dir) }
            session.step = .failed(error.localizedDescription)
        }
    }

    // Full-copy import: the game folder is copied into Melammu-managed storage
    // (minus EngineProfile.excludedGameFiles), mapped to W:\ via dosdevices,
    // and path-memory files (install.inf Current=) are rewritten on the copy.
    // The original stays untouched and is no longer referenced after import.
    private func startFolderFlow(_ folderURL: URL) async {
        let id = UUID()
        gameID = id

        do {
            // Engine detection ran on the original in setFolder() — it must,
            // because the copy lacks excluded marker files (Lib/RenderDX.dll).
            let profile = EngineProfile.find(selectedEngineID)

            // Custom storage root (external drive) must exist and be writable
            // before anything is created
            if let root = gameDataRootURL {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
                      isDir.boolValue,
                      FileManager.default.isWritableFile(atPath: root.path) else {
                    session.step = .failed("保存先が見つからないか書き込めません: \(root.path)")
                    return
                }
            }

            let dir = try service.makeGameDir(id: id)
            gameDir = dir
            let dataDir = try service.makeGameDataDir(id: id, root: gameDataRootURL)
            gameDataDir = dataDir

            session.step = .copyingGameData
            let session = self.session
            try await service.importGameCopy(
                from: folderURL, to: dataDir,
                excluding: profile.excludedGameFiles
            ) { fraction, detail in
                Task { @MainActor in
                    session.copyProgress = fraction
                    session.copyDetail = detail
                }
            }

            session.step = .creatingPrefix
            let prefix = dir.appendingPathComponent("prefix")
            try await service.createPrefix(at: prefix)

            session.step = .installingFonts
            try? service.installFonts(to: prefix)
            await service.registerJapaneseFonts(to: prefix, profile: profile)

            if profile.requiresDXVK {
                session.step = .installingDXVK
                try? await service.installDXVK(to: prefix)
            }

            // Returns the Windows path the game is reachable at (e.g.
            // "W:\gamedata\"); rewrite install.inf's Current= to match so the
            // launcher resolves data/Lib/saves from the copy, not a drive root.
            let winRoot = try service.mapGameDataDrive(prefix: prefix, gameDataDir: dataDir)
            let pathHits = service.rewritePathMemoryFiles(in: dataDir, driveRoot: winRoot)
            session.pathWarnings = pathHits
                .filter { !$0.rewritten }
                .prefix(20)
                .map { "\($0.file.lastPathComponent): \($0.line)" }

            session.step = .detectingExe
            let candidates = service.detectExesInFolder(dataDir)
            session.candidateExes = candidates

            if candidates.count == 1 {
                session.selectedExe = candidates[0]
                try await finalize()
            } else if candidates.isEmpty {
                rollbackCurrent()
                session.step = .failed("実行ファイルが見つかりませんでした")
            } else {
                session.step = .choosingExe
            }
        } catch is CancellationError {
            // User cancelled mid-copy: cancelInstall already rolled back, but
            // files written after that race re-create the dirs — sweep again.
            rollbackCurrent()
        } catch {
            rollbackCurrent()
            session.step = .failed(error.localizedDescription)
        }
    }

    private func rollbackCurrent() {
        if let dir = gameDir { service.rollback(gameDir: dir, gameDataDir: gameDataDir) }
    }

    func confirmExe() async {
        do { try await finalize() } catch {
            session.step = .failed(error.localizedDescription)
        }
    }

    func cancelInstall() {
        service.cancelCurrentOperation()
        rollbackCurrent()
        reset()
    }

    func reset() {
        installerURL = nil
        gameFolderURL = nil
        gameName = ""
        selectedEngineID = EngineProfile.unknown.id
        session.step = .idle
        session.candidateExes = []
        session.selectedExe = nil
        session.copyProgress = 0
        session.copyDetail = ""
        session.pathWarnings = []
        gameID = nil
        gameDir = nil
        gameDataDir = nil
    }

    // MARK: - Private

    private func finalize() async throws {
        guard let gameDir, let selectedExe = session.selectedExe else { return }
        let prefix = gameDir.appendingPathComponent("prefix")

        session.step = .applyingProfile
        let profile = EngineProfile.find(selectedEngineID)
        try await service.applyEngineProfile(profile, to: prefix)

        let engineID: EngineProfile.ID? = selectedEngineID == EngineProfile.unknown.id
            ? nil : selectedEngineID
        let game = service.buildGame(
            id: gameID!,
            name: gameName,
            gameDir: gameDir,
            gameDataDir: gameDataDir,
            selectedExe: selectedExe,
            engineID: engineID
        )
        onInstall(game)
        session.step = .done
    }
}
