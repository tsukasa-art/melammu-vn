# Melammu

**[melammu.app](https://melammu.app)** — compatible title database | [日本語版 README](README.ja.md)

Part of **Orrery** — a macOS compatibility layer for Windows visual novels.

A macOS launcher for Japanese visual novels running under Wine. Drop in an installer `.exe`, and Melammu builds the Wine prefix, installs fonts and DXVK, detects the game engine, and adds the title to your library — no terminal required.

## What it does

- **Install wizard** — drop a game installer `.exe` onto Melammu; it creates an isolated Wine prefix under `~/Library/Application Support/Melammu/Games/`, installs fonts and DXVK, and lets you pick the game executable.
- **Engine detection** — identifies the engine (KiriKiriZ, Artemis, BGI, CatSystem2, etc.) and applies the correct DLL overrides and workarounds automatically.
- **Game library** — sidebar list with cover art, per-game launch and settings. Also imports legacy wrapper `.app` bundles.
- **HUD** — floats above the game window (toggle: `⌘⇧H`); camera button captures a screenshot via ScreenCaptureKit. Warns when fullscreen mode is unsupported.
- **Screenshot gallery** — in-app gallery per game.

## Architecture

```
Melammu.app/
├── Contents/MacOS/Melammu           (Swift app — this repo)
└── Contents/Resources/
    └── wine-support/
        ├── wine/                    Melammu Wine fork (Wine 10.0 lineage; standard games)
        │   ├── bin/wine
        │   └── lib/wine/
        ├── wine64/                  compatibility wine64 (Wine 7.7; KiriKiri2 TVP/Direct2D)
        │   ├── bin/wine64
        │   └── lib/wine/
        ├── dxvk/                    DXVK x64 + x32 DLLs (D3D9 via d9vk)
        └── system32/                engine-specific DLLs

Game data:
~/Library/Application Support/Melammu/Games/<Title>/prefix/  (Wine prefix per game)
```

The Swift app drives the bundled Wine fork directly via `Process()`, sets `WINEPREFIX`, and manages the full prefix lifecycle. No third-party wrapper is part of the canonical runtime path. The manifest for the bundled Wine provenance is maintained separately.

## Engine compatibility

For the full list of tested titles and engines, see **[melammu.app/compat](https://melammu.app/compat)**.

For per-engine technical notes, see the [Zenn series](https://zenn.dev/tsukasa_art/articles/mac-eroge-compat-part1).

### KiriKiriZ: fullscreen crash recovery

Running KiriKiriZ games in fullscreen mode crashes under Wine. To recover, delete `savedata/datasc.ksd` inside the game's prefix — this resets the window-mode setting. Melammu's HUD displays a warning to avoid triggering this.

## Requirements

- macOS 26 Tahoe or later (Apple Silicon)
- Xcode 26 (to build from source)
- Screen Recording permission (granted on first launch, required for HUD screenshot)

## Build & run

```bash
open Melammu.xcodeproj
# Build & run in Xcode (⌘R)
```

Debug builds display as **Melammu [Dev]** in the menu bar.

## Project structure

```
Melammu/
├── MelammuApp.swift
├── ContentView.swift
├── Models/
│   ├── Game.swift
│   ├── EngineProfile.swift
│   └── InstallSession.swift
├── Services/
│   ├── InstallerService.swift    Wine prefix creation, DXVK install, engine setup
│   ├── EngineDetector.swift      engine identification from exe/file patterns
│   ├── GameScanner.swift         library scan (installed games + legacy .app bundles)
│   ├── GameCaptureService.swift  ScreenCaptureKit screenshot capture
│   └── HUDPanel.swift            floating HUD window management
├── ViewModels/
│   ├── LibraryViewModel.swift    ⌘⇧H hotkey, game launch, HUD lifecycle
│   └── InstallViewModel.swift
└── Views/
    ├── LibraryView.swift
    ├── HUDView.swift
    ├── InstallView.swift
    ├── ScreenshotGalleryView.swift
    ├── GameGridItem.swift
    └── GameListItem.swift
```

## Roadmap

- Apple Developer ID signing → Gatekeeper-clean distribution
- KiriKiriZ fullscreen crash: in-app recovery button (delete `datasc.ksd`)
- Per-game configuration UI (window size, locale, custom env vars)
- ISO / disc image mounting via `hdiutil`
- Wider engine coverage

## Support verification

Trial versions are tested first. For titles without a trial, see **[melammu.app](https://melammu.app)** for how to request testing.

## Vision

Japanese visual novels remain effectively inaccessible on macOS — no official support, no App Store releases, no community-maintained wrapper with active development. This project exists to change that. The goal is a polished, self-contained macOS app that any publisher could bundle or license to ship their catalog on Apple Silicon without requiring Windows.

If you are a publisher or developer interested in macOS compatibility for your titles, feel free to reach out.

## License

The Swift application (this repository) is proprietary — all rights reserved.  
[swingby-wine](https://github.com/tsukasa-art/swingby-wine) is LGPL (inherited from Wine). Source is available on GitHub.
