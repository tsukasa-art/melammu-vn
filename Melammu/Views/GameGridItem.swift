import SwiftUI
import AppKit

enum ScreenshotTab { case snap, gallery }

struct GameDetailView: View {
    let game: Game
    @Environment(LibraryViewModel.self) private var vm
    @State private var screenshots: [URL] = []
    @State private var selectedTab: ScreenshotTab = .snap
    @State private var snapImage: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                screenshotsSection
            }
        }
        .navigationTitle(game.name)
        .onAppear {
            screenshots = vm.screenshots(for: game)
            reloadSnap()
        }
        .onChange(of: game) {
            screenshots = vm.screenshots(for: game)
            reloadSnap()
        }
        .onChange(of: vm.screenshotToken) { screenshots = vm.screenshots(for: game) }
        .onChange(of: vm.snapToken) { reloadSnap() }
    }

    private func reloadSnap() {
        snapImage = NSImage(contentsOfFile: LibraryViewModel.latestSnapPNG)
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // 背景: カスタムバナー or カバーのぼかし
            bannerBackground
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipped()

            // グラデーションオーバーレイ（上下を締める）
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.35), location: 0.0),
                    .init(color: .black.opacity(0.0),  location: 0.35),
                    .init(color: .black.opacity(0.0),  location: 0.55),
                    .init(color: .black.opacity(0.6),  location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 300)

            // コンテンツ
            HStack(alignment: .bottom, spacing: 20) {
                coverImage
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name)
                        .font(.title2).bold()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .shadow(color: .black.opacity(0.5), radius: 2)

                    HStack(spacing: 8) {
                        if let engineID = game.engineID {
                            Label(EngineProfile.find(engineID).displayName, systemImage: "cpu")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.7), radius: 4)
                        }
                        RuntimeBadge(isLegacy: game.isLegacy, prominent: true)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }

                    Text(game.dateAdded.formatted(.dateTime.year().month().day().locale(Locale(identifier: "ja_JP"))))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.8), radius: 4)

                    if let folder = vm.gameStorageURL(game) {
                        Button(action: { vm.revealGameFolder(game) }) {
                            Label((folder.path as NSString).abbreviatingWithTildeInPath,
                                  systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("保存フォルダを Finder で開く")
                        .shadow(color: .black.opacity(0.8), radius: 4)
                    }

                    HStack(spacing: 10) {
                        let isThisRunning = vm.isGameRunning && vm.lastLaunchedGame?.id == game.id
                        Button(action: { isThisRunning ? vm.forceQuit() : vm.launch(game) }) {
                            Label(isThisRunning ? "停止" : "起動",
                                  systemImage: isThisRunning ? "stop.fill" : "play.fill")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isThisRunning ? .red : .accentColor)
                        .controlSize(.large)
                        .shadow(color: .black.opacity(0.4), radius: 4)

                        Button(action: { vm.setCover(for: game) }) {
                            Label(game.customCoverPath != nil ? "カバー変更" : "カバー画像", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)

                        Button(action: { vm.setBanner(for: game) }) {
                            Label(game.customBannerPath != nil ? "背景変更" : "背景画像", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var bannerBackground: some View {
        if let path = game.customBannerPath, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            coverImage
                .scaleEffect(1.15)
                .blur(radius: 24)
                .allowsHitTesting(false)
        }
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("サムネ").tag(ScreenshotTab.snap)
                    Text("ギャラリー (\(screenshots.count))").tag(ScreenshotTab.gallery)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if selectedTab == .snap {
                    Button("撮影（⌥⇧S）") {
                        vm.lastLaunchedGame = game
                        vm.takeSnap(for: game)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("ギャラリーに保存") { vm.saveScreenshotToGallery(for: game) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(snapImage == nil)
                } else {
                    Button("Finderで開く") { vm.revealScreenshots(for: game) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            switch selectedTab {
            case .snap:
                snapTabContent
            case .gallery:
                galleryTabContent
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var snapTabContent: some View {
        if let img = snapImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
        } else {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "camera")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("サムネスナップがありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("HUDのカメラボタンかメニューから撮影してください")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(40)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var galleryTabContent: some View {
        if screenshots.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("保存済みスクリーンショットがありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("HUDの「↓」ボタンでサムネをギャラリーに保存できます")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(40)
                Spacer()
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 10)],
                spacing: 10
            ) {
                ForEach(screenshots, id: \.self) { url in
                    ScreenshotThumbnail(url: url)
                }
            }
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let path = game.customCoverPath, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if !game.wrapperPath.isEmpty {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.wrapperPath))
                .resizable().aspectRatio(contentMode: .fill)
        } else {
            CoverPlaceholder(game: game)
        }
    }
}
