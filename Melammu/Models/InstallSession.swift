import Foundation

enum InstallStep: Equatable {
    case idle
    case copyingGameData
    case creatingPrefix
    case installingFonts
    case installingDXVK
    case runningInstaller
    case detectingExe
    case choosingExe      // paused: user must pick from candidateExes
    case applyingProfile
    case done
    case failed(String)

    var label: String {
        switch self {
        case .idle:             return ""
        case .copyingGameData:  return "ゲームデータをコピーしています…"
        case .creatingPrefix:   return "Wine 環境を初期化しています…"
        case .installingFonts:  return "フォントをインストールしています…"
        case .installingDXVK:   return "DXVK をセットアップしています…"
        case .runningInstaller: return "インストーラーを実行しています…"
        case .detectingExe:     return "実行ファイルを検索しています…"
        case .choosingExe:      return "実行ファイルを選択"
        case .applyingProfile:  return "エンジン設定を適用しています…"
        case .done:             return "インストール完了"
        case .failed(let msg):  return "エラー: \(msg)"
        }
    }

    var isTerminal: Bool {
        switch self { case .done, .failed: true; default: false }
    }
}

@Observable
final class InstallSession {
    var step: InstallStep = .idle
    var candidateExes: [URL] = []
    var selectedExe: URL?
    // Full-copy import progress (0...1) and the file being copied
    var copyProgress: Double = 0
    var copyDetail: String = ""
    // Absolute Windows paths found in copied ini/inf files that were NOT
    // auto-rewritten — shown on the done screen for the user to judge
    var pathWarnings: [String] = []

    var isRunning: Bool {
        !step.isTerminal && step != .idle && step != .choosingExe
    }
}
