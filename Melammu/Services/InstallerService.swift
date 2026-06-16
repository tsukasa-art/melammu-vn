import Foundation
import CoreText

enum InstallerError: LocalizedError {
    case wineNotFound
    case commandFailed(Int32)
    case insufficientSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .wineNotFound:
            return "Wine バイナリが見つかりません。wine fork をビルドして Melammu.app にバンドルしてください。"
        case .commandFailed(let code):
            return "コマンドが失敗しました (exit \(code))"
        case .insufficientSpace(let needed, let available):
            let fmt = ByteCountFormatter()
            return "保存先の空き容量が不足しています（必要: \(fmt.string(fromByteCount: needed)) / 空き: \(fmt.string(fromByteCount: available))）"
        }
    }
}

/// A line in a copied game file that records an absolute Windows path.
/// install.inf `Current=` is rewritten automatically; anything else is only
/// reported — rewriting unknown formats risks breaking the copy, a visible
/// warning is safer.
struct PathMemoryHit {
    let file: URL
    let line: String
    let rewritten: Bool
}

final class InstallerService {
    private var currentProcess: Process?

    func cancelCurrentOperation() {
        importCancelFlag.isCancelled = true
        currentProcess?.terminate()
        currentProcess = nil
    }
    private let gamesBaseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Melammu/Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: - Directory

    func makeGameDir(id: UUID) throws -> URL {
        let dir = gamesBaseURL.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Game data lives outside the prefix and is connected via a dosdevices
    // drive letter (W:). The prefix (which contains symlinks) always stays on
    // the local APFS volume; game data may live on an external drive whose
    // filesystem (e.g. exFAT) cannot hold symlinks.
    func makeGameDataDir(id: UUID, root: URL? = nil) throws -> URL {
        let dir: URL
        if let root {
            dir = root.appendingPathComponent("Melammu/Games/\(id.uuidString)/gamedata", isDirectory: true)
        } else {
            dir = gamesBaseURL.appendingPathComponent("\(id.uuidString)/gamedata", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Game data import (full copy)

    private final class CancelFlag: @unchecked Sendable {
        nonisolated(unsafe) var isCancelled = false
    }
    private let importCancelFlag = CancelFlag()

    /// Copies the entire game folder into `gameDataDir`. Originals are opened
    /// read-only and never modified. Saves written into the original game dir
    /// (Save/, env.ini — the norm for symlink-era titles) ride along
    /// automatically; diagnostic leftovers (*.bak-*, ._*) are skipped.
    func importGameCopy(from source: URL, to gameDataDir: URL,
                        excluding excludedRelativePaths: [String],
                        progress: @escaping @Sendable (Double, String) -> Void) async throws {
        importCancelFlag.isCancelled = false
        let cancelFlag = importCancelFlag
        let excluded = Set(excludedRelativePaths.map { $0.lowercased() })
        try await Task.detached(priority: .userInitiated) {
            var files: [(rel: String, src: URL, size: Int64)] = []
            var visited = Set<String>()
            try Self.collectGameFiles(dir: source, rel: "", excluded: excluded,
                                      into: &files, visited: &visited)
            let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)

            // Free-space check: payload + 512 MB margin (prefix lives on its
            // own volume and is checked implicitly by wineboot failing).
            let needed = totalBytes + 512 * 1024 * 1024
            if let capacity = try? gameDataDir.resourceValues(
                   forKeys: [.volumeAvailableCapacityForImportantUsageKey]
               ).volumeAvailableCapacityForImportantUsage,
               capacity < needed {
                throw InstallerError.insufficientSpace(needed: needed, available: capacity)
            }

            let fm = FileManager.default
            var copied: Int64 = 0
            var lastReported = -1.0
            for entry in files {
                if cancelFlag.isCancelled { throw CancellationError() }
                let dest = gameDataDir.appendingPathComponent(entry.rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: entry.src, to: dest)
                // The copy owns the saves now — originals may carry read-only
                // permissions that would block the game's writes.
                if let perms = (try? fm.attributesOfItem(atPath: dest.path))?[.posixPermissions] as? NSNumber {
                    let writable = perms.uint16Value | 0o600
                    try? fm.setAttributes([.posixPermissions: NSNumber(value: writable)],
                                          ofItemAtPath: dest.path)
                }
                copied += entry.size
                let fraction = Double(copied) / Double(totalBytes)
                if fraction - lastReported >= 0.005 || copied >= totalBytes {
                    lastReported = fraction
                    progress(fraction, entry.rel)
                }
            }
        }.value
    }

    nonisolated private static func shouldSkipImport(name: String) -> Bool {
        let lower = name.lowercased()
        // Dot-prefixed covers .DS_Store and AppleDouble ._* (Windows games
        // never ship dotfiles); the rest are Melammu diagnostic leftovers.
        if lower.hasPrefix(".") { return true }
        if lower.contains(".bak-") { return true }
        if lower.contains(".disabled-") { return true }
        if lower.hasSuffix(".regen-test") { return true }
        return false
    }

    // Follows symlinks (shadow-style sources mix links and real files) with a
    // visited set guarding against cycles.
    nonisolated private static func collectGameFiles(
        dir: URL, rel: String, excluded: Set<String>,
        into files: inout [(rel: String, src: URL, size: Int64)],
        visited: inout Set<String>
    ) throws {
        guard visited.insert(dir.resolvingSymlinksInPath().path).inserted else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )
        for item in contents {
            let name = item.lastPathComponent
            if shouldSkipImport(name: name) { continue }
            let itemRel = rel.isEmpty ? name : rel + "/" + name
            if excluded.contains(itemRel.lowercased()) { continue }
            let resolved = item.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            // Dead symlinks (e.g. /tmp leftovers) are silently dropped
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try collectGameFiles(dir: resolved, rel: itemRel, excluded: excluded,
                                     into: &files, visited: &visited)
            } else {
                let size = Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                files.append((rel: itemRel, src: resolved, size: size))
            }
        }
    }

    // MARK: - Game data drive mapping

    /// Maps the game data into the prefix via a dosdevices drive letter and
    /// returns the Windows path (e.g. `W:\gamedata\`) the game is reachable at.
    ///
    /// The drive points at the PARENT of gameDataDir, never at gameDataDir
    /// itself — so the game lives one level down at `W:\<folder>\`, not at the
    /// drive root. yaneurao's Start.exe is a launcher that loads
    /// `<install.inf Current>\Start.exe` as a module; if Current is the drive
    /// root (`W:\`) it loads itself forever (build_module loop → 92% CPU, no
    /// window — verified on a yaneurao title). A subfolder matches the (A) wrapper
    /// topology (`C:\Program Files\<game>\`, Current=`G:\…\<game>\`) that runs
    /// cleanly. The symlink lives on the local APFS volume, so the target may
    /// be on any filesystem. W is high enough that mountmgr's auto-assignment
    /// (d: upward) never collides, and Wine preserves manual mappings.
    @discardableResult
    func mapGameDataDrive(prefix: URL, gameDataDir: URL, letter: String = "w") throws -> String {
        let dosdevices = prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        let link = dosdevices.appendingPathComponent("\(letter):")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: gameDataDir.deletingLastPathComponent())
        // e.g. "W:\gamedata\" — "\\" is one backslash in a normal string literal
        return letter.uppercased() + ":\\" + gameDataDir.lastPathComponent + "\\"
    }

    // MARK: - Path-memory rewrite (install.inf etc.)

    /// Kaguya-retail games record their install dir as an absolute Windows
    /// path in install.inf (`Current = "G:\game\…"`) and resolve Lib/, data
    /// and saves through it — without rewriting it the whole copy is bypassed.
    /// Rewrites Current= to the drive root in the copy only; scans other shallow
    /// ini/inf files and reports absolute Windows paths without touching them.
    func rewritePathMemoryFiles(in gameDataDir: URL, driveRoot: String = #"W:\"#) -> [PathMemoryHit] {
        var hits: [PathMemoryHit] = []
        for file in pathMemoryCandidates(in: gameDataDir) {
            if file.lastPathComponent.lowercased() == "install.inf" {
                hits.append(contentsOf: rewriteInstallInf(at: file, driveRoot: driveRoot))
            } else {
                hits.append(contentsOf: scanWindowsPaths(in: file))
            }
        }
        return hits
    }

    // Shallow scan (root + one subdir level), .inf/.ini up to 64 KB
    private func pathMemoryCandidates(in root: URL) -> [URL] {
        var results: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []
            ) else { return }
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if depth < 1 { scan(item, depth: depth + 1) }
                    continue
                }
                let ext = item.pathExtension.lowercased()
                guard ext == "inf" || ext == "ini" else { continue }
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 65536 else { continue }
                results.append(item)
            }
        }
        scan(root, depth: 0)
        return results
    }

    /// Byte-level rewrite: install.inf is CP932(Shift-JIS) + CRLF and the
    /// title line contains SJIS bytes — the file is never String-decoded.
    /// Only the ASCII `Current = "..."` line is replaced; every other byte
    /// is preserved verbatim.
    private func rewriteInstallInf(at file: URL, driveRoot: String) -> [PathMemoryHit] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var lines: [Data] = []
        var start = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0D, i + 1 < data.endIndex, data[i + 1] == 0x0A {
                lines.append(data.subdata(in: start..<i))
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        let tail = data.subdata(in: start..<data.endIndex)

        var hits: [PathMemoryHit] = []
        var changed = false
        let replacement = Data("Current = \"\(driveRoot)\"".utf8)  // pure ASCII
        for idx in lines.indices {
            if Self.lineStartsWithKey(lines[idx], key: "Current") {
                if lines[idx] != replacement {
                    let original = String(data: lines[idx], encoding: .shiftJIS)
                        ?? String(decoding: lines[idx], as: UTF8.self)
                    lines[idx] = replacement
                    changed = true
                    hits.append(PathMemoryHit(file: file, line: original, rewritten: true))
                }
            } else if Self.containsWindowsAbsolutePath(String(data: lines[idx], encoding: .shiftJIS) ?? "") {
                // e.g. CDDrive= — left untouched (dead reference, game runs
                // with it as-is), surfaced for the user
                let text = String(data: lines[idx], encoding: .shiftJIS) ?? ""
                hits.append(PathMemoryHit(file: file, line: text, rewritten: false))
            }
        }
        guard changed else { return hits }

        var out = Data(capacity: data.count)
        for line in lines {
            out.append(line)
            out.append(contentsOf: [0x0D, 0x0A])
        }
        out.append(tail)
        try? out.write(to: file)
        return hits
    }

    // Matches optional ASCII whitespace, the key, optional whitespace, '='
    private static func lineStartsWithKey(_ line: Data, key: String) -> Bool {
        let keyBytes = Array(key.utf8)
        var i = line.startIndex
        while i < line.endIndex, line[i] == 0x20 || line[i] == 0x09 { i += 1 }
        for byte in keyBytes {
            guard i < line.endIndex, line[i] == byte else { return false }
            i += 1
        }
        while i < line.endIndex, line[i] == 0x20 || line[i] == 0x09 { i += 1 }
        return i < line.endIndex && line[i] == 0x3D  // '='
    }

    private static func containsWindowsAbsolutePath(_ text: String) -> Bool {
        text.range(of: #"[A-Za-z]:\\"#, options: .regularExpression) != nil
    }

    private func scanWindowsPaths(in file: URL) -> [PathMemoryHit] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        let text = String(data: data, encoding: .shiftJIS)
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        var hits: [PathMemoryHit] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard Self.containsWindowsAbsolutePath(line) else { continue }
            hits.append(PathMemoryHit(file: file, line: line, rewritten: false))
        }
        return hits
    }

    // MARK: - Prefix initialization

    func createPrefix(at prefixURL: URL) async throws {
        guard let wine = wineURL() else { throw InstallerError.wineNotFound }
        try await runCommand(wine, arguments: ["wineboot", "--init"],
                             environment: wineEnv(prefix: prefixURL))
    }

    // MARK: - Fonts

    // Fonts installed into every prefix. BIZ UD family (TrueType, MS Gothic-
    // compatible metrics) is the primary substitution target: CFF fonts like
    // Source Han Sans drop strokes in engines that rasterize text via
    // GGO_BITMAP (mono), and their wider metrics clip fixed-size dialog labels.
    // MelammuUDGothic-Regular is a renamed single-weight BIZUDGothic-Regular:
    // having no Bold face forces Wine's synthetic bold, matching how Windows
    // renders MS Gothic Bold (see wine-support/fonts/README.md).
    private static let prefixFontNames = [
        "sourcehansans.ttc",
        "unifont.ttf",
        "BIZUDGothic-Regular.ttf",
        "BIZUDGothic-Bold.ttf",
        "BIZUDPGothic-Regular.ttf",
        "BIZUDPGothic-Bold.ttf",
        "BIZUDMincho-Regular.ttf",
        "BIZUDPMincho-Regular.ttf",
        "MelammuUDGothic-Regular.ttf",
        // Dialog-only narrow proportional for EngineProfile.narrowProportional
        // engines: IPAPGothic kana with half-width digits condensed to MS PGothic's
        // 0.5 em (stops "255"-style digit clipping) and every name record rewritten
        // so no "IPA Pゴシック" name survives to collide with a JP-locale fallback.
        // Built by tools/make_melammu_pgothic.py from ipagp.ttf (IPA Font License
        // v1.0 — derivative redistribution OK with the bundled license file).
        "MelammuPGothic-Regular.ttf",
    ]

    func installFonts(to prefixURL: URL) throws {
        let fontsDir = prefixURL.appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        for name in Self.prefixFontNames {
            guard let src = findFontURL(named: name) else { continue }
            let dest = fontsDir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    // MARK: - Font substitution

    func registerJapaneseFonts(to prefixURL: URL, profile: EngineProfile? = nil) async {
        guard let wine = wineURL() else { return }
        let env = wineEnv(prefix: prefixURL)
        // Wine reads font replacements from its own key, not Windows FontSubstitutes.
        // The Windows-standard HKLM FontSubstitutes is ignored by Wine's GDI in wow64 mode.
        let wineKey = #"HKCU\Software\Wine\Fonts\Replacements"#
        // Fixed-pitch gothic target. "Melammu UDGothic" is single-weight → Wine
        // synthesizes bold like Windows does for MS Gothic (no real Bold face).
        let gothic = (profile?.msGothicSynthBold == true) ? "Melammu UDGothic" : "BIZ UDGothic"
        // Proportional MS faces. Default BIZ UDPGothic (body-text quality, real
        // Bold). narrowProportional engines get "Melammu PGothic" — IPAPGothic's
        // narrow kana with half-width digits condensed to MS PGothic's 0.5 em, so
        // fixed-size dialog labels AND the "255" RGB scale fit (verified on a yaneurao title).
        // Meiryo/Yu Gothic stay BIZ UDP: no engine requests them for dialogs here,
        // and the verified yaneurao prefix uses exactly this split.
        let propo = (profile?.narrowProportional == true) ? "Melammu PGothic" : "BIZ UDPGothic"
        let subs: [(String, String)] = [
            // Japanese names → bundled BIZ UD family (TrueType, MS-compatible
            // metrics — Source Han Sans is CFF and wider, which drops strokes in
            // GGO_BITMAP engines and clips fixed-size dialog labels).
            // Fixed-pitch ⇔ proportional and gothic ⇔ mincho are mapped 1:1 so
            // engine layouts that depend on the distinction survive.
            ("Meiryo",                "BIZ UDPGothic"),
            ("Meiryo UI",             "BIZ UDPGothic"),
            ("MS Gothic",             gothic),
            ("MS PGothic",            propo),
            ("MS UI Gothic",          propo),
            ("MS Mincho",             "BIZ UDMincho"),
            ("MS PMincho",            "BIZ UDPMincho"),
            ("Yu Gothic",             "BIZ UDPGothic"),
            ("Yu Gothic UI",          "BIZ UDPGothic"),
            ("Yu Mincho",             "BIZ UDPMincho"),
            ("UD Digi KyoKasho N-R",  "BIZ UDGothic"),
            ("UD Digi KyoKasho NK-R", "BIZ UDPGothic"),
            ("UD Digi KyoKasho NP-R", "BIZ UDPGothic"),
            // Japanese full-width / katakana names (games request these via CP932/W APIs;
            // verified with WINEDEBUG=+font)
            ("メイリオ",               "BIZ UDPGothic"),
            ("ＭＳ ゴシック",           gothic),
            ("ＭＳ 明朝",               "BIZ UDMincho"),
            ("ＭＳ Ｐゴシック",         propo),
            ("ＭＳ Ｐ明朝",             "BIZ UDPMincho"),
            // Korean → Source Han Sans K
            ("Batang",                "Source Han Sans K"),
            ("BatangChe",             "Source Han Sans K"),
            ("Dotum",                 "Source Han Sans K"),
            ("DotumChe",              "Source Han Sans K"),
            ("Gulim",                 "Source Han Sans K"),
            ("GulimChe",              "Source Han Sans K"),
            ("Gungsuh",               "Source Han Sans K"),
            ("GungsuhChe",            "Source Han Sans K"),
            ("Malgun Gothic",         "Source Han Sans K"),
            ("굴림",                   "Source Han Sans K"),
            ("굴림체",                  "Source Han Sans K"),
            ("돋움",                   "Source Han Sans K"),
            ("돋움체",                  "Source Han Sans K"),
            ("맑은 고딕",               "Source Han Sans K"),
            ("바탕",                   "Source Han Sans K"),
            ("바탕체",                  "Source Han Sans K"),
            // Chinese Simplified → Source Han Sans SC
            ("Dengxian",              "Source Han Sans SC"),
            ("FangSong",              "Source Han Sans SC"),
            ("KaiTi",                 "Source Han Sans SC"),
            ("Microsoft YaHei",       "Source Han Sans SC"),
            ("Microsoft YaHei UI",    "Source Han Sans SC"),
            ("NSimSun",               "Source Han Sans SC"),
            ("SimHei",                "Source Han Sans SC"),
            ("SimKai",                "Source Han Sans SC"),
            ("SimSun",                "Source Han Sans SC"),
            ("SimSun-ExtB",           "Source Han Sans SC"),
            // Chinese Traditional → Source Han Sans TC
            ("DFKai-SB",              "Source Han Sans TC"),
            ("Microsoft JhengHei",    "Source Han Sans TC"),
            ("Microsoft JhengHei UI", "Source Han Sans TC"),
            ("MingLiU",               "Source Han Sans TC"),
            ("MingLiU-ExtB",          "Source Han Sans TC"),
            ("PMingLiU",              "Source Han Sans TC"),
            ("PMingLiU-ExtB",         "Source Han Sans TC"),
            // Full Unicode fallback
            ("Arial Unicode MS",      "Unifont"),
            // MS Shell Dlg is a virtual alias that Windows resolves to Tahoma.
            // BGI/Ethornell reads NONCLIENTMETRICS which wineboot (LANG=ja_JP.UTF-8) sets
            // to "MS Shell Dlg". Without this mapping Wine cannot resolve the name cleanly,
            // causing infinite GDI recursion (stack overflow at gdi32+0x505c).
            ("MS Shell Dlg",          "Tahoma"),
            ("MS Shell Dlg 2",        "Tahoma"),
        ]
        for (from, to) in subs {
            try? await runCommand(wine, arguments: [
                "reg", "add", wineKey, "/v", from, "/t", "REG_SZ", "/d", to, "/f"
            ], environment: env)
        }
        // 96 DPI — prevents content tearing in d3d9 games
        try? await runCommand(wine, arguments: [
            "reg", "add", #"HKCU\Software\Wine\Fonts"#,
            "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96", "/f"
        ], environment: env)
        // Japanese codepage (Shift-JIS) — required for BGI/Ethornell and other
        // Japanese engines to enumerate fonts without GDI recursion in wow64 mode.
        try? await runCommand(wine, arguments: [
            "reg", "add", #"HKCU\Software\Wine\Fonts"#,
            "/v", "Codepages", "/t", "REG_SZ", "/d", "932,932", "/f"
        ], environment: env)
        // ClearType (FontSmoothingType=2) — wineboot defaults to Grayscale (type=1).
        // Without ClearType, Wine GDI takes a different rendering path that triggers
        // infinite recursion in BGI/Ethornell's WndProc during startup.
        let desktopKey = #"HKCU\Control Panel\Desktop"#
        try? await runCommand(wine, arguments: [
            "reg", "add", desktopKey, "/v", "FontSmoothing", "/t", "REG_SZ", "/d", "2", "/f"
        ], environment: env)
        try? await runCommand(wine, arguments: [
            "reg", "add", desktopKey, "/v", "FontSmoothingType", "/t", "REG_DWORD", "/d", "2", "/f"
        ], environment: env)
        try? await runCommand(wine, arguments: [
            "reg", "add", desktopKey, "/v", "FontSmoothingGamma", "/t", "REG_DWORD", "/d", "1400", "/f"
        ], environment: env)
        try? await runCommand(wine, arguments: [
            "reg", "add", desktopKey, "/v", "FontSmoothingOrientation", "/t", "REG_DWORD", "/d", "1", "/f"
        ], environment: env)
        // Console font must be a fixed-width font. When wineboot runs with LANG=ja_JP.UTF-8,
        // Wine's CoreText font lookup picks BIZ UDGothic (macOS system Japanese font) as the
        // console font, which is proportional. BGI/Ethornell creates a console window at startup;
        // gdi32's raster-font selection on a proportional font recurses infinitely → stack overflow.
        let consoleKey = #"HKCU\Console"#
        try? await runCommand(wine, arguments: [
            "reg", "add", consoleKey, "/v", "FaceName", "/t", "REG_SZ", "/d", "Courier New", "/f"
        ], environment: env)
        // FontSize DWORD: high word = height (16), low word = width (8) → 0x00100008 = 1048584
        try? await runCommand(wine, arguments: [
            "reg", "add", consoleKey, "/v", "FontSize", "/t", "REG_DWORD", "/d", "1048584", "/f"
        ], environment: env)
    }

    // MARK: - DXVK

    func installDXVK(to prefixURL: URL) async throws {
        guard let wine = wineURL() else { throw InstallerError.wineNotFound }
        guard let dxvkDir = dxvkBundleURL() else { return }  // gracefully skip if not bundled

        let sys32  = prefixURL.appendingPathComponent("drive_c/windows/system32")
        let sysWow = prefixURL.appendingPathComponent("drive_c/windows/syswow64")
        try FileManager.default.createDirectory(at: sys32,  withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysWow, withIntermediateDirectories: true)

        let dlls = ["d3d9.dll", "d3d11.dll", "dxgi.dll"]
        for dll in dlls {
            let x64 = dxvkDir.appendingPathComponent("x64/\(dll)")
            let x32 = dxvkDir.appendingPathComponent("x32/\(dll)")
            if FileManager.default.fileExists(atPath: x64.path) {
                let dest = sys32.appendingPathComponent(dll)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: x64, to: dest)
                Self.stripWineBuiltinMarker(at: dest)
            }
            if FileManager.default.fileExists(atPath: x32.path) {
                let dest = sysWow.appendingPathComponent(dll)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: x32, to: dest)
                Self.stripWineBuiltinMarker(at: dest)
            }
        }

        // DLL overrides: prefer native DXVK over Wine built-ins
        let env = wineEnv(prefix: prefixURL)
        for name in ["d3d9", "d3d11", "dxgi"] {
            try await runCommand(wine, arguments: [
                "reg", "add",
                #"HKCU\Software\Wine\DllOverrides"#,
                "/v", name, "/t", "REG_SZ", "/d", "native,builtin", "/f"
            ], environment: env)
        }

        // Force vsync regardless of per-game settings (e.g. KiriKiriZ writes waitvsync=no
        // which causes tearing/flickering on Wine+Metal without this override).
        let conf = prefixURL.appendingPathComponent("drive_c/dxvk.conf")
        try? "d3d9.presentInterval = 1\n".write(to: conf, atomically: true, encoding: .utf8)
    }

    // MARK: - LAV Filters (stub — requires winetricks or bundled installer)

    func installLAVFilters(to prefixURL: URL) async throws {
        let winetricks = URL(fileURLWithPath: "/usr/local/bin/winetricks")
        guard FileManager.default.fileExists(atPath: winetricks.path) else { return }
        var env = wineEnv(prefix: prefixURL)
        env["WINEPREFIX"] = prefixURL.path
        // Ignore exit code; winetricks may return non-zero on partial installs
        try? await runCommand(winetricks, arguments: ["lavfilters"], environment: env)
    }

    // MARK: - Installer execution

    func runInstaller(at exeURL: URL, prefix prefixURL: URL) async throws {
        guard let wine = wineURL() else { throw InstallerError.wineNotFound }
        // Don't redirect stdout/stderr — installer needs its UI rendered by Wine
        try await runProcess(wine, arguments: [exeURL.path],
                             environment: wineEnv(prefix: prefixURL))
        // Wait for any deferred Wine child processes to settle
        if let wineserver = wineServerURL() {
            try? await runCommand(wineserver, arguments: ["-w"],
                                  environment: wineEnv(prefix: prefixURL))
        }
    }

    // MARK: - Exe detection

    func detectGameExes(in prefixURL: URL) -> [URL] {
        let searchDirs = [
            prefixURL.appendingPathComponent("drive_c/Program Files"),
            prefixURL.appendingPathComponent("drive_c/Program Files (x86)")
        ]
        var results: [URL] = []
        for dir in searchDirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "exe" else { continue }
                guard !isNonGameExe(url) else { continue }
                // Skip tiny executables (launchers, shims < 64 KB)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size >= 65536 else { continue }
                results.append(url)
            }
        }
        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func detectExesInFolder(_ folder: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents
            .filter { $0.pathExtension.lowercased() == "exe" && !isNonGameExe($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isNonGameExe(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let blockedNames: Set<String> = [
            "iexplore.exe", "wordpad.exe", "write.exe", "notepad.exe",
            "mspaint.exe", "calc.exe", "regedit.exe", "taskmgr.exe",
            "explorer.exe", "cmd.exe", "conhost.exe", "wineboot.exe",
            "wmplayer.exe", "sidebar.exe", "msiexec.exe", "werfault.exe",
        ]
        if blockedNames.contains(name) { return true }
        let blockedPrefixes = ["unins", "vcredist", "dxsetup", "dotnetfx", "openal", "directx", "redist"]
        return blockedPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Engine profile application

    func applyEngineProfile(_ profile: EngineProfile, to prefixURL: URL) async throws {
        guard let wine = wineURL() else { throw InstallerError.wineNotFound }
        let sys32 = prefixURL.appendingPathComponent("drive_c/windows/system32")
        let env = wineEnv(prefix: prefixURL)

        for fileName in profile.system32Files {
            guard let src = bundleSystem32File(named: fileName) else { continue }
            let dest = sys32.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
            let dllName = (fileName as NSString).deletingPathExtension
            try? await runCommand(wine, arguments: [
                "reg", "add",
                #"HKCU\Software\Wine\DllOverrides"#,
                "/v", dllName, "/t", "REG_SZ", "/d", "native,builtin", "/f"
            ], environment: env)
        }
    }

    // MARK: - Rollback

    func rollback(gameDir: URL, gameDataDir: URL? = nil) {
        try? FileManager.default.removeItem(at: gameDir)
        if let gameDataDir, !gameDataDir.path.hasPrefix(gameDir.path + "/") {
            // External-volume layout <root>/Melammu/Games/<id>/gamedata —
            // remove the per-game <id> dir, not just gamedata inside it
            try? FileManager.default.removeItem(at: gameDataDir.deletingLastPathComponent())
        }
    }

    // MARK: - Game construction

    func buildGame(id: UUID, name: String, gameDir: URL, gameDataDir: URL? = nil,
                   selectedExe: URL, engineID: EngineProfile.ID?) -> Game {
        let prefix = gameDir.appendingPathComponent("prefix")
        var exePath = selectedExe.path
        if let dataDir = gameDataDir, exePath.hasPrefix(dataDir.path + "/") {
            exePath = String(exePath.dropFirst(dataDir.path.count + 1))
        } else if exePath.hasPrefix(prefix.path + "/") {
            exePath = String(exePath.dropFirst(prefix.path.count + 1))
        }
        return Game(id: id, name: name, gameDir: gameDir.path, exePath: exePath,
                    gameDataDir: gameDataDir?.path, engineID: engineID)
    }

    // MARK: - Private: environment / paths (instance wrappers)

    private func wineEnv(prefix: URL) -> [String: String] { Self.makeWineEnv(prefix: prefix) }
    private func wineURL() -> URL? { Self.findWineURL() }
    private func wineServerURL() -> URL? { Self.findWineURL()?.deletingLastPathComponent().appendingPathComponent("wineserver") }

    // MARK: - Static shared helpers (used by LibraryViewModel too)

    nonisolated static func makeWineEnv(prefix: URL, wine64: Bool = false, runtimeSubdir: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEMSYNC"] = "1"
        env["LANG"] = "ja_JP.UTF-8"
        env["WINEDEBUG"] = "-all"
        // Set WINEDLLPATH only when the bundled wine-support dir exists.
        // wine64 uses its own separate installation (wine-support/wine64/) to avoid
        // version mismatch with wine-10.0 DLLs (wine-7.7 wine64 needs wine-7.7 DLLs).
        // runtimeSubdir overrides the default for engine-specific runtimes
        // (general hook; currently unused — all engines use the default B fork.
        // The 803M "wine-sikarugir" (A) runtime was retired; see
        // EngineProfile.wineRuntimeSubdir).
        let wineSupportSubdir = runtimeSubdir ?? (wine64 ? "wine64" : "wine")
        if let libDir = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/\(wineSupportSubdir)/lib/wine"),
           FileManager.default.fileExists(atPath: libDir.path) {
            env["WINEDLLPATH"] = libDir.path
        }

        // GStreamer runtime for movie playback (winegstreamer.so → quartz). The
        // bundled winegstreamer.so only has rpath @loader_path/, so it cannot find
        // the GStreamer core dylibs on its own; point it (and the plugin loader)
        // at the shared bundled GStreamer.framework — exactly how the Sikarugir
        // launcher wires it (DYLD_FALLBACK_LIBRARY_PATH + GST_PLUGIN_PATH). Applies
        // to all runtimes; DYLD_FALLBACK is only consulted when normal resolution
        // fails, so it does not disturb wine's own dylib loading.
        if let fw = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/GStreamer.framework"),
           FileManager.default.fileExists(atPath: fw.path) {
            let libs = fw.appendingPathComponent("Libraries").path
            let plugins = fw.appendingPathComponent("Versions/Current/lib/gstreamer-1.0").path
            let scanner = fw.appendingPathComponent("Versions/Current/libexec/gstreamer-1.0/gst-plugin-scanner").path
            let priorFallback = env["DYLD_FALLBACK_LIBRARY_PATH"]
            env["DYLD_FALLBACK_LIBRARY_PATH"] = priorFallback.map { "\(libs):\($0)" }
                ?? "\(libs):/usr/local/lib:/usr/lib"
            env["GST_PLUGIN_PATH"] = plugins
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins
            env["GST_PLUGIN_SCANNER"] = scanner
        }
        return env
    }

    /// Kills every wine process belonging to `prefix` — and only that prefix.
    /// wineserver -k resolves its target via the prefix's dev/inode socket
    /// (/tmp/.wine-<uid>/server-<dev>-<inode>/), so it is structurally unable
    /// to touch other prefixes or the (A) wrapper apps. Tried with both
    /// bundled wine and wine64 servers; whichever doesn't own the prefix
    /// exits harmlessly.
    nonisolated static func killWineServer(prefix: URL) {
        // Try every bundled runtime's wineserver. The kill target is resolved from
        // the prefix's server socket (dev/inode), so the server that doesn't own
        // the prefix exits harmlessly — we just need to include the one that does.
        // (wine64: Bool, runtimeSubdir: String?)
        let runtimes: [(Bool, String?)] = [(false, nil), (true, nil)]
        for (wine64, runtimeSubdir) in runtimes {
            guard let wineserver = findWineURL(wine64: wine64, runtimeSubdir: runtimeSubdir)?
                      .deletingLastPathComponent().appendingPathComponent("wineserver"),
                  FileManager.default.fileExists(atPath: wineserver.path) else { continue }
            let p = Process()
            p.executableURL = wineserver
            p.arguments = ["-k"]
            p.environment = makeWineEnv(prefix: prefix, wine64: wine64, runtimeSubdir: runtimeSubdir)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()  // -k just signals the server; returns immediately
            } catch { continue }
        }
    }

    /// バンドル同梱の DXVK DLL には Sikarugir 由来の wine builtin 署名
    /// （PE の DOS スタブ・offset 0x40 付近の "Wine builtin DLL"）が埋め込まれている。
    /// この署名があると wine ローダは当該 DLL を builtin と判定し、`native` ロード経路では
    /// 受け付けない（`d3d11=native` 単独だと c0000135、`native,builtin` だと黙って
    /// wine 内蔵 d3d11→wined3d にフォールバックして DXVK が起動しない）。
    /// 署名を 0 で潰すと true native として読まれ、prefix に置いた DXVK が
    /// `native,builtin` override で正しくロードされ、DXVK→Vulkan→MoltenVK が機能する。
    /// （Sikarugir は DXVK を wine の builtin ディレクトリに重ねて builtin としてロードする
    /// ため同じ署名でも動く。Melammu は prefix 内に native として置く設計なので署名が逆効果。）
    /// 冪等: 署名が無ければ（既に native / DXVK 以外）何もしない。誤爆防止に PE ヘッダ
    /// (e_lfanew) より前の DOS スタブ領域に限定して探索する。
    @discardableResult
    nonisolated static func stripWineBuiltinMarker(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        var bytes = [UInt8](data)
        guard bytes.count > 0x40 else { return false }
        let lfanew = Int(bytes[0x3c]) | (Int(bytes[0x3d]) << 8)
                   | (Int(bytes[0x3e]) << 16) | (Int(bytes[0x3f]) << 24)
        let limit = min(max(lfanew, 0x40), bytes.count)
        let marker = Array("Wine builtin DLL".utf8)
        guard marker.count <= limit else { return false }
        var found = -1
        for start in 0...(limit - marker.count) where Array(bytes[start..<start + marker.count]) == marker {
            found = start
            break
        }
        guard found >= 0 else { return false }
        for i in found..<found + marker.count { bytes[i] = 0 }
        do { try Data(bytes).write(to: url); return true } catch { return false }
    }

    /// wine Mac ドライバの RetinaMode を prefix に設定/解除する。
    /// RetinaMode=y にすると wine の座標系が Retina（高DPI）になり、DXVK ゲームの
    /// 自前ウィンドウ中央寄せが画面内に収まる＋高精細描画になる（固定720pは等倍で小さめ）。
    /// 既に目的の状態なら何もしない（user.reg を読むだけで wine プロセスを起動しないので速い）。
    /// 変更が要る時だけ `wine reg` を同期実行する（トグル時のみ・稀）。
    nonisolated static func setRetinaMode(_ on: Bool, prefix: URL) {
        let userReg = prefix.appendingPathComponent("user.reg")
        if currentRetinaMode(userReg: userReg) == on { return }
        guard let wine = findWineURL() else { return }
        let p = Process()
        p.executableURL = wine
        if on {
            p.arguments = ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
                           "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"]
        } else {
            p.arguments = ["reg", "delete", #"HKCU\Software\Wine\Mac Driver"#,
                           "/v", "RetinaMode", "/f"]
        }
        p.environment = makeWineEnv(prefix: prefix)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { }
    }

    /// user.reg の [Software\\Wine\\Mac Driver] セクションに "RetinaMode"="y" があるか。
    private nonisolated static func currentRetinaMode(userReg: URL) -> Bool {
        guard let text = try? String(contentsOf: userReg, encoding: .utf8) else { return false }
        var inSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.hasPrefix(#"[Software\\Wine\\Mac Driver]"#)
                continue
            }
            if inSection && line.hasPrefix(#""RetinaMode"="#) {
                return line.contains(#"="y""#)
            }
        }
        return false
    }

    /// macOS の検疫属性 (com.apple.quarantine) を再帰的に除去する。
    /// ネット DL したゲームの exe/DLL に付いたままだと、wine が exec マップする際に
    /// Gatekeeper の「マルウェアが含まれていないことを検証できませんでした」ダイアログが出て
    /// 起動できない（PROT_EXEC 修正とは別系統の macOS 機構）。除去は冪等で、付いていなくても無害。
    nonisolated static func stripQuarantine(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { }
    }

    /// True when a wineserver for this prefix has a live socket dir
    /// (/tmp/.wine-<uid>/server-<dev hex>-<inode hex>).
    nonisolated static func wineServerSocketExists(prefix: URL) -> Bool {
        var st = stat()
        guard stat(prefix.path, &st) == 0 else { return false }
        let dir = String(format: "/tmp/.wine-%d/server-%llx-%llx",
                         getuid(), UInt64(st.st_dev), UInt64(st.st_ino))
        return FileManager.default.fileExists(atPath: dir + "/socket")
    }

    nonisolated static func findWineURL(wine64: Bool = false, runtimeSubdir: String? = nil) -> URL? {
        // runtimeSubdir picks an engine-specific bundled runtime (general hook,
        // currently unused); its loader binary is always "wine" (not wine64).
        let binary = (runtimeSubdir == nil && wine64) ? "wine64" : "wine"
        let wineSupportSubdir = runtimeSubdir ?? (wine64 ? "wine64" : "wine")
        // 1. Bundled (production) — wine64 has its own full installation
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/\(wineSupportSubdir)/bin/\(binary)"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // No silent fallback to Whisky or legacy wrapper Wine. The bundled
        // runtime is the source of truth; compatibility runtimes must be
        // represented explicitly under wine-support/ and recorded in
        // the runtime manifest (maintained separately).
        return nil
    }

    private func dxvkBundleURL() -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/dxvk"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func bundleSystem32File(named name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/system32/\(name)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func findFontURL(named name: String) -> URL? {
        // 1. Bundled in Melammu.app (preferred for production)
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("wine-support/fonts/\(name)"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        // 2. Repo checkout (development run without bundled resources)
        let repoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("wine-support/fonts/\(name)")
        if FileManager.default.fileExists(atPath: repoURL.path) { return repoURL }
        // 3. From any existing game wrapper (development / migration fallback)
        return findFontInWrappers(named: name)
    }

    private func findFontInWrappers(named name: String) -> URL? {
        let wrappersDir = URL(fileURLWithPath: GameScanner.wrappersPath)
        guard let apps = try? FileManager.default.contentsOfDirectory(at: wrappersDir, includingPropertiesForKeys: nil) else { return nil }
        for app in apps.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where app.pathExtension == "app" {
            let candidate = app.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/windows/Fonts/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Private: process runners

    // Runs a process and ignores exit code (e.g. interactive installer).
    private func runProcess(
        _ url: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = url
            p.arguments = arguments
            p.environment = environment
            p.terminationHandler = { [weak self] _ in
                self?.currentProcess = nil
                cont.resume()
            }
            do { currentProcess = p; try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func runCommand(
        _ url: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = url
            p.arguments = arguments
            p.environment = environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
            p.terminationHandler = { [weak self] proc in
                self?.currentProcess = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: InstallerError.commandFailed(proc.terminationStatus))
                }
            }
            do { currentProcess = p; try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
