import SwiftUI
import AppKit

/// Runtime badge. Visually distinguishes (B) native (direct launch via bundled wine) from
/// (A) Sikarugir legacy wrapper (standalone .app launch). Useful when both entries for the
/// same title appear side-by-side in the library.
struct RuntimeBadge: View {
    let isLegacy: Bool
    var prominent = false

    private var tint: Color { isLegacy ? Color(nsColor: .systemGray) : .blue }

    var body: some View {
        Label(isLegacy ? "Sikarugir" : "ネイティブ",
              systemImage: isLegacy ? "macwindow" : "internaldrive")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize()   // バッジは省略表示させない（行名側を truncate させる）
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .background(
                Capsule().fill(prominent
                               ? AnyShapeStyle(tint)
                               : AnyShapeStyle(tint.opacity(0.18)))
            )
    }
}

/// Placeholder color palette — pastel/pale tones.
/// One color is deterministically assigned from the game name;
/// the user can cycle through them via right-click (Game.placeholderColorIndex).
enum PlaceholderPalette {
    /// Hues (0...1) spread around the color wheel, biased toward pastels.
    static let hues: [Double] = [0.95, 0.04, 0.09, 0.14, 0.30, 0.45, 0.52, 0.60, 0.70, 0.80, 0.88]

    private static func wrap(_ i: Int) -> Int { ((i % hues.count) + hues.count) % hues.count }

    static func defaultIndex(for name: String) -> Int {
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return seed % hues.count
    }

    /// Light background color (pale tone).
    static func background(_ i: Int) -> Color {
        Color(hue: hues[wrap(i)], saturation: 0.36, brightness: 0.88)
    }

    /// Slightly darker foreground in the same hue family (for icon contrast).
    static func foreground(_ i: Int) -> Color {
        Color(hue: hues[wrap(i)], saturation: 0.55, brightness: 0.52)
    }
}

/// Cover placeholder shown when no custom cover image is set.
/// Displays a pastel background with a gamepad icon instead of a generic document icon.
/// Color is controlled by Game.placeholderColorIndex.
struct CoverPlaceholder: View {
    let game: Game

    private var index: Int {
        game.placeholderColorIndex ?? PlaceholderPalette.defaultIndex(for: game.name)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PlaceholderPalette.background(index)
                Image(systemName: "gamecontroller.fill")
                    .resizable().scaledToFit()
                    .frame(width: min(geo.size.width * 0.4, 72))
                    .foregroundStyle(PlaceholderPalette.foreground(index))
            }
        }
    }
}

struct GameSidebarRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 10) {
            coverImage
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(game.name)
                    .font(.body)
                    .lineLimit(1)
                if let engineID = game.engineID {
                    Text(EngineProfile.find(engineID).displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            RuntimeBadge(isLegacy: game.isLegacy)
        }
        .padding(.vertical, 2)
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
