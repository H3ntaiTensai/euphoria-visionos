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

/// The CG gallery: the original's sets under their character tabs, each opening
/// its unlocked pictures.
struct GalleryRoom: View {
    let open: (Panel) -> Void
    let close: () -> Void
    @State private var viewing: [String]?
    private let sets = StoryLibrary.shared.index.gallery
    private let progress = Progress.shared

    var body: some View {
        let seen = progress.seenCG
        let pictures = sets.flatMap(\.pictures)
        ZStack {
            CharacterAlbum(room: .gallery, open: open, close: close,
                           counts: (pictures.filter(seen.contains).count, pictures.count),
                           items: sets.map(\.group)) { index, scale in
                let set = sets[index]
                let unlocked = set.pictures.filter(seen.contains)
                AlbumThumbnail(art: "thumb_cg/\(set.thumb)", locked: unlocked.isEmpty,
                               label: "\(unlocked.count) of \(set.pictures.count) pictures", scale: scale) {
                    viewing = unlocked
                }
            }
            .opacity(viewing == nil ? 1 : 0)
            if let viewing {
                PictureViewer(pictures: viewing) { self.viewing = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewing)
        #if DEBUG
        .task {
            // `-viewGallerySet 0`: open a gallery set's pictures.
            guard let value = UserDefaults.standard.string(forKey: "viewGallerySet"), let index = Int(value) else { return }
            viewing = sets[index].pictures.filter(progress.seenCG.contains)
        }
        #endif
    }
}

/// Scene Replay: the original's scenes under their character tabs.
struct ReplayRoom: View {
    let engine: StoryEngine
    let open: (Panel) -> Void
    let close: () -> Void
    private let replays = StoryLibrary.shared.index.replays
    private let progress = Progress.shared

    var body: some View {
        let unlocked = progress.replays
        CharacterAlbum(room: .replays, open: open, close: close,
                       counts: (replays.filter { unlocked.contains($0.label) }.count, replays.count),
                       items: replays.map(\.group)) { index, scale in
            let replay = replays[index]
            AlbumThumbnail(art: "thumb_rp/\(replay.thumb)", locked: !unlocked.contains(replay.label),
                           label: "Scene \(index + 1)", scale: scale) {
                close()
                engine.startReplay(replay.label)
            }
        }
    }
}

/// The layout the gallery and scene replay share (ES.CGMODE.BTDEF, ES.RPMODE.BTDEF):
/// six character buttons down the left over the chosen character's portrait, her
/// entries six to a page on the right, page arrows, and the seen / total counter.
private struct CharacterAlbum<Item: View>: View {
    let room: Panel
    let open: (Panel) -> Void
    let close: () -> Void
    let counts: (seen: Int, total: Int)
    /// Each entry's character tab, in the original's order.
    let items: [Int]
    @ViewBuilder let item: (Int, CGFloat) -> Item

    static var characters: [String] { ["Nemu", "Kanae", "Rinne", "Rika", "Natsuki", "Misc."] }
    @State private var group = 1
    @State private var page = 0

    var body: some View {
        let entries = items.indices.filter { items[$0] == group }
        let pages = max(1, (entries.count + 5) / 6)
        let art = room == .gallery ? "cgmode" : "rpmode"
        BonusScreen(backdrop: "sys/extra/\(art)/back", current: room, back: "sys/extra/\(art)/btn_back_bt3",
                    backFrames: 3, underlay: String(format: "sys/extra/cgmode/tip_c%02d", group),
                    open: open, close: close) { scale in
            ForEach(1...6, id: \.self) { tab in
                // x 41, rows 102 apart from y 111.
                StripButton(art: String(format: "sys/extra/cgmode/btn_c%02d_bt3", tab), frames: 3,
                            label: Self.characters[tab - 1], selected: tab == group, scale: scale, sound: SystemSound.tab) {
                    group = tab
                    page = 0
                }
                .offset(x: 41 * scale, y: (111 + 102 * CGFloat(tab - 1)) * scale)
            }
            // Two columns of three, 241 × 180 apart from (518, 146); thumbnails inset 2.
            ForEach(Array(entries.dropFirst(page * 6).prefix(6).enumerated()), id: \.element) { slot, index in
                item(index, scale)
                    .offset(x: (518 + 241 * CGFloat(slot % 2)) * scale, y: (146 + 180 * CGFloat(slot / 2)) * scale)
            }
            ArtButton(base: "sys/extra/\(art)/btn_prev", label: "Previous Page", enabled: page > 0, scale: scale) {
                page -= 1
            }
            .offset(x: 843 * scale, y: 105 * scale)
            ArtButton(base: "sys/extra/\(art)/btn_next", label: "Next Page", enabled: page + 1 < pages, scale: scale) {
                page += 1
            }
            .offset(x: 945 * scale, y: 105 * scale)
            ArtNumber(art: "sys/extra/\(art)/num_l", value: page + 1, scale: scale)
                .offset(x: 892 * scale, y: 97 * scale)
            // Seen before the slash, total after it.
            ArtNumber(art: "sys/extra/\(art)/num_m", value: counts.seen, scale: scale)
                .frame(width: 104 * scale, alignment: .trailing)
                .offset(x: 536 * scale, y: 88 * scale)
            ArtNumber(art: "sys/extra/\(art)/num_m", value: counts.total, scale: scale)
                .offset(x: 673 * scale, y: 88 * scale)
                .accessibilityLabel("\(counts.seen) of \(counts.total) unlocked")
        }
        .onAppear {
            // The character is shared with the other album (BonusPlace); the page is this
            // album's own, kept only while it is on the same character.
            group = BonusPlace.group
            if let place = AlbumPlace.remembered[room], place.group == group { page = place.page }
        }
        .onChange(of: group) {
            BonusPlace.group = group
            AlbumPlace.remembered[room] = (group, page)
        }
        .onChange(of: page) { AlbumPlace.remembered[room] = (group, page) }
    }
}

/// The page last shown in each album and the character it was on, kept while the app
/// runs so a finished replay returns to the same place.
@MainActor private enum AlbumPlace {
    static var remembered: [Panel: (group: Int, page: Int)] = [:]
}

/// A gallery or replay entry: the original's plate (its locked look), with the
/// thumbnail over it once unlocked.
private struct AlbumThumbnail: View {
    let art: String
    let locked: Bool
    let label: String
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        let library = ArtLibrary.shared
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                if let plate = library.image("sys/extra/cgmode/btn_plate_back_off") {
                    Image(uiImage: plate).resizable()
                        .frame(width: plate.size.width * scale, height: plate.size.height * scale)
                }
                if !locked, let image = library.image(art) {
                    Image(uiImage: image).resizable()
                        .frame(width: 215 * scale, height: 161 * scale)
                        .offset(x: 2 * scale, y: 2 * scale)
                }
            }
            .contentShape(.hoverEffect, .rect(cornerRadius: 4 * scale))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(locked ? "Locked" : label)
    }
}

/// A number drawn with the original's digit art ("<art>/num_0" ... "num_9").
private struct ArtNumber: View {
    let art: String
    let value: Int
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(String(value).enumerated()), id: \.offset) { _, digit in
                if let image = ArtLibrary.shared.image("\(art)/num_\(digit)") {
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value)")
    }
}

/// A gallery set's pictures, full window, with Previous and Next below and the
/// picture's place in the set between them. Tap for the next; past the last closes.
/// With spatial scenes on, the whole set is queued for generation from the picture
/// shown outward, so the next ones are ready by the time they come up.
struct PictureViewer: View {
    let pictures: [String]
    let close: () -> Void
    @State private var index = 0
    @State private var spatialShowing = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        ZStack {
            // Cleared while a spatial scene shows: it renders behind the window and
            // an opaque fill would hide it.
            Color.black.opacity(spatialShowing ? 0 : 1)
            if index < pictures.count, let image = ArtLibrary.shared.image(pictures[index]) {
                if SpatialSceneLibrary.isEligible(pictures[index]) {
                    // Screen-shaped event CGs open as spatial scenes. Pictures change at
                    // once, with no fade between them.
                    SpatialPicture(name: pictures[index], fades: false)
                } else {
                    // Tall and wide pictures scroll, as in the original's viewer.
                    ScrollView(image.size.width / image.size.height > 1.4 ? .horizontal : .vertical) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: fit(image) ? .fit : .fill)
                    }
                    .scrollIndicators(.hidden)
                    .id(index)
                }
            }
        }
        .clipShape(.rect(cornerRadius: StageView.cornerRadius))
        .contentShape(.rect)
        .onPreferenceChange(SpatialShowingKey.self) { spatialShowing = !$0.isEmpty }
        .onTapGesture {
            if index + 1 < pictures.count { index += 1 } else { close() }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                SystemSound.play(SystemSound.click)
                close()
            } label: {
                Image(systemName: "xmark").font(.system(size: 18 * scale, weight: .semibold))
                    .frame(width: 52 * scale, height: 52 * scale)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .roomGlass(in: .circle)
            .padding(26 * scale)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) { navigation }
        .onChange(of: index, initial: true) { _, index in queueSet(from: index) }
        .onDisappear {
            // Stop generating the rest of the set once it is closed.
            SpatialSceneLibrary.shared.lookahead([])
        }
        .accessibilityAction(named: "Next") { step(1) }
        .accessibilityAction(named: "Previous") { step(-1) }
    }

    /// Previous, the picture's place in the set, Next.
    private var navigation: some View {
        HStack(spacing: 22 * scale) {
            navigationButton("Previous", symbol: "chevron.left", enabled: index > 0) { step(-1) }
            Text("\(index + 1) / \(pictures.count)")
                .font(.game(22 * scale, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 90 * scale)
                .accessibilityLabel("Picture \(index + 1) of \(pictures.count)")
            navigationButton("Next", symbol: "chevron.right", enabled: index + 1 < pictures.count, trailingIcon: true) { step(1) }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 10 * scale)
        .roomGlass(in: .capsule)
        .padding(.bottom, 30 * scale)
    }

    private func navigationButton(_ title: String, symbol: String, enabled: Bool, trailingIcon: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        // Silent, like a tap on the picture: paging through a set shouldn't click.
        Button(action: action) {
            HStack(spacing: 8 * scale) {
                if !trailingIcon { Image(systemName: symbol) }
                Text(title)
                if trailingIcon { Image(systemName: symbol) }
            }
            .font(.game(21 * scale, weight: .medium))
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 10 * scale)
            .contentShape(.hoverEffect, .capsule)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Greyed out at the first and last picture of the set.
        .opacity(enabled ? 1 : 0.3)
    }

    private func step(_ direction: Int) {
        index = min(max(index + direction, 0), pictures.count - 1)
    }

    /// The set's spatial-eligible pictures, nearest first: the ones after this one in
    /// order, then the ones before it going back. Replaces any earlier queue.
    private func queueSet(from index: Int) {
        guard Settings.shared.spatialScenes else { return }
        let after = pictures.indices.filter { $0 > index }
        let before = pictures.indices.filter { $0 < index }.reversed()
        let order = [index] + after + before
        let sources = order.map { pictures[$0] }.filter(SpatialSceneLibrary.isEligible).compactMap { SpatialSource($0) }
        SpatialSceneLibrary.shared.lookahead(sources)
    }

    /// Screen-shaped pictures fit; panoramas and tall pictures fill one axis and scroll.
    private func fit(_ image: UIImage) -> Bool {
        let aspect = image.size.width / image.size.height
        return aspect > 1.2 && aspect < 1.4
    }
}

/// A button made of the original's art files: "<base>_off", highlighted with
/// "<base>_over" while looked at, "<base>_on" while pressed, "<base>_na" when unavailable.
/// Pressing plays the original's click sound.
struct ArtButton: View {
    let base: String
    let label: String
    var enabled = true
    let scale: CGFloat
    var sound: String? = SystemSound.click
    let action: () -> Void

    var body: some View {
        let library = ArtLibrary.shared
        if let image = library.image("\(base)_\(enabled ? "off" : "na")") ?? library.image("\(base)_off") {
            Button {
                SystemSound.play(sound)
                action()
            } label: {
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
                    .contentShape([.interaction, .hoverEffect], .rect)
                    .padding(.vertical, -10 * scale)
                    // Looking anywhere at the button shows the "_over" art: without a
                    // group, that art's effect waits for a look at the art itself, which
                    // visionOS never reports for a view that is not the button.
                    .hoverEffectGroup()
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
    var sound: String? = SystemSound.click
    let action: () -> Void

    var body: some View {
        let library = ArtLibrary.shared
        if let rest = library.frame(art, selected ? 2 : 0, of: frames) {
            Button {
                SystemSound.play(sound)
                action()
            } label: {
                Image(uiImage: rest).resizable()
                    .frame(width: rest.size.width * scale, height: rest.size.height * scale)
                    .opacity(enabled ? 1 : 0.35)
                    .overlay {
                        if enabled, !selected, let over = library.frame(art, 1, of: frames) {
                            Image(uiImage: over).resizable()
                                .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
                        }
                    }
                    .contentShape([.interaction, .hoverEffect], .rect)
                    .hoverEffectGroup()
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
    /// Art drawn over the backdrop and under the buttons (the album's portrait).
    var underlay: String?
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
                if let underlay, let image = ArtLibrary.shared.image(underlay) {
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .allowsHitTesting(false)
                }
                ForEach(Self.tabs, id: \.art) { tab in
                    StripButton(art: "sys/extra/btn_tab_\(tab.art)_bt3", frames: 3, label: tab.label,
                                selected: tab.panel == current, scale: scale, sound: SystemSound.tab) {
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

    var body: some View {
        BonusScreen(backdrop: "sys/extra/bgmmode/back", current: .music, back: "sys/extra/bgmmode/btn_back_bt3",
                    backFrames: 3, open: open, close: close) { scale in
            ForEach(Array(tracks.enumerated()), id: \.element) { index, track in
                // Every track is open, as the original's ES.BGMMODE.INIT unlocks them all.
                // Tracks 1–10 at x 51, 11–20 at x 521; rows 46 apart from y 92 (ES.BGMMODE.BTDEF).
                StripButton(art: String(format: "sys/extra/bgmmode/btn_bgm%02d_bt4", index + 1), frames: 4,
                            label: "Track \(index + 1)", selected: playing == track, scale: scale) {
                    toggle(track)
                }
                .offset(x: (index < 10 ? 51 : 521) * scale, y: (92 + 46 * CGFloat(index % 10) - (index == 0 ? 1 : 0)) * scale)
            }
        }
        .onDisappear {
            if playing != nil { engine.audio.stop(channel: 1, fadeMs: 500) }
        }
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
