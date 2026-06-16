# Melammu

**[melammu.app](https://melammu.app)** — 動作確認済みタイトル一覧

Wine上でWindows向け美少女ゲームを動かすmacOSランチャーです。インストーラーの`.exe`をドロップするだけで、WinePrefixの構築・フォントとDXVKのインストール・エンジン検出・ライブラリ登録まで自動で完了します。ターミナル操作は不要です。

## 機能

- **インストールウィザード** — インストーラー `.exe` をドロップすると、`~/Library/Application Support/Melammu/Games/` 以下に専用のWine Prefixを作成し、フォントとDXVKをインストールして、ゲームの実行ファイルを選択します
- **エンジン自動検出** — KiriKiri Z・Artemis・BGI・CatSystem2などのエンジンを識別し、必要なDLLオーバーライドと設定を自動で適用します
- **ゲームライブラリ** — カバー画像付きのサイドバー一覧。ゲームごとの起動・設定管理。旧来のラッパー `.app` も読み込みます
- **HUD** — ゲームウィンドウの上に浮かぶオーバーレイ（`⌘⇧H` でトグル）。カメラボタンでScreenCaptureKitによるスクリーンショット撮影。フルスクリーン非対応時は警告を表示します
- **スクリーンショットギャラリー** — ゲームごとのギャラリー表示

## アーキテクチャ

```
Melammu.app/
├── Contents/MacOS/Melammu           (Swift アプリ — このリポジトリ)
└── Contents/Resources/
    └── wine-support/
        ├── wine/                    Melammu Wine fork（Wine 10.0 系譜; 標準ゲーム用）
        │   ├── bin/wine
        │   └── lib/wine/
        ├── wine64/                  互換用 wine64（Wine 7.7; KiriKiri2 TVP/Direct2D用）
        │   ├── bin/wine64
        │   └── lib/wine/
        ├── dxvk/                    DXVK x64 + x32 DLL (D3D9 は d9vk 経由)
        └── system32/                エンジン別 DLL

ゲームデータ:
~/Library/Application Support/Melammu/Games/<タイトル>/prefix/  (ゲームごとのWine Prefix)
```

Swiftアプリは同梱した Wine fork を`Process()`で直接起動し、`WINEPREFIX`を設定してPrefixのライフサイクル全体を管理します。正規のランタイム経路にサードパーティ製ラッパーは含めません。同梱 Wine の出所はマニフェストで別途管理しています。

## エンジン互換性

動作確認済みタイトルとエンジンの一覧は **[melammu.app/compat](https://melammu.app/compat)** を参照してください。

エンジンごとの技術的な調査内容は [Zenn連載](https://zenn.dev/tsukasa_art/articles/mac-eroge-compat-part1) を参照してください。

### KiriKiri Z：フルスクリーンクラッシュからの復帰

KiriKiri ZゲームをWine上でフルスクリーン実行するとクラッシュします。復帰するには、ゲームのPrefix内の `savedata/datasc.ksd` を削除してください（ウィンドウモード設定がリセットされます）。MelammuのHUDにはこの操作を誤って行わないよう警告が表示されます。

## 動作環境

- macOS 26 Tahoe 以降（Apple Silicon）
- Xcode 26（ソースからビルドする場合）
- 画面収録の権限（初回起動時に付与。HUDスクリーンショットに必要）

## ビルドと実行

```bash
open Melammu.xcodeproj
# Xcode でビルド・実行 (⌘R)
```

デバッグビルドはメニューバーに **Melammu [Dev]** と表示されます。

## プロジェクト構成

```
Melammu/
├── MelammuApp.swift
├── ContentView.swift
├── Models/
│   ├── Game.swift
│   ├── EngineProfile.swift
│   └── InstallSession.swift
├── Services/
│   ├── InstallerService.swift    Wine Prefix作成・DXVKインストール・エンジン設定
│   ├── EngineDetector.swift      exeとファイルパターンからエンジン識別
│   ├── GameScanner.swift         ライブラリスキャン（インストール済みゲーム + 旧.appバンドル）
│   ├── GameCaptureService.swift  ScreenCaptureKitによるスクリーンショット
│   └── HUDPanel.swift            フローティングHUDウィンドウ管理
├── ViewModels/
│   ├── LibraryViewModel.swift    ⌘⇧H ホットキー・ゲーム起動・HUDライフサイクル
│   └── InstallViewModel.swift
└── Views/
    ├── LibraryView.swift
    ├── HUDView.swift
    ├── InstallView.swift
    ├── ScreenshotGalleryView.swift
    ├── GameGridItem.swift
    └── GameListItem.swift
```

## ロードマップ

- Apple Developer ID署名 → Gatekeeperなしで配布
- KiriKiri Zフルスクリーンクラッシュ：アプリ内復帰ボタン（`datasc.ksd`削除）
- ゲームごとの設定UI（ウィンドウサイズ・ロケール・カスタム環境変数）
- `hdiutil` によるISO/ディスクイメージのマウント
- 対応エンジンの拡充

## 検証のサポート

体験版があるタイトルを優先的に検証します。体験版がないタイトルの検証依頼は **[melammu.app](https://melammu.app)** をご覧ください。

## ビジョン

日本の美少女ゲームはmacOSで実質的に遊べない状態が続いています。公式サポートなし、App Storeリリースなし、活発にメンテされているラッパーもない。このプロジェクトはその状況を変えるために作りました。目標は、パブリッシャーがApple Silicon向けにカタログを配信する際に、Windowsを必要とせずにバンドルまたはライセンス供与できる、洗練された自己完結型のmacOSアプリです。

タイトルのmacOS対応にご興味のあるパブリッシャー・開発者の方は、お気軽にご連絡ください。

## ライセンス

このSwiftアプリケーション（本リポジトリ）はプロプライエタリです。All rights reserved。  
[wine-wukiyo](https://github.com/tsukasa-art/wine-wukiyo) はLGPL（Wineから継承）。ソースはGitHubで公開しています。
