import Foundation

/// ゲーム本体ディレクトリからエンジンをファイルシグネチャで自動判定する。
/// 判定できない時は nil を返す（呼び出し側で手動 Picker にフォールバック）。
///
/// シグネチャは `01_engines.md` のチートシート＋A ラッパー20本の実測で検証済み
/// （19/20 一致。未対応は marmalade=スタディステディの1本のみ＝手動指定）。
/// `.pfs` は Artemis と iarsys が共用するため `iarsys64.dll` の有無で先に分岐する。
/// BGI は本体 exe の PE アーキで bgi(64bit) / bgi32(32bit) を分ける。
enum EngineDetector {

    static func detect(installerURL: URL) -> EngineProfile.ID? {
        detect(directory: installerURL.deletingLastPathComponent())
    }

    static func detect(folderURL: URL) -> EngineProfile.ID? {
        detect(directory: folderURL)
    }

    static func detect(directory: URL) -> EngineProfile.ID? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        let lower = Set(entries.map { $0.lowercased() })

        func has(_ names: String...) -> Bool { names.contains { lower.contains($0.lowercased()) } }
        func ext(_ e: String) -> Bool { lower.contains { $0.hasSuffix(e.lowercased()) } }
        func sub(_ rel: String) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(rel).path) }

        // iarsys と Artemis はどちらも .pfs。iarsys64.dll があれば iarsys。
        if has("iarsys64.dll") { return EngineProfile.iarsys.id }
        if ext(".pfs") { return EngineProfile.artemis.id }
        if has("cs2.exe") && has("boot.dfn") { return EngineProfile.catSystem2.id }
        if has("cmvs64.exe", "cmvs32.exe") { return EngineProfile.cmvs.id }
        if has("reallive.exe") || sub("REALLIVEDATA") { return EngineProfile.reallive.id }
        if ext(".xp3") {
            // ゆずソフト KiriKiri2 (Direct2D) は plugin/DrawDeviceD2D.dll を持つ。
            return sub("plugin/DrawDeviceD2D.dll")
                ? EngineProfile.kirikiri2.id : EngineProfile.kirikiri.id
        }
        if has("bgi.gdb", "bgi.edb", "bhvc.exe") {
            return mainExeIs64bit(in: directory, entries: entries)
                ? EngineProfile.bgi.id : EngineProfile.bgi32.id
        }
        // やねうらお GameSDK: Start.exe + Lib/RenderDX.dll（体験版）または
        // Start.exe に "yaneuraoGameSDK" 静的リンク（製品版）。
        if has("start.exe"),
           sub("Lib/RenderDX.dll")
            || fileContains(directory.appendingPathComponent("Start.exe"), "yaneuraoGameSDK") {
            return EngineProfile.yaneurao.id
        }
        if ext(".pac") && has("launcher.exe", "filechk.exe") { return EngineProfile.giga.id }
        if sub("AdvData") || ext(".crx") { return EngineProfile.circus.id }
        return nil   // 不明（例: marmalade）→ 手動選択へ
    }

    // MARK: - Helpers

    /// 本体らしい exe（ランチャー/インストーラ系を除いた最大サイズ）が 64bit PE か。
    private static func mainExeIs64bit(in dir: URL, entries: [String]) -> Bool {
        let blocked = ["unins", "vcredist", "setup", "config", "filechk",
                       "autoupdate", "startuptool", "launcher"]
        let exes = entries.filter { $0.lowercased().hasSuffix(".exe") }
        let candidates = exes.filter { name in
            !blocked.contains { name.lowercased().hasPrefix($0) }
        }
        let pool = candidates.isEmpty ? exes : candidates
        func size(_ name: String) -> Int {
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(name).path)
            return (attrs?[.size] as? Int) ?? 0
        }
        guard let exe = pool.max(by: { size($0) < size($1) }) else { return false }
        return peIs64bit(dir.appendingPathComponent(exe))
    }

    /// PE ヘッダの Machine フィールドが x86-64 (0x8664) か。
    private static func peIs64bit(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 0x40), head.count >= 0x40 else { return false }
        let lfanew = UInt32(head[0x3c]) | (UInt32(head[0x3d]) << 8)
                   | (UInt32(head[0x3e]) << 16) | (UInt32(head[0x3f]) << 24)
        try? fh.seek(toOffset: UInt64(lfanew))
        guard let pe = try? fh.read(upToCount: 6), pe.count == 6 else { return false }
        guard pe[0] == 0x50, pe[1] == 0x45 else { return false }   // "PE"
        let machine = UInt16(pe[4]) | (UInt16(pe[5]) << 8)
        return machine == 0x8664
    }

    /// ファイル内に ASCII 文字列が含まれるか（yaneurao 署名検出用・先頭 16MB まで）。
    private static func fileContains(_ url: URL, _ ascii: String) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16 * 1024 * 1024),
              let needle = ascii.data(using: .ascii) else { return false }
        return data.range(of: needle) != nil
    }
}
