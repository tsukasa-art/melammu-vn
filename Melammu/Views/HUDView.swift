import SwiftUI

struct HUDView: View {
    let gameName: String
    let onScreenshot: () -> Void
    let onSaveToGallery: () -> Void
    let onForceQuit: () -> Void
    let onDismiss: () -> Void

    @State private var confirmingQuit = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.85))
                Text("フルスクリーン非対応")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 16)

            Button(action: onScreenshot) {
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("サムネ撮影（ウィンドウを選択）")

            Button(action: onSaveToGallery) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("最後のスナップをギャラリーに保存")

            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 16)

            if confirmingQuit {
                Button(action: onForceQuit) {
                    Text("強制終了")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button(action: { confirmingQuit = false }) {
                    Text("キャンセル")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { confirmingQuit = true }) {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(.plain)
                .help("ゲームを強制終了")

                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 16)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("HUDを閉じる")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.black.opacity(0.65))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }
}
