import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @State private var installVM: InstallViewModel
    @Environment(\.dismiss) private var dismiss

    init(onInstall: @escaping (Game) -> Void) {
        _installVM = State(wrappedValue: InstallViewModel(onInstall: onInstall))
    }

    private var vm: InstallViewModel { installVM }
    private var bindable: Bindable<InstallViewModel> { Bindable(installVM) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            currentScreen
        }
        .frame(width: 480)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    // MARK: - Header

    @State private var showingCancelConfirm = false

    private var header: some View {
        HStack {
            Text("ゲームをインストール")
                .font(.headline)
            Spacer()
            Button {
                if vm.session.isRunning {
                    showingCancelConfirm = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .confirmationDialog("インストールを中止しますか？", isPresented: $showingCancelConfirm, titleVisibility: .visible) {
                Button("中止する", role: .destructive) {
                    vm.cancelInstall()
                    dismiss()
                }
                Button("続ける", role: .cancel) {}
            } message: {
                Text("作成済みのデータは削除されます。")
            }
        }
        .padding()
    }

    // MARK: - Screen routing

    @ViewBuilder
    private var currentScreen: some View {
        switch vm.session.step {
        case .idle:
            if vm.installerURL == nil && vm.gameFolderURL == nil { dropZoneView } else { configView }
        case .choosingExe:
            exePickerView
        case .done:
            doneView
        case .failed(let msg):
            errorView(msg)
        default:
            progressView
        }
    }

    // MARK: - Drop zone

    private var dropZoneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(".exe またはゲームフォルダをドロップ")
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("ファイルを選択…", action: pickFile)
                    .buttonStyle(.bordered)
                Button("フォルダを選択…", action: pickFolder)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - Config form

    private var configView: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent(vm.gameFolderURL != nil ? "ゲームフォルダ" : "インストーラー") {
                    Text(vm.gameFolderURL?.lastPathComponent ?? vm.installerURL?.lastPathComponent ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TextField("ゲーム名", text: bindable.gameName)
                Picker("エンジン", selection: bindable.selectedEngineID) {
                    ForEach(EngineProfile.all) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                if vm.gameFolderURL != nil {
                    LabeledContent("保存先") {
                        HStack(spacing: 8) {
                            Text(vm.storageDisplayName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("変更…", action: pickStorageRoot)
                            if vm.gameDataRootPath != nil {
                                Button("内蔵に戻す") { vm.gameDataRootPath = nil }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button(vm.gameFolderURL != nil ? "コピーして取り込む" : "インストール開始") {
                    Task { await vm.startInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.gameName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 20) {
            if vm.session.step == .copyingGameData {
                ProgressView(value: vm.session.copyProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(vm.session.step.label)
                .foregroundStyle(.secondary)
            if vm.session.step == .copyingGameData {
                Text(vm.session.copyDetail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
            }
            if vm.session.step == .runningInstaller {
                Text("インストーラーを操作してください")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - Exe picker

    private var exePickerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vm.session.candidateExes.isEmpty
                 ? "実行ファイルが見つかりませんでした"
                 : "起動する実行ファイルを選択")
                .font(.headline)
                .padding()

            Divider()

            if vm.session.candidateExes.isEmpty {
                Text("インストール先に .exe が見つかりませんでした。\nゲームを手動で追加するか、インストールをやり直してください。")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.session.candidateExes, id: \.self) { url in
                            exeRow(url)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("選択して続行") {
                    Task { await vm.confirmExe() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.session.selectedExe == nil)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func exeRow(_ url: URL) -> some View {
        let selected = vm.session.selectedExe == url
        return HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .fontWeight(selected ? .semibold : .regular)
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.session.selectedExe = url }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("インストール完了")
                .font(.title3)
            if !vm.session.pathWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("固定のWindowsパスが残っています（書き換えていません）",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.session.pathWarnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 400)
            }
            Button("ライブラリに戻る") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("インストール失敗")
                .font(.title3)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("閉じる") { dismiss() }
                Button("最初からやり直す") { vm.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
    }

    // MARK: - Helpers

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let exeType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exeType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.setInstaller(url)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.setFolder(url)
    }

    private func pickStorageRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "ゲームデータの保存先フォルダを選択（外部ドライブ可）"
        panel.prompt = "この場所に保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.gameDataRootPath = url.path
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        self.vm.setFolder(url)
                    } else if url.pathExtension.lowercased() == "exe" {
                        self.vm.setInstaller(url)
                    }
                }
            }
        }
        return true
    }
}
