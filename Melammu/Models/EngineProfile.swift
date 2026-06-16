import Foundation

struct EngineProfile: Identifiable, Codable, Hashable {
    typealias ID = String

    let id: ID
    let displayName: String
    let requiresDXVK: Bool
    let requiresLAVFilters: Bool
    // dll filenames to copy from bundle's wine-support/system32/ into Wine's system32
    let system32Files: [String]
    // Use wine64 instead of the bundled `wine` launcher.
    // Needed when the bundled wine's wow64 layer has wined3d feature-level failures
    // (e.g. KiriKiri2 TVP/Direct2D — DrawDeviceD2D.dll init returns void in wow64 mode).
    var requiresWine64: Bool = false
    // Map fixed-pitch ＭＳ ゴシック to the single-weight "Melammu UDGothic" family
    // so Wine GDI synthesizes bold (smearing), matching Windows — MS Gothic has no
    // real Bold face either. Engines that request condensed ＭＳ ゴシック Bold
    // (e.g. GIGA) render visibly thinner with a real-Bold family like BIZ UDGothic.
    var msGothicSynthBold: Bool = false
    // Map proportional MS faces (MS PGothic / MS UI Gothic / ＭＳ Ｐゴシック) to
    // "Melammu PGothic" instead of BIZ UDPGothic. Melammu PGothic = IPAPGothic's
    // narrow kana (~0.90 em vs BIZ UDP 0.93) with half-width digits condensed to
    // MS PGothic's 0.5 em, which stops clipping in fixed-size (DLU-based) settings
    // dialogs — both kana labels and the "255" RGB scale (these controls are
    // fixed-pixel, so glyph advance is the only lever; the dialog can't be widened
    // via font metrics). Only safe for engines whose proportional faces are
    // dialog-only — many engines (RealLive, BGI, CMVS…) render BODY text with
    // ＭＳ Ｐゴシック, so this must never become the global default (static scan).
    var narrowProportional: Bool = false
    // Game files (paths relative to the game dir) to OMIT when importing the game
    // into Melammu's managed copy. For yaneurao GameSDK this drops Lib/RenderDX.dll
    // so the engine defaults to its DIB renderer (a quality/perf preference, NOT a
    // crash fix — the settings-dialog self-subclass recursion fires in DIB mode too).
    // CAUTION: exclusion only binds if the copied install.inf's `Current=` path is
    // rewritten to the import destination — kaguya titles resolve Lib/data/saves via
    // that absolute path, not the exe's directory. Consumed by the copy-import flow
    // in InstallerService.importGameCopy / rewriteInstallInf.
    var excludedGameFiles: [String] = []
    // When non-nil, used verbatim as WINEDLLOVERRIDES at launch, taking precedence
    // over the default blanket DXVK override. Lets an engine run a MIXED Direct3D
    // config — e.g. KiriKiri Z wants d3d9 on wined3d (light: no per-draw
    // DXVK→MoltenVK cost, which saturated one core) but d3d11 still on DXVK:
    // "d3d9=b;d3d11=n,b". Only consulted when requiresDXVK is true so the
    // DXVK DLL prep / Retina handling still runs for the d3d11 side. The bundled
    // wined3d d3d9 is safe for non-CMVS games now that the CMVS save-thumbnail
    // capture is gated off by default (see enablesCmvsCapture).
    var wineDllOverrides: String? = nil
    // Enables the Melammu CMVS save-thumbnail capture in the bundled wine's d3d9.dll
    // (sets MELAMMU_CMVS_THUMBS=1). Default OFF: the capture hooks are inert and
    // d3d9 behaves like stock wine. ONLY CMVS needs it — enabling it for another
    // engine white-screens it, because the per-Present back-buffer capture +
    // last-presented serve on READONLY locks corrupts normal rendering (this was
    // the KiriKiri Z wined3d regression).
    var enablesCmvsCapture: Bool = false
    // Which bundled wine runtime to launch this engine with, as the
    // wine-support/<subdir>/ directory name. nil = default (Melammu fork "wine").
    // General escape hatch; currently every engine uses the default (B). The
    // former "wine-sikarugir" (A) routing for KiriKiri Z was retired once clean-
    // gated A/B perf measurement showed no material difference (static AND dynamic),
    // and the 803M Sikarugir runtime was dropped from the bundle (runtime
    // consolidation). Orthogonal to requiresWine64.
    var wineRuntimeSubdir: String? = nil
}

extension EngineProfile {
    static let bgi = EngineProfile(
        id: "bgi",
        displayName: "BGI (64bit)",
        requiresDXVK: true,
        requiresLAVFilters: false,
        system32Files: []
    )
    // 32-bit BGI games: DXVK is not applicable (Vulkan timeline semaphore unsupported for 32-bit).
    // Uses wined3d fallback instead.
    static let bgi32 = EngineProfile(
        id: "bgi32",
        displayName: "BGI (32bit)",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: []
    )
    // KiriKiri Z runs on the fork (B). The former per-game Sikarugir(A) opt-in
    // (a KiriKiri Z title via Game.wineRuntimeOverride="wine-sikarugir") was retired:
    // clean-gated A/B perf showed no material difference and the bundled 803M
    // Sikarugir runtime was removed.
    // NOTE: B is not universally good. a CMVS title freezes in an
    // experimental-wow64 longjmp loop (STATUS_LONGJUMP 0x80000026) on BOTH A and
    // B (clean-prefix repro) — a deeper wine bug, not fixable by runtime choice
    // (post-v1).
    // wineDllOverrides keeps d3d9 on wined3d / d3d11 on DXVK.
    static let kirikiri = EngineProfile(
        id: "kirikiri",
        displayName: "KiriKiri Z",
        requiresDXVK: true,
        requiresLAVFilters: true,
        system32Files: ["extrans.dll"],
        wineDllOverrides: "d3d9=b;d3d11=n,b;dxgi=b"
    )
    static let catSystem2 = EngineProfile(
        id: "cs2",
        displayName: "CatSystem2",
        requiresDXVK: true,
        requiresLAVFilters: false,
        system32Files: []
    )
    static let reallive = EngineProfile(
        id: "reallive",
        displayName: "RealLive",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: []
    )
    // Artemis uses D3D11 (GALSFICTION_tr.exe imports d3d11/dxgi and calls
    // D3D11CreateDevice). DXVK is required on fork (B). Without it, the bundled
    // wined3d falls back and CreateVertexShader fails.
    // d3d11 on DXVK, d3d9 on builtin wined3d (same config as KiriKiri Z).
    // Default "d3d9,d3d11=n,b" would also set d3d9 to native(DXVK), causing the
    // DirectShow movie VMR (Direct3D9-based rendering) to run on DXVK d3d9
    // (MoltenVK), resulting in white-screen output (winegstreamer decode is fine).
    // In-game verified: d3d9=b fixes OP movie rendering.
    // Game body renders in d3d11, so d3d9=builtin does not affect main rendering.
    static let artemis = EngineProfile(
        id: "artemis",
        displayName: "Artemis Engine",
        requiresDXVK: true,
        requiresLAVFilters: false,
        system32Files: [],
        wineDllOverrides: "d3d9=b;d3d11=n,b;dxgi=b"
    )
    // CMVS runs on wined3d. DXVK must stay off for two reasons:
    // (1) cmvs64 + DXVK crashes (requires Vulkan 1.3, unsupported by MoltenVK);
    // (2) the save-thumbnail fix (last-presented back-buffer serve) lives in
    //     wined3d's d3d9.dll — DXVK's d3d9 would reintroduce black thumbnails.
    // The verified CMVS prefix uses exactly this configuration.
    static let cmvs = EngineProfile(
        id: "cmvs",
        displayName: "CMVS",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: [],
        enablesCmvsCapture: true
    )
    // iarsys titles: main rendering uses d3d11(DXVK).
    // DirectShow movies use EVR (Enhanced Video Renderer), unlike artemis which uses VMR7.
    // Decode via winegstreamer is fine, but EVR frame present depends on Wine's
    // dxva2 video processor (semi-stub), causing white-screen hang (audio renderer
    // wedge). This cannot be fixed by d3d9 backend selection (DXVK vs wined3d)
    // — it is an EVR/DXVA2 layer issue. Tracked as post-v1 work.
    static let iarsys = EngineProfile(
        id: "iarsys",
        displayName: "iarsys (Qruppo)",
        requiresDXVK: true,
        requiresLAVFilters: false,
        system32Files: []
    )
    // KiriKiri2 TVP with Direct2D draw device (e.g. yuzusoft).
    // Must run via wine64: the bundled wine's wow64 layer fails wined3d feature-level
    // checks, causing DrawDeviceD2D.dll to return void → TJS "(void) to Object" error.
    static let kirikiri2 = EngineProfile(
        id: "kirikiri2",
        displayName: "KiriKiri2 (TVP/Direct2D)",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: [],
        requiresWine64: true
    )

    // GIGA ADV: 32-bit D3D9 on wined3d. Text is condensed
    // ＭＳ ゴシック Bold via GGO_GRAY8 — needs synthetic bold to match Windows.
    // narrowProportional is SAFE here: GIGA has no font-resolution recursion in
    // dialogs, so the narrower proportional face fixes clipping without side
    // effects. verified on a GIGA ADV title; the face is
    // now "Melammu PGothic" (same kana, digits condensed) — strictly better for the
    // digit clipping, re-verify on a GIGA ADV title when convenient.
    static let giga = EngineProfile(
        id: "giga",
        displayName: "GIGA ADV",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: [],
        msGothicSynthBold: true,
        narrowProportional: true
    )

    // yaneurao GameSDK (yaneurao publisher titles). 32-bit GDI text
    // (Lib/Graphics.dll) + optional D3D9 presenter (Lib/RenderDX.dll). The settings
    // dialog can crash via game-side wndproc self-subclass recursion regardless of
    // render mode (heap-address-reuse race); the durable fix is the Wine-side
    // SetWindowLong self-reference guard, not this profile. RenderDX exclusion just
    // prefers the stabler DIB renderer.
    // narrowProportional is enabled. CORRECTION (verified on a yaneurao title (verified)
    // on the guard build wine-10.0-30-g513a9def352): the earlier "non-BIZ-UD faces
    // stack-overflow the settings dialog, so this MUST stay false" rule was a
    // PRE-GUARD artifact. The IPAPGothic refreeze it cited was sampled BEFORE the
    // SetWindowLong self-subclass guard landed. On the guarded wine the dialog opens
    // with the substitute face and does NOT freeze (all tabs), and the "255" digit
    // clip is fixed. The freeze was never the font; it was the self-subclass recursion
    // the guard now catches. The face is "Melammu PGothic" (see narrowProportional doc).
    static let yaneurao = EngineProfile(
        id: "yaneurao",
        displayName: "やねうらおGameSDK (かぐや)",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: [],
        narrowProportional: true,
        excludedGameFiles: ["Lib/RenderDX.dll"]
    )

    // CIRCUS (D.C.シリーズ): display/detection stub — no special handling
    // verified yet (DC3RX runs on defaults).
    static let circus = EngineProfile(
        id: "circus",
        displayName: "CIRCUS",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: []
    )

    static let unknown = EngineProfile(
        id: "unknown",
        displayName: "不明",
        requiresDXVK: false,
        requiresLAVFilters: false,
        system32Files: []
    )

    static let all: [EngineProfile] = [.bgi, .bgi32, .kirikiri, .kirikiri2, .catSystem2, .reallive, .artemis, .cmvs, .giga, .circus, .iarsys, .yaneurao, .unknown]

    static func find(_ id: ID) -> EngineProfile {
        all.first { $0.id == id } ?? .unknown
    }
}
