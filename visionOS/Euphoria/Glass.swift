import SwiftUI

/// The light glass the menus share. Its namespace holds the ink for text and controls.
enum RoomGlass {
    /// Text and controls on the light glass: dark, as on light Liquid Glass.
    static let ink = Color(white: 0.12)
}

/// The original bonus screens' white room, faded into the glass so the panels keep
/// some of the original's look.
struct RoomGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S

    /// The room inside the original's frame (the Music Replay backdrop, which has
    /// nothing drawn over it), without the header bar and the bottom strip.
    @MainActor static var room: UIImage? {
        if let cached = RoomGlassCache.image { return cached }
        guard let cg = ArtLibrary.shared.image("sys/extra/bgmmode/back")?.cgImage,
              let crop = cg.cropping(to: CGRect(x: 37, y: 68, width: 950, height: 670)) else { return nil }
        RoomGlassCache.image = UIImage(cgImage: crop)
        return RoomGlassCache.image
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(RoomGlass.ink)
            .tint(RoomGlass.ink)
            .background {
                if let room = Self.room {
                    Image(uiImage: room).resizable().scaledToFill()
                        // Low opacity keeps it glass; extra contrast lets the room's
                        // faint lines and red lights read through it.
                        .contrast(1.8)
                        .opacity(0.42)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .glassBackgroundEffect(in: shape)
    }
}

@MainActor private enum RoomGlassCache {
    static var image: UIImage?
}

extension View {
    func roomGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(RoomGlassModifier(shape: shape))
    }
}

