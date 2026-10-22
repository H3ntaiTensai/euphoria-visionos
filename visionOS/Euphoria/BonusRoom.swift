import SwiftUI

extension Panel {
    /// The four bonus sections, in the original's tab order.
    static let bonus: [Panel] = [.gallery, .replays, .music, .staff]
    var isBonus: Bool { Self.bonus.contains(self) }
}

/// The bonus menu in visionOS style: a glass window with the sections in an ornament
/// to its left, the original's character tiles on a glass slab across its top edge
/// (gallery and scene replay), and a now-playing bar below it (music replay).
/// Settings › Classic Bonus Menu shows the original's PC layout instead.
struct BonusRoom: View {
    let engine: StoryEngine
    let section: Panel
    let open: (Panel) -> Void
    let close: () -> Void
    @State private var viewing: [String]?
    @State private var group = 1
    /// The music room's track (an index into the track list) and whether it is paused.
    @State private var track: Int?
    @State private var paused = false
    @Bindable private var settings = Settings.shared
    private let progress = Progress.shared
    private let library = StoryLibrary.shared.index
    @Environment(\.uiScale) private var scale

    static let characters = ["Nemu", "Kanae", "Rinne", "Rika", "Natsuki", "Misc."]

    /// The music room's titles, as the original's track art spells them.
    static let trackTitles = [
        "Unrest", "Tension", "Lost Hope", "Repose", "Shock", "Struggle in Vain", "Tragedy", "Solitude",
        "Madness", "Lust", "Brutality", "Carnality", "Conclusion", "Resolution",
        "“Door to Paradise” (short ver.)", "“Door to Paradise” (short off-vocal ver.)",
        "“Door to Paradise” (short instrumental ver.)", "“Door to Paradise” (full ver.)",
        "“Door to Paradise” (full off-vocal ver.)", "“Door to Paradise” (full instrumental ver.)",
    ]

    /// The staff comments' speakers, as the original's button art spells them.
    static let staff: [(role: String, name: String)] = [
        ("“Nemu Manaka’s” VA", "Aozora Ramune"), ("“Kanae Hokari’s” VA", "Himari"),
        ("“Rinne Byakuya’s” VA", "Sugihara Matsuri"), ("“Rika Makiba’s” VA", "Konoha"),
        ("“Natsuki Aoi’s” VA", "Misonoh Mei"), ("“Miyako Andou’s” VA", "Azuma Karin"),
        ("Character designer", "Hamashima Shigeo"), ("Scenario", "Asou Ei"), ("Scenario", "Izumi Banya"),
        ("Chief graphics designer", "Hyoujou Aoi"), ("Chief graphics designer", "PONSUKE"),
        ("Graphics designer", "Takurou"), ("Graphics designer", "Futami Shizuru"),
        ("Graphics designer", "Munashimujou"), ("Programmer", "Honoi"), ("Director", "Akutsu Ryou"),
        ("Sub-director/Scripter", "Supana/RYU☆JI"),
    ]

    private var isAlbum: Bool { section == .gallery || section == .replays }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 24 * scale) {
                header
                switch section {
                case .gallery, .replays: album
                case .music: musicList
                default: staffList
                }
            }
            .padding(.horizontal, 52 * scale)
            // Room under the character slab, which overlaps the window's top edge.
            .padding(.top, (isAlbum ? 100 : 44) * scale)
            .padding(.bottom, 36 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .roomGlass(in: .rect(cornerRadius: StageView.cornerRadius))
            // Hidden under the viewer: a spatial scene shows only through a clear window.
            .opacity(viewing == nil ? 1 : 0)
            if let viewing {
                PictureViewer(pictures: viewing) { self.viewing = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewing)
        .animation(.easeInOut(duration: 0.25), value: section)
        .ornament(visibility: viewing == nil ? .visible : .hidden, attachmentAnchor: .scene(.leading),
                  contentAlignment: .trailing) {
            sectionTabs
        }
        .ornament(visibility: isAlbum && viewing == nil ? .visible : .hidden, attachmentAnchor: .scene(.top),
                  contentAlignment: .center) {
            CharacterSlab(group: $group)
        }
        .ornament(visibility: section == .music && track != nil ? .visible : .hidden, attachmentAnchor: .scene(.bottom),
                  contentAlignment: .top) {
            nowPlaying
        }
        .onAppear { group = BonusPlace.group[section] ?? 1 }
        .onChange(of: section) { group = BonusPlace.group[section] ?? 1 }
        .onChange(of: group) { BonusPlace.group[section] = group }
        .onDisappear {
            // Only a track the music room started; otherwise the title theme plays on.
            if track != nil { engine.audio.stop(channel: 1, fadeMs: 500) }
        }
        #if DEBUG
        .task {
            // `-viewGallerySet 0`: open a gallery set's pictures.
            guard section == .gallery, let value = UserDefaults.standard.string(forKey: "viewGallerySet"),
                  let index = Int(value) else { return }
            viewing = library.gallery[index].pictures.filter(progress.seenCG.contains)
        }
        .task {
            // `-bonusGroup 3`: show a character's tab; `-playTrack 0`: start a track.
            let defaults = UserDefaults.standard
            if let value = defaults.string(forKey: "bonusGroup"), let tab = Int(value) { group = tab }
            if section == .music, let value = defaults.string(forKey: "playTrack"), let index = Int(value) { play(index) }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18 * scale) {
            Button {
                SystemSound.play(SystemSound.click)
                close()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22 * scale, weight: .semibold))
                    .frame(width: 56 * scale, height: 56 * scale)
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back to Title")
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(title).font(.game(36 * scale, weight: .semibold))
                Text(subtitle).font(.game(19 * scale)).foregroundStyle(.secondary)
            }
            Spacer()
            if section == .gallery { spatialSwitch }
        }
    }

    private var title: String {
        switch section {
        case .gallery: "CG Gallery"
        case .replays: "Scene Replay"
        case .music: "Music Replay"
        default: "Staff Comments"
        }
    }

    private var subtitle: String {
        switch section {
        case .gallery:
            let pictures = library.gallery.flatMap(\.pictures)
            return "\(pictures.filter(progress.seenCG.contains).count) of \(pictures.count) pictures"
        case .replays:
            return "\(library.replays.filter { progress.replays.contains($0.label) }.count) of \(library.replays.count) scenes"
        case .music:
            return "\(library.music.count) tracks"
        default:
            let unlocked = library.staff.indices.filter { progress.staffUnlocked($0 + 1) }.count
            return "\(unlocked) of \(library.staff.count) comments"
        }
    }

    /// Whether pictures will open as spatial scenes; the same setting as Settings › Spatial Scenes.
    @ViewBuilder private var spatialSwitch: some View {
        let available = SpatialSceneLibrary.shared.isSupported
        let on = settings.spatialScenes && available
        Toggle(isOn: $settings.spatialScenes) {
            Label(available ? (on ? "Spatial On" : "Spatial Off") : "Spatial Unavailable",
                  systemImage: on ? "cube" : "photo")
                .font(.game(19 * scale, weight: .medium))
        }
        .toggleStyle(.switch)
        .tint(.green)
        .disabled(!available)
        .fixedSize()
        .padding(.leading, 20 * scale)
        .padding(.trailing, 12 * scale)
        .padding(.vertical, 10 * scale)
        .glassBackgroundEffect(in: .capsule)
    }

    // MARK: Section tabs

    private var sectionTabs: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Panel.bonus) { tab in
                Button {
                    guard tab != section else { return }
                    SystemSound.play(SystemSound.tab)
                    open(tab)
                } label: {
                    Text(Self.label(tab))
                        .font(.game(19, weight: tab == section ? .semibold : .regular))
                        .foregroundStyle(tab == section ? Color.white : RoomGlass.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .background(tab == section ? RoomGlass.ink.opacity(0.85) : .clear, in: .capsule)
                        .contentShape(.hoverEffect, .capsule)
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .disabled(!available(tab))
                .opacity(available(tab) ? 1 : 0.4)
                .accessibilityAddTraits(tab == section ? .isSelected : [])
            }
        }
        .fixedSize()
        .padding(10)
        // Plain white over the glass instead of the room picture: still see-through.
        .foregroundStyle(RoomGlass.ink)
        .tint(RoomGlass.ink)
        .background(.white.opacity(0.55), in: .rect(cornerRadius: 32))
        .glassBackgroundEffect(in: .rect(cornerRadius: 32))
    }

    private static func label(_ tab: Panel) -> String {
        switch tab {
        case .gallery: "CG Gallery"
        case .replays: "Scene Replay"
        case .music: "Music Replay"
        default: "Staff Comments"
        }
    }

    /// Staff comments open once one is unlocked, as on the title screen. Every track
    /// is open in Music Replay, as the original's ES.BGMMODE.INIT unlocks them all.
    private func available(_ tab: Panel) -> Bool {
        switch tab {
        case .staff: library.staff.indices.contains { progress.staffUnlocked($0 + 1) }
        default: true
        }
    }

    // MARK: Gallery and scene replay

    private var album: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 18 * scale), count: 4)
        return GeometryReader { proxy in
            // As in the original, the portrait (575 × 768) runs from the bottom edge of the
            // window up, behind the entries; it fills the height below the header here.
            let height = proxy.size.height + 36 * scale
            let factor = height / 768
            ZStack(alignment: .topLeading) {
                if let portrait = ArtLibrary.shared.image(String(format: "sys/extra/cgmode/tip_c%02d", group)) {
                    Image(uiImage: portrait).resizable()
                        .frame(width: 575 * factor, height: height)
                        // The figures start about 200 pixels into the art.
                        .offset(x: -200 * factor)
                        .id(group)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18 * scale) {
                        if section == .gallery {
                            ForEach(library.gallery.filter { $0.group == group }) { set in
                                let unlocked = set.pictures.filter(progress.seenCG.contains)
                                AlbumTile(art: "thumb_cg/\(set.thumb)", locked: unlocked.isEmpty,
                                          caption: "\(unlocked.count)/\(set.pictures.count)",
                                          spatial: settings.spatialScenes && SpatialSceneLibrary.shared.isSupported
                                              && unlocked.contains(where: SpatialSceneLibrary.isEligible),
                                          label: "\(unlocked.count) of \(set.pictures.count) pictures") {
                                    viewing = unlocked
                                }
                            }
                        } else {
                            ForEach(Array(library.replays.enumerated()).filter { $0.element.group == group }, id: \.element.id) { index, replay in
                                AlbumTile(art: "thumb_rp/\(replay.thumb)", locked: !progress.replays.contains(replay.label),
                                          caption: nil, spatial: false, label: "Scene \(index + 1)") {
                                    close()
                                    engine.startReplay(replay.label)
                                }
                            }
                        }
                    }
                    .padding(8 * scale)
                }
                .scrollIndicators(.hidden)
                .padding(.leading, 320 * factor)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.3), value: group)
    }

    // MARK: Music replay

    private var musicList: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14 * scale), count: 2)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12 * scale) {
                ForEach(library.music.indices, id: \.self) { index in
                    ListRow(locked: false, selected: track == index,
                            icon: track == index ? (paused ? "pause.fill" : "speaker.wave.2.fill") : "play.fill") {
                        HStack {
                            Text(Self.trackTitles[safe: index] ?? "Track \(index + 1)")
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%02d", index + 1)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } action: {
                        track == index ? togglePause() : play(index)
                    }
                }
            }
            .padding(8 * scale)
        }
        .scrollIndicators(.hidden)
    }

    private var nowPlaying: some View {
        HStack(spacing: 18) {
            Image(systemName: "music.note").font(.system(size: 20))
            Text(track.flatMap { Self.trackTitles[safe: $0] } ?? "")
                .font(.game(19, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 300, alignment: .leading)
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous Track")
                Button(action: togglePause) { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .accessibilityLabel(paused ? "Play" : "Pause")
                Button { step(1) } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next Track")
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .font(.game(20))
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let position = engine.audio.progress(channel: 1) ?? (0, 0)
                HStack(spacing: 12) {
                    // A bar of its own: the system one's track vanishes on the light glass.
                    let fraction = position.duration > 0 ? min(position.time / position.duration, 1) : 0
                    Capsule().fill(.black.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().frame(width: 180 * fraction)
                        }
                        .frame(width: 180, height: 6)
                        .accessibilityElement()
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                    Text("\(Self.clock(position.time)) / \(Self.clock(position.duration))")
                        .font(.game(16)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .roomGlass(in: .capsule)
    }

    private func play(_ index: Int) {
        guard library.music.indices.contains(index) else { return }
        engine.audio.play(channel: 1, file: library.music[index], fadeMs: 300, volume: -1, loop: -1)
        track = index
        paused = false
    }

    private func togglePause() {
        paused.toggle()
        engine.audio.setPaused(paused, channel: 1)
    }

    /// The previous or next track, wrapping around.
    private func step(_ direction: Int) {
        let count = library.music.count
        guard count > 0 else { return }
        play(((track ?? 0) + direction + count) % count)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Staff comments

    private var staffList: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14 * scale), count: 2)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12 * scale) {
                ForEach(library.staff.indices, id: \.self) { index in
                    let unlocked = progress.staffUnlocked(index + 1)
                    let person = Self.staff[safe: index]
                    ListRow(locked: !unlocked, selected: false, icon: "text.bubble") {
                        if unlocked, let person {
                            VStack(alignment: .leading, spacing: 2 * scale) {
                                Text(person.role).font(.game(16 * scale)).foregroundStyle(.secondary)
                                Text(person.name)
                            }
                        } else {
                            Text("Locked")
                        }
                    } action: {
                        close()
                        engine.startReplay(library.staff[index], kind: .staff)
                    }
                }
            }
            .padding(8 * scale)
        }
        .scrollIndicators(.hidden)
    }
}

/// The character tab and section shown last, kept while the app runs so a finished
/// replay returns to the same character.
@MainActor private enum BonusPlace {
    static var group: [Panel: Int] = [:]
}

/// The original's six character tiles on a thick glass slab, scrolling sideways
/// four at a time.
private struct CharacterSlab: View {
    @Binding var group: Int
    @State private var first: Int?
    private static let visible = 4
    private static let spacing: CGFloat = 14

    var body: some View {
        let count = BonusRoom.characters.count
        HStack(spacing: 10) {
            arrow("chevron.left", label: "Previous Characters", enabled: (first ?? 1) > 1) {
                first = max(1, (first ?? 1) - 1)
            }
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing) {
                    ForEach(1...count, id: \.self) { tab in
                        StripButton(art: String(format: "sys/extra/cgmode/btn_c%02d_bt3", tab), frames: 3,
                                    label: BonusRoom.characters[tab - 1], selected: tab == group, scale: 1,
                                    sound: SystemSound.tab) {
                            group = tab
                        }
                        .clipShape(.rect(cornerRadius: 6))
                        .scaleEffect(tab == group ? 1.06 : 1)
                        .offset(z: tab == group ? 12 : 4)
                        .animation(.spring(duration: 0.3), value: group)
                        .id(tab)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $first, anchor: .leading)
            .scrollIndicators(.hidden)
            .frame(width: 196 * CGFloat(Self.visible) + Self.spacing * CGFloat(Self.visible - 1) + 12)
            arrow("chevron.right", label: "More Characters", enabled: (first ?? 1) + Self.visible <= count) {
                first = min(count - Self.visible + 1, (first ?? 1) + 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // The slab's edge, a little below its face, so the glass reads as thick.
            RoundedRectangle(cornerRadius: 34)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.22), lineWidth: 1))
                .offset(y: 7)
        }
        .roomGlass(in: .rect(cornerRadius: 34))
        .overlay {
            RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.3), value: first)
        .onAppear {
            // Show the selected character's tile when it starts past the first four.
            if group > Self.visible { first = group - Self.visible + 1 }
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A gallery set or scene: its thumbnail, or frosted glass with a lock until it is
/// unlocked. A cube marks sets whose pictures open as spatial scenes.
private struct AlbumTile: View {
    let art: String
    let locked: Bool
    let caption: String?
    let spatial: Bool
    let label: String
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            SystemSound.play(SystemSound.click)
            action()
        } label: {
            ZStack {
                if !locked, let image = ArtLibrary.shared.image(art) {
                    Image(uiImage: image).resizable().aspectRatio(4 / 3, contentMode: .fill)
                } else {
                    Color.black.opacity(0.06)
                    Image(systemName: "lock.fill").font(.system(size: 26 * scale)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if spatial && !locked {
                    Image(systemName: "cube")
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .frame(width: 32 * scale, height: 32 * scale)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.4), in: .circle)
                        .padding(8 * scale)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let caption, !locked {
                    Text(caption)
                        .font(.game(15 * scale, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 9 * scale)
                        .padding(.vertical, 3 * scale)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.5), in: .capsule)
                        .padding(8 * scale)
                }
            }
            .clipShape(.rect(cornerRadius: 18 * scale))
            .contentShape(.hoverEffect, .rect(cornerRadius: 18 * scale))
            .hoverEffect { effect, isActive, _ in effect.scaleEffect(isActive ? 1.05 : 1) }
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(locked ? "Locked" : label + (spatial ? ", opens as spatial scenes" : ""))
    }
}

/// A row in the music and staff lists: glass, lifted when selected, dimmed and locked
/// until unlocked.
private struct ListRow<Content: View>: View {
    let locked: Bool
    let selected: Bool
    let icon: String
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            SystemSound.play(SystemSound.click)
            action()
        } label: {
            HStack(spacing: 16 * scale) {
                Image(systemName: locked ? "lock.fill" : icon)
                    .font(.system(size: 20 * scale))
                    .frame(width: 30 * scale)
                    .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(RoomGlass.ink))
                content()
                    .font(.game(22 * scale))
                    .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(RoomGlass.ink))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22 * scale)
            .padding(.vertical, 16 * scale)
            .frame(minHeight: 74 * scale)
            .background(.black.opacity(selected ? 0.13 : 0.05), in: .rect(cornerRadius: 20 * scale))
            .contentShape(.hoverEffect, .rect(cornerRadius: 20 * scale))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
