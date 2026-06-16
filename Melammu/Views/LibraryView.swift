import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Bindable var vm: LibraryViewModel
    @Binding var selectedGame: Game?
    @State private var showInstall = false
    @State private var gameToDelete: Game?
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            ForEach(vm.games) { game in
                GameSidebarRow(game: game)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedGame?.id == game.id
                                  ? Color.accentColor.opacity(0.25)
                                  : Color.clear)
                            .padding(.horizontal, 4)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedGame = game }
                    .contextMenu { contextMenu(for: game) }
            }
        }
        .navigationTitle("Melammu")
        .overlay {
            if let status = vm.migrationStatus {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status).font(.callout).multilineTextAlignment(.center)
                        Text("元の Sikarugir 版はそのまま残ります")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)   // 移行中も右クリックで次々キューに積めるよう透過
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItem {
                Button { showInstall = true } label: {
                    Image(systemName: "plus")
                }
                .help("ゲームをインストール")
            }
            ToolbarItem {
                Button(action: vm.refreshLibrary) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("更新：新規ゲームをスキャン＋未取り込みを管理フォルダへ移行")
            }
        }
        .sheet(isPresented: $showInstall) {
            InstallView { game in
                vm.install(game)
            }
        }
        .confirmationDialog(
            gameToDelete.map { "「\($0.name)」を\($0.isLegacy ? "登録解除" : "削除")しますか？" } ?? "",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: gameToDelete
        ) { game in
            Button(game.isLegacy ? "登録解除" : "完全に削除", role: .destructive) {
                vm.delete(game)
                if selectedGame?.id == game.id { selectedGame = nil }
                gameToDelete = nil
            }
            Button("キャンセル", role: .cancel) { gameToDelete = nil }
        } message: { game in
            Text(game.isLegacy
                 ? "ライブラリから登録解除します（.app ラッパーはディスクに残ります）。"
                 : "ゲームデータ・Wine環境・セーブデータをディスクから完全に削除します。元に戻せません。")
        }
        .overlay {
            if vm.games.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("↑ スキャンして追加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in vm.add(url: url) }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func contextMenu(for game: Game) -> some View {
        if vm.isGameRunning && vm.lastLaunchedGame?.id == game.id {
            Button("停止", role: .destructive) { vm.forceQuit() }
        } else {
            Button("起動") { vm.launch(game) }
        }
        Divider()
        Button("サムネ撮影（⌥⇧S）") { vm.takeSnap(for: game) }
        Divider()
        Button("保存フォルダを開く") { vm.revealGameFolder(game) }
        if game.engineProfile.requiresDXVK {
            Divider()
            Menu("ウィンドウ表示") {
                Button {
                    vm.setDisplayMode(.large, for: game)
                } label: {
                    Label("大きく（通常・推奨）",
                          systemImage: game.resolvedDisplayMode == .large ? "checkmark" : "")
                }
                Button {
                    vm.setDisplayMode(.crisp, for: game)
                } label: {
                    Label("くっきり（小さめ・高精細）",
                          systemImage: game.resolvedDisplayMode == .crisp ? "checkmark" : "")
                }
            }
        }
        if game.isLegacy {
            Divider()
            Button("ネイティブに移行…") { vm.migrateToNative(game) }
        }
        Divider()
        Button("カバー画像を設定...") { vm.setCover(for: game) }
        if game.customCoverPath == nil && game.wrapperPath.isEmpty {
            Button("プレースホルダー色を変更") { vm.cyclePlaceholderColor(for: game) }
        }
        Divider()
        Button(game.isLegacy ? "登録解除…" : "削除…", role: .destructive) {
            gameToDelete = game
            showDeleteConfirm = true
        }
        .disabled(vm.isGameRunning && vm.lastLaunchedGame?.id == game.id)
    }
}
