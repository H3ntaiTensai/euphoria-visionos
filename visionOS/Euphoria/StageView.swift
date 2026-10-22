import ImageIO
import SwiftUI
import UIKit

/// Decoded artwork, by original name.
final class ArtLibrary: @unchecked Sendable {
    static let shared = ArtLibrary()
    private let cache = NSCache<NSString, UIImage>()
    private let sizes = NSCache<NSString, NSValue>()

    init() { cache.countLimit = 80 }

    /// One frame of an original sprite strip (the "_bt3" / "_bt4" button art: frames side by side).
    func frame(_ name: String, _ index: Int, of count: Int) -> UIImage? {
        let key = "\(name.lowercased())#\(index)/\(count)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let strip = image(name), let cg = strip.cgImage else { return nil }
        let width = cg.width / count
        guard let part = cg.cropping(to: CGRect(x: width * index, y: 0, width: width, height: cg.height)) else { return nil }
        let image = UIImage(cgImage: part)
        cache.setObject(image, forKey: key)
        return image
    }

    /// A picture's size in pixels, read from the file's header without decoding it.
    func pixelSize(_ name: String) -> CGSize? {
        let key = name.lowercased() as NSString
        if let size = sizes.object(forKey: key) { return size.cgSizeValue }
        guard let url = StoryLibrary.shared.assetURL(name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: width, height: height)
        sizes.setObject(NSValue(cgSize: size), forKey: key)
        return size
    }

    func image(_ name: String) -> UIImage? {
        let key = name.lowercased() as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = StoryLibrary.shared.assetURL(name), let file = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        // Decoding ahead of drawing fails for palette PNGs (the solid color plates).
        let image = file.preparingForDisplay() ?? file
        cache.setObject(image, forKey: key)
        return image
    }
}

extension EnvironmentValues {
    /// Window width relative to the 1440-point design width; overlays scale with it.
    @Entry var uiScale: CGFloat = 1
    /// True while a panel covers the stage: floating sprites drop back to the window.
    @Entry var stageFlattened = false
}

/// The original 1024×768 screen, drawn natively: the background in the window,
/// characters and cut-ins floating in front of it.
struct StageView: View {
    /// Matches the system window's corner rounding.
    static let cornerRadius: CGFloat = 46

    let stage: Stage
    /// Off while skipping: pictures flash by too fast to be worth generating.
    var spatial = true
    var settings = Settings.shared
    @Environment(\.stageFlattened) private var flattened
    @State private var animating = false
    /// Pictures showing as spatial scenes; what is under them is cleared (see SpatialShowingKey).
    @State private var spatialShowing: Set<String> = []

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Screen.size.width
            TimelineView(.animation(minimumInterval: nil, paused: !animating)) { _ in
                let time = Date.timeIntervalSinceReferenceDate
                let sprites = stage.ordered
                // Backgrounds and event CGs become spatial scenes behind the window: the topmost
                // full-screen still picture, as everything under it is covered.
                let sceneIndex = spatial && settings.spatialScenes
                    ? sprites.lastIndex { $0.isStillPicture(at: time) } : nil
                // The lowest layer showing as a spatial scene: nothing under it may be opaque.
                let spatialFloor = spatialShowing.isEmpty ? nil
                    : sprites.firstIndex { $0.image.map(spatialShowing.contains) ?? false }
                ZStack(alignment: .topLeading) {
                    Color.black.clipShape(.rect(cornerRadius: Self.cornerRadius))
                        .opacity(spatialFloor == nil ? 1 : 0)
                    ForEach(Array(sprites.enumerated()), id: \.element.id) { index, sprite in
                        // The scene sits at the window's surface, wherever its layer would float.
                        let depth = index == sceneIndex ? 0 : depth(of: sprite, index: index, count: sprites.count)
                        Group {
                            if index == sceneIndex, let image = sprite.image {
                                // Event CGs change at once, as in the CG gallery.
                                SpatialPicture(name: image, tint: sprite.tint,
                                               fades: !(image as NSString).lastPathComponent.lowercased().hasPrefix("ev_"))
                            } else {
                                SpriteView(sprite: sprite, time: time, scale: scale)
                            }
                        }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            // Clip before moving forward: layers in front of the window aren't clipped by it.
                            .clipShape(.rect(cornerRadius: Self.cornerRadius))
                            .inFrontOfWindow(by: depth)
                            .opacity(spatialFloor.map { index < $0 } == true ? 0 : 1)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: stage) {
            if stage.hasSway {
                animating = true
                return
            }
            let remaining = stage.busyUntil - Date.timeIntervalSinceReferenceDate
            guard remaining > 0 else {
                animating = false
                return
            }
            animating = true
            try? await Task.sleep(for: .seconds(remaining + 0.05))
            if !Task.isCancelled { animating = false }
        }
        .onPreferenceChange(SpatialShowingKey.self) { spatialShowing = $0 }
        .accessibilityHidden(true)
    }

    /// Backgrounds sit in the window; characters float in front of them; full-screen
    /// covers (fades, flashes, an incoming background) float in front of everything.
    private func depth(of sprite: Sprite, index: Int, count: Int) -> CGFloat {
        guard !flattened else { return 0 }
        let step = settings.characterDepth * 30
        switch sprite.id {
        case "BG", "EV_W": return 0
        case "BGF", "LNO_FD", "MAC_FLASH": return Self.coverDepth(settings)
        default: return step * (1 + CGFloat(index) / CGFloat(max(count, 1)))
        }
    }

    /// Where full-screen covers float: in front of every character.
    @MainActor static func coverDepth(_ settings: Settings) -> CGFloat {
        settings.characterDepth * 90 + 6
    }

    /// Where the interface (dialogue, choices, the heroine selection) floats: in front of the whole stage.
    @MainActor static func interfaceDepth(_ settings: Settings) -> CGFloat {
        coverDepth(settings) + 16
    }

    /// A layer moved toward the viewer looks larger in perspective and would spill
    /// past the window's edge; shrink it so its outline stays on the window as seen
    /// from a typical viewing distance (about 1.5 m, in points).
    static func perspectiveScale(forDepth depth: CGFloat) -> CGFloat {
        let viewingDistance: CGFloat = 2000
        return viewingDistance / (viewingDistance + depth)
    }
}

extension View {
    /// Applies the original's camera tint (sepia flashbacks and the like).
    @ViewBuilder func tinted(_ tint: Tint?) -> some View {
        if let tint {
            colorEffect(ShaderLibrary.tint(.float(Double(tint.saturation) / 128),
                                           .float(tint.red), .float(tint.green), .float(tint.blue)))
        } else {
            self
        }
    }

    /// Floats a window-sized layer `depth` points toward the viewer without growing past the window.
    func inFrontOfWindow(by depth: CGFloat) -> some View {
        scaleEffect(StageView.perspectiveScale(forDepth: depth)).offset(z: depth)
    }
}

private struct SpriteView: View {
    let sprite: Sprite
    let time: TimeInterval
    let scale: CGFloat

    var body: some View {
        let zoom = Screen.baseDepth / max(sprite.z.value(at: time), 1)
        let quake = sprite.quake?.offset(at: time) ?? .zero
        let sway = sprite.sway?.offset(at: time) ?? .zero
        let shake = CGSize(width: quake.width + sway.width, height: quake.height + sway.height)
        let x = sprite.x.value(at: time) * zoom + shake.width
        let y = sprite.y.value(at: time) * zoom + shake.height
        let fade = sprite.fade.value(at: time)
        let opacity = min(max(sprite.alpha.value(at: time) / 256, 0), 1)
        // With a rule, a fade in or out is shaped by the mask instead of a uniform dissolve.
        let ruleFade = sprite.rule != nil && sprite.alpha.duration > 0 && time < sprite.alpha.end
        ZStack {
            if let previous = sprite.previous, fade < 1 {
                ArtImage(name: previous, scale: scale, tint: sprite.tint)
                    .opacity(isOpaque || sprite.rule != nil ? 1 : 1 - fade)
            }
            if let image = sprite.image {
                if sprite.previous != nil {
                    ArtImage(name: image, scale: scale, tint: sprite.tint, rule: sprite.rule, progress: fade)
                        .opacity(sprite.rule == nil ? fade : 1)
                } else {
                    ArtImage(name: image, scale: scale, tint: sprite.tint, rule: ruleFade ? sprite.rule : nil, progress: opacity)
                }
            }
        }
        .scaleEffect(zoom)
        // The original's blur amount; 100 is a heavy blur.
        .blur(radius: max(sprite.blur?.value(at: time) ?? 0, 0) * 0.12 * scale)
        .position(x: (Screen.size.width / 2 + x) * scale, y: (Screen.size.height / 2 + y) * scale)
        .opacity(ruleFade ? 1 : opacity)
    }

    /// Full-screen art crossfades over the old picture instead of dipping through it.
    private var isOpaque: Bool { ["BG", "BGF", "LNO_FD"].contains(sprite.id) }
}

private struct ArtImage: View {
    let name: String
    let scale: CGFloat
    var tint: Tint?
    var rule: String?
    var progress: Double = 1

    var body: some View {
        if let image = ArtLibrary.shared.image(name) {
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let picture = Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                .tinted(tint)
            if let rule, progress < 1, let mask = ArtLibrary.shared.image(rule) {
                picture.colorEffect(ShaderLibrary.ruleReveal(.float2(size), .image(Image(uiImage: mask)),
                                                             .float(progress), .float(0.12)))
            } else {
                picture
            }
        }
    }
}
