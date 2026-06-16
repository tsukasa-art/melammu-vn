import SwiftUI
import AppKit

struct ScreenshotThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.15))
                    .aspectRatio(16 / 9, contentMode: .fit)
            }

            Text(label)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(.bottom, 6)
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onAppear { image = NSImage(contentsOf: url) }
        .help("クリックしてPreviewで開く")
    }

    private var label: String {
        let name = url.deletingPathExtension().lastPathComponent
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: name) else {
            return name.replacingOccurrences(of: "T", with: " ")
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/M/d HH:mm"
        return fmt.string(from: date)
    }
}
