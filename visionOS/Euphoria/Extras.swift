import AVFoundation
import SwiftUI

/// The opening and ending movies, drawn over the stage. A tap skips.
struct MoviePlayerView: UIViewRepresentable {
    let url: URL
    let finished: () -> Void
    var settings = Settings.shared

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVPlayer(url: url)
        player.volume = settings.muted ? 0 : Float(settings.musicVolume)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.observe(player, finished: finished)
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func observe(_ player: AVPlayer, finished: @escaping () -> Void) {
            token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                           object: player.currentItem, queue: .main) { _ in finished() }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The CG gallery: the original's sets, each opening its unlocked pictures.
struct GalleryPanel: View {
    @Binding var viewing: [String]?
    private let progress = Progress.shared
    private let sets = StoryLibrary.shared.index.gallery
    @Environment(\.uiScale) private var scale

    var body: some View {
        let seen = progress.seenCG
        let unlocked = sets.filter { set in set.pictures.contains(where: seen.contains) }.count
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text("\(unlocked) of \(sets.count) unlocked")
                .font(.system(size: 20 * scale))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14 * scale), count: 4),
                          spacing: 14 * scale) {
                    ForEach(sets) { set in
                        let pictures = set.pictures.filter(seen.contains)
                        ThumbnailButton(art: "thumb_cg/\(set.thumb)", locked: pictures.isEmpty,
                                        caption: pictures.isEmpty ? nil : "\(pictures.count)/\(set.pictures.count)") {
                            viewing = pictures
                        }
                    }
                }
            }
        }
    }
}

/// The scene replay list.
struct ReplayPanel: View {
    let engine: StoryEngine
    let close: () -> Void
    private let progress = Progress.shared
    private let replays = StoryLibrary.shared.index.replays
    @Environment(\.uiScale) private var scale

    var body: some View {
        let unlocked = progress.replays
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text("\(replays.filter { unlocked.contains($0.label) }.count) of \(replays.count) unlocked")
                .font(.system(size: 20 * scale))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14 * scale), count: 4),
                          spacing: 14 * scale) {
                    ForEach(replays) { replay in
                        ThumbnailButton(art: "thumb_rp/\(replay.thumb)", locked: !unlocked.contains(replay.label),
                                        caption: nil) {
                            close()
                            engine.startReplay(replay.label)
                        }
                    }
                }
            }
        }
    }
}

private struct ThumbnailButton: View {
    let art: String
    let locked: Bool
    let caption: String?
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                if !locked, let image = ArtLibrary.shared.image(art) {
                    Image(uiImage: image).resizable().aspectRatio(4 / 3, contentMode: .fill)
                } else {
                    Color.black.opacity(0.35)
                        .overlay {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 26 * scale))
                                .foregroundStyle(.tertiary)
                        }
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 3 * scale)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(8 * scale)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14 * scale))
            .contentShape(.hoverEffect, .rect(cornerRadius: 14 * scale))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(locked ? "Locked" : "Open")
    }
}

/// A gallery set's pictures, full window. Tap for the next; past the last closes.
struct PictureViewer: View {
    let pictures: [String]
    let close: () -> Void
    @State private var index = 0
    @Environment(\.uiScale) private var scale

    var body: some View {
        ZStack {
            Color.black
            if index < pictures.count, let image = ArtLibrary.shared.image(pictures[index]) {
                if SpatialSceneLibrary.isEligible(pictures[index]) {
                    // Screen-shaped event CGs open as spatial scenes.
                    SpatialPicture(name: pictures[index])
                        .id(index)
                        .transition(.opacity)
                } else {
                    // Tall and wide pictures scroll, as in the original's viewer.
                    ScrollView(image.size.width / image.size.height > 1.4 ? .horizontal : .vertical) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: fit(image) ? .fit : .fill)
                    }
                    .scrollIndicators(.hidden)
                    .id(index)
                    .transition(.opacity)
                }
            }
        }
        .clipShape(.rect(cornerRadius: StageView.cornerRadius))
        .contentShape(.rect)
        .onTapGesture {
            if index + 1 < pictures.count { index += 1 } else { close() }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12 * scale) {
                Text("\(index + 1) / \(pictures.count)")
                    .font(.system(size: 18 * scale, weight: .semibold))
                    .monospacedDigit()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 18 * scale, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 10 * scale)
            .glassBackgroundEffect(in: .capsule)
            .padding(26 * scale)
        }
        .animation(.easeInOut(duration: 0.3), value: index)
        .onChange(of: index, initial: true) { _, index in
            // Have the next picture's scene ready by the time it is shown.
            let next = pictures.dropFirst(index + 1).prefix(1).filter(SpatialSceneLibrary.isEligible)
            SpatialSceneLibrary.shared.prefetch(next.compactMap(StoryLibrary.shared.assetURL))
        }
        .accessibilityAction(named: "Next") {
            if index + 1 < pictures.count { index += 1 }
        }
    }

    /// Screen-shaped pictures fit; panoramas and tall pictures fill one axis and scroll.
    private func fit(_ image: UIImage) -> Bool {
        let aspect = image.size.width / image.size.height
        return aspect > 1.2 && aspect < 1.4
    }
}

/// A button made of the original's art files: "<base>_off", highlighted with
/// "<base>_over" while looked at, "<base>_on" while pressed, "<base>_na" when unavailable.
struct ArtButton: View {
    let base: String
    let label: String
    var enabled = true
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        let library = ArtLibrary.shared
        if let image = library.image("\(base)_\(enabled ? "off" : "na")") ?? library.image("\(base)_off") {
            Button(action: action) {
                Image(uiImage: image).resizable()
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .opacity(enabled || library.image("\(base)_na") != nil ? 1 : 0.4)
                    .overlay {
                        if enabled, let over = library.image("\(base)_over") {
                            Image(uiImage: over).resizable()
                                .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
                        }
                    }
                    // A taller target than thin text art, for eyes and fingers.
                    .padding(.vertical, 10 * scale)
                    .contentShape(.rect)
                    .padding(.vertical, -10 * scale)
            }
            .buttonStyle(PressedArtStyle(pressed: library.image("\(base)_on")))
            .disabled(!enabled)
            .accessibilityLabel(label)
        }
    }
}

/// A button drawn from one of the original's sprite strips ("_bt3" / "_bt4"): frame 0
/// at rest, frame 1 while looked at, frame 2 while pressed or selected.
struct StripButton: View {
    let art: String
    let frames: Int
    let label: String
    var selected = false
    var enabled = true
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        let library = ArtLibrary.shared
        if let rest = library.frame(art, selected ? 2 : 0, of: frames) {
            Button(action: action) {
                Image(uiImage: rest).resizable()
                    .frame(width: rest.size.width * scale, height: rest.size.height * scale)
                    .opacity(enabled ? 1 : 0.35)
                    .overlay {
                        if enabled, !selected, let over = library.frame(art, 1, of: frames) {
                            Image(uiImage: over).resizable()
                                .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(PressedArtStyle(pressed: library.frame(art, 2, of: frames)))
            .disabled(!enabled)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Shows the original's pressed art while a button is held.
struct PressedArtStyle: ButtonStyle {
    let pressed: UIImage?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed, let pressed {
                    Image(uiImage: pressed).resizable()
                }
            }
    }
}

/// The original's bonus screens: their backdrop, the tab bar along the top, and a
/// Back button, all at the original's positions on the 1024×768 screen.
private struct BonusScreen<Content: View>: View {
    let backdrop: String
    let current: Panel
    let back: String
    let backFrames: Int
    let open: (Panel) -> Void
    let close: () -> Void
    @ViewBuilder let content: (CGFloat) -> Content

    private static var tabs: [(art: String, panel: Panel, x: CGFloat, label: String)] {
        [("cgmode", .gallery, 37, "CG Gallery"), ("rpmode", .replays, 258, "Scene Replay"),
         ("bgmmode", .music, 447, "Music Replay"), ("staffmode", .staff, 629, "Staff Comments")]
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Screen.size.width
            ZStack(alignment: .topLeading) {
                if let image = ArtLibrary.shared.image(backdrop) {
                    Image(uiImage: image).resizable()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                ForEach(Self.tabs, id: \.art) { tab in
                    StripButton(art: "sys/extra/btn_tab_\(tab.art)_bt3", frames: 3, label: tab.label,
                                selected: tab.panel == current, scale: scale) {
                        if tab.panel != current { open(tab.panel) }
                    }
                    .offset(x: tab.x * scale, y: 34 * scale)
                }
                Group {
                    if backFrames > 0 {
                        StripButton(art: back, frames: backFrames, label: "Back", scale: scale, action: close)
                    } else {
                        ArtButton(base: back, label: "Back", scale: scale, action: close)
                    }
                }
                .offset(x: 848 * scale, y: 8 * scale)
                content(scale)
            }
        }
        .clipShape(.rect(cornerRadius: StageView.cornerRadius))
    }
}

/// Music Replay: the soundtrack, two columns of the original's track art.
struct MusicRoom: View {
    let engine: StoryEngine
    let open: (Panel) -> Void
    let close: () -> Void
    @State private var playing: String?
    private let tracks = StoryLibrary.shared.index.music
    private let progress = Progress.shared

    var body: some View {
        BonusScreen(backdrop: "sys/extra/bgmmode/back", current: .music, back: "sys/extra/bgmmode/btn_back_bt3",
                    backFrames: 3, open: open, close: close) { scale in
            ForEach(Array(tracks.enumerated()), id: \.element) { index, track in
                let heard = progress.tracks.contains(track)
                // Tracks 1–10 at x 51, 11–20 at x 521; rows 46 apart from y 92 (ES.BGMMODE.BTDEF).
                StripButton(art: String(format: "sys/extra/bgmmode/btn_bgm%02d_bt4", index + 1), frames: 4,
                            label: heard ? "Track \(index + 1)" : "Track \(index + 1), locked",
                            selected: playing == track, enabled: heard, scale: scale) {
                    toggle(track)
                }
                .offset(x: (index < 10 ? 51 : 521) * scale, y: (92 + 46 * CGFloat(index % 10) - (index == 0 ? 1 : 0)) * scale)
            }
        }
        .onDisappear { engine.audio.stop(channel: 1, fadeMs: 500) }
    }

    private func toggle(_ track: String) {
        if playing == track {
            engine.audio.stop(channel: 1, fadeMs: 500)
            playing = nil
        } else {
            engine.audio.play(channel: 1, file: track, fadeMs: 300, volume: -1, loop: -1)
            playing = track
        }
    }
}

/// Staff Comments: the original's portrait buttons, three columns of six.
struct StaffRoom: View {
    let engine: StoryEngine
    let open: (Panel) -> Void
    let close: () -> Void
    private let labels = StoryLibrary.shared.index.staff
    private let progress = Progress.shared

    var body: some View {
        BonusScreen(backdrop: "sys/extra/staffmode/back", current: .staff, back: "sys/extra/staffmode/btn_back",
                    backFrames: 0, open: open, close: close) { scale in
            ForEach(Array(labels.enumerated()), id: \.element) { index, label in
                // The original shows only unlocked comments, at x 46 + 318·column, y 70 + 62·row.
                if progress.staffUnlocked(index + 1) {
                    ArtButton(base: String(format: "sys/extra/staffmode/btn_%02d", index + 1),
                              label: "Staff comment \(index + 1)", scale: scale) {
                        close()
                        engine.startReplay(label, kind: .staff)
                    }
                    .offset(x: (46 + 318 * CGFloat(index / 6)) * scale, y: (70 + 62 * CGFloat(index % 6)) * scale)
                }
            }
        }
    }
}
