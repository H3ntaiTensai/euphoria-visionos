import SwiftUI

enum Panel: String, Identifiable {
    case history, save, load, settings, gallery, replays, music, staff
    var id: String { rawValue }
}

/// The game window: title screen or story, with controls in an ornament below.
struct GameView: View {
    let engine: StoryEngine
    @State private var panel: Panel?
    @State private var textHidden = false

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 1440
            ZStack {
                switch engine.mode {
                case .title:
                    TitleView(engine: engine, panel: $panel)
                case .story:
                    StoryView(engine: engine, textHidden: $textHidden)
                }
                switch panel {
                case .music:
                    MusicRoom(engine: engine, open: { panel = $0 }) { panel = nil }
                        .transition(.opacity)
                case .staff:
                    StaffRoom(engine: engine, open: { panel = $0 }) { panel = nil }
                        .transition(.opacity)
                case let panel?:
                    PanelHost(panel: panel, engine: engine) { self.panel = nil }
                        .transition(.opacity)
                case nil:
                    EmptyView()
                }
                if let movie = engine.movie {
                    MoviePlayerView(url: movie) { engine.movieFinished() }
                        .background(.black)
                        .clipShape(.rect(cornerRadius: StageView.cornerRadius))
                        .contentShape(.rect)
                        .onTapGesture { engine.movieFinished() }
                        .accessibilityAction(named: "Skip Movie") { engine.movieFinished() }
                        .transition(.opacity)
                }
            }
            .environment(\.uiScale, scale)
            .environment(\.stageFlattened, panel != nil)
        }
        .background(WindowAspectLock())
        .animation(.easeInOut(duration: 0.25), value: panel)
        .animation(.easeInOut(duration: 0.4), value: engine.mode)
        .animation(.easeInOut(duration: 0.4), value: engine.movie)
        .onChange(of: engine.finishedReplay) { _, finished in
            // A replay ended: back to its list, as in the original.
            guard let finished else { return }
            engine.finishedReplay = nil
            panel = finished == .staff ? .staff : .replays
        }
        .ornament(visibility: engine.mode == .story && engine.movie == nil ? .visible : .hidden, attachmentAnchor: .scene(.bottom),
                  contentAlignment: .top) {
            ControlBar(engine: engine, panel: $panel, textHidden: $textHidden)
        }
        .task { await DebugAutomation.run(engine) }
        #if DEBUG
        .task {
            // `-debugQuit YES`: press Quit a few seconds after launch.
            guard UserDefaults.standard.bool(forKey: "debugQuit") else { return }
            try? await Task.sleep(for: .seconds(4))
            TitleView.quit(engine)
        }
        .task {
            // `-panel history|save|load|settings`: open a panel after launch.
            guard let name = UserDefaults.standard.string(forKey: "panel"), let shown = Panel(rawValue: name) else { return }
            try? await Task.sleep(for: .seconds(3))
            panel = shown
        }
        .task {
            // `-textHidden YES`: start with the text hidden.
            textHidden = UserDefaults.standard.bool(forKey: "textHidden")
        }
        #endif
    }
}

/// The original title screen: its artwork with its button art, each placed where
/// the original puts it (beside the rule lines drawn in the background).
struct TitleView: View {
    let engine: StoryEngine
    @Binding var panel: Panel?
    @State private var extras = UserDefaults.standard.bool(forKey: "titleExtras")
    private let progress = Progress.shared

    /// The original's menu column: x 671, rows 55 apart from y 396 (ES.TITLE.BTDEF).
    private static let rows: [CGFloat] = [396, 451, 508, 562, 617]

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Screen.size.width
            ZStack(alignment: .topLeading) {
                if let image = ArtLibrary.shared.image("sys/title/back") {
                    Image(uiImage: image).resizable()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                ForEach(Array(buttons.enumerated()), id: \.element.art) { row, button in
                    ArtButton(base: "sys/title/btn_\(button.art)", label: Self.label(button.art),
                              enabled: button.action != nil, scale: scale) {
                        button.action?()
                    }
                    .offset(x: 671 * scale, y: Self.rows[row] * scale)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: extras)
        }
        .clipShape(.rect(cornerRadius: StageView.cornerRadius))
    }

    private var buttons: [(art: String, action: (() -> Void)?)] {
        if extras {
            let staff = (1...StoryLibrary.shared.index.staff.count).contains(where: progress.staffUnlocked)
            return [("cgmode", { panel = .gallery }),
                    ("rpmode", { panel = .replays }),
                    ("bgmmode", progress.tracks.isEmpty ? nil : { panel = .music }),
                    ("staffmode", staff ? { panel = .staff } : nil),
                    ("back", { extras = false })]
        }
        return [("start", { engine.newGame() }),
                ("load", { panel = .load }),
                ("omake", progress.extrasUnlocked ? { extras = true } : nil),
                ("config", { panel = .settings }),
                ("end", { Self.quit(engine) })]
    }

    /// Quit: close the game window. visionOS keeps an app's last window open on
    /// dismissWindow, so ask the system to end the window's scene session instead.
    static func quit(_ engine: StoryEngine) {
        engine.audio.stopAll()
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
                debugLog("Quit failed: \(error.localizedDescription)")
            }
        }
    }

    static func label(_ art: String) -> String {
        ["start": "Start", "load": "Load", "omake": "Bonus", "config": "Settings", "end": "Quit",
         "cgmode": "CG Gallery", "rpmode": "Scene Replay", "bgmmode": "Music Replay", "staffmode": "Staff Comments",
         "back": "Return to Main Menu"][art] ?? art
    }
}

/// The stage with the dialogue and choices floating in front of it.
private struct StoryView: View {
    let engine: StoryEngine
    @Binding var textHidden: Bool
    var settings = Settings.shared
    @Environment(\.uiScale) private var scale
    @Environment(\.stageFlattened) private var flattened
    @State private var revealed = 0
    @State private var revealTask: Task<Void, Never>?

    private var lineLength: Int { engine.line?.text.count ?? 0 }
    private var lineComplete: Bool { revealed >= lineLength }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                StageView(stage: engine.stage, spatial: !engine.skipping)
                if let buttons = engine.pictureChoices, !flattened {
                    HeroineSelection(buttons: buttons) { engine.choose($0) }
                        .inFrontOfWindow(by: StageView.interfaceDepth(settings))
                        .transition(.opacity)
                }
                if !textHidden && !flattened {
                    VStack(spacing: 22 * scale) {
                        if let choices = engine.choices {
                            ChoiceList(choices: choices) { engine.choose($0) }
                                .frame(maxHeight: .infinity)
                        }
                        if let line = engine.line {
                            DialoguePanel(line: line, revealed: revealed, complete: lineComplete,
                                          waiting: engine.waitingForClick, width: proxy.size.width * 0.86,
                                          sizeScale: engine.textSize.map { Double($0) / 22 } ?? 1)
                        }
                    }
                    .padding(.bottom, proxy.size.height * 0.035)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    .inFrontOfWindow(by: StageView.interfaceDepth(settings))
                    .transition(.opacity)
                }
            }
            .contentShape(.rect)
            .onTapGesture(perform: tap)
        }
        .animation(.easeOut(duration: 0.2), value: engine.choices)
        .animation(.easeOut(duration: 0.4), value: engine.pictureChoices)
        .animation(.easeOut(duration: 0.2), value: textHidden)
        .onChange(of: engine.lineSerial, initial: true) { _, _ in startReveal() }
        .onChange(of: lineComplete) { _, _ in scheduleAuto() }
        .onChange(of: engine.waitingForClick) { _, _ in scheduleAuto() }
        .onChange(of: engine.autoPlay) { _, _ in scheduleAuto() }
        .accessibilityAction(named: "Continue", tap)
    }

    private func tap() {
        if textHidden {
            textHidden = false
        } else if engine.choices != nil || engine.pictureChoices != nil {
            return
        } else if !lineComplete {
            revealed = lineLength
        } else {
            engine.skipping = false
            engine.advance()
        }
    }

    private func startReveal() {
        revealTask?.cancel()
        let speed = settings.textSpeed
        guard speed > 0, !engine.skipping, lineLength > 0 else {
            revealed = lineLength
            return
        }
        revealed = 0
        let total = lineLength
        revealTask = Task {
            let step = Duration.seconds(1 / speed)
            while !Task.isCancelled, revealed < total {
                try? await Task.sleep(for: step)
                revealed += 1
            }
        }
    }

    private func scheduleAuto() {
        guard engine.autoPlay, lineComplete, engine.waitingForClick, let line = engine.line else { return }
        let serial = engine.lineSerial
        let delay = settings.autoDelay + Double(line.text.count) * 0.02
        Task {
            try? await Task.sleep(for: .seconds(delay))
            // Let a voice finish before moving on.
            while engine.audio.isVoicePlaying, engine.autoPlay, engine.lineSerial == serial {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if engine.autoPlay, engine.lineSerial == serial, engine.waitingForClick { engine.advance() }
        }
    }
}

private struct DialoguePanel: View {
    let line: Line
    let revealed: Int
    let complete: Bool
    let waiting: Bool
    let width: CGFloat
    /// The script's text size relative to the original's default (es.TextSizeChange).
    var sizeScale: Double = 1
    var settings = Settings.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        let text = settings.textScale * sizeScale * scale
        VStack(alignment: .leading, spacing: 10 * scale) {
            if let name = line.name {
                Text(name)
                    .font(.system(size: 30 * text, weight: .semibold, design: .serif))
                    .foregroundStyle(CharacterColors.color(for: line))
            }
            // The unrevealed rest keeps its space, so the panel never resizes mid-line.
            Text("\(Text(line.text.prefix(revealed)))\(Text(line.text.dropFirst(revealed)).foregroundStyle(.clear))")
                .font(.system(size: 30 * text, design: .serif))
                .lineSpacing(7 * text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(line.text)
        }
        .padding(.horizontal, 44 * scale)
        .padding(.vertical, 30 * scale)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 170 * scale, alignment: .topLeading)
        // Tinted so light text stays readable over the game's many white rooms.
        .background(.black.opacity(0.42), in: .rect(cornerRadius: 34 * scale))
        .glassBackgroundEffect(in: .rect(cornerRadius: 34 * scale))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(22 * scale)
                .opacity(complete && waiting ? 1 : 0)
                .symbolEffect(.bounce.down, options: .repeating, isActive: complete && waiting)
        }
    }
}

enum CharacterColors {
    /// The speaker's color; a name not yet revealed ("???") stays neutral.
    static func color(for line: Line) -> Color {
        guard let name = line.name else { return Color(white: 0.92) }
        return name.contains("?") ? Color(white: 0.92) : color(for: line.who ?? name)
    }

    static func color(for who: String) -> Color {
        switch who {
        case "Nemu", "Young Nemu": Color(red: 0.72, green: 0.78, blue: 1.0)
        case "Kanae": Color(red: 1.0, green: 0.74, blue: 0.62)
        case "Rinne": Color(red: 0.85, green: 0.72, blue: 1.0)
        case "Rika": Color(red: 1.0, green: 0.68, blue: 0.80)
        case "Natsuki": Color(red: 0.70, green: 0.92, blue: 0.80)
        case "Keisuke": Color(red: 0.80, green: 0.86, blue: 0.95)
        default: Color(white: 0.92)
        }
    }
}

private struct ChoiceList: View {
    let choices: [Choice]
    let choose: (Int) -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(spacing: 16 * scale) {
            ForEach(choices) { choice in
                Button { choose(choice.index) } label: {
                    Text(choice.text)
                        .font(.system(size: 28 * scale, weight: .medium, design: .serif))
                        .padding(.horizontal, 40 * scale)
                        .padding(.vertical, 18 * scale)
                        .frame(minWidth: 520 * scale)
                        .glassBackgroundEffect(in: .capsule)
                        .contentShape(.hoverEffect, .capsule)
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .disabled(!choice.enabled)
                .opacity(choice.enabled ? 1 : 0.45)
            }
        }
    }
}

/// The original's heroine selection: sketch portraits on its own backdrop.
private struct HeroineSelection: View {
    let buttons: [PictureButton]
    let choose: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Screen.size.width
            ZStack(alignment: .topLeading) {
                if let back = ArtLibrary.shared.image("sys/csel/back") {
                    Image(uiImage: back).resizable().clipShape(.rect(cornerRadius: StageView.cornerRadius))
                }
                ForEach(buttons) { button in
                    if let art = ArtLibrary.shared.image(button.art) {
                        let size = CGSize(width: art.size.width * scale, height: art.size.height * scale)
                        Button { choose(button.number) } label: {
                            ZStack {
                                Image(uiImage: art).resizable()
                                if let hover = ArtLibrary.shared.image(button.hover) {
                                    // The original's highlighted art, shown while looked at.
                                    Image(uiImage: hover).resizable()
                                        .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
                                }
                            }
                            .frame(width: size.width, height: size.height)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .offset(x: button.origin.x * scale, y: button.origin.y * scale)
                        .accessibilityLabel("Option \(button.number)")
                    }
                }
            }
        }
    }
}

/// Story controls, in words like the original's quick menu.
private struct ControlBar: View {
    let engine: StoryEngine
    @Binding var panel: Panel?
    @Binding var textHidden: Bool

    @State private var savedFlash = false

    var body: some View {
        let _ = SaveStore.shared.revision
        HStack(spacing: 6) {
            Button("History") { panel = .history }
            Toggle("Auto", isOn: Binding(get: { engine.autoPlay }, set: { engine.autoPlay = $0; if $0 { engine.skipping = false } }))
                .toggleStyle(.button)
            Toggle("Skip", isOn: Binding(get: { engine.skipping }, set: { engine.skipping = $0; if $0 { engine.autoPlay = false; engine.advance() } }))
                .toggleStyle(.button)
            Button("Save") { panel = .save }
            Button("Load") { panel = .load }
            Button(savedFlash ? "Saved" : "Q.Save") {
                guard let save = engine.currentSave else { return }
                SaveStore.shared.write(save, slot: SaveStore.quickSlot)
                savedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    savedFlash = false
                }
            }
            .disabled(engine.currentSave == nil)
            Button("Q.Load") {
                if let save = SaveStore.shared.read(SaveStore.quickSlot) { engine.load(save) }
            }
            .disabled(!SaveStore.shared.exists(SaveStore.quickSlot))
            Divider().frame(height: 28)
            Button { textHidden.toggle() } label: { Image(systemName: textHidden ? "text.bubble.fill" : "text.bubble") }
                .help("Hide Text")
            Button { panel = .settings } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { engine.returnToTitle() } label: { Image(systemName: "house") }
                .help("Title")
        }
        .buttonStyle(.borderless)
        .padding(12)
        .glassBackgroundEffect()
    }
}

/// Launch arguments for driving the app without input (Debug builds):
/// `-autostart YES`, `-startLabel 00_op_02`, `-autoAdvance 0.8` (seconds per line),
/// `-choices 0,1`, `-loadSlot quick`, `-skip YES` (skip mode, kept on after choices),
/// `-replay RP_nem_h01`, `-playMovie op`, `-titleExtras YES`, `-viewGallerySet 0`.
enum DebugAutomation {
    @MainActor
    static func run(_ engine: StoryEngine) async {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let label = defaults.string(forKey: "replay") {
            engine.startReplay(label, kind: label.hasPrefix("STAFF_") ? .staff : .scene)
        } else if let movie = defaults.string(forKey: "playMovie"), let url = StoryLibrary.shared.assetURL("pac/\(movie).ypf") {
            await engine.playMovie(url)
            return
        } else if let slot = defaults.string(forKey: "loadSlot"), let save = SaveStore.shared.read(slot) {
            engine.load(save)
        } else if let label = defaults.string(forKey: "startLabel") {
            engine.newGame(at: label)
        } else if defaults.bool(forKey: "autostart") {
            engine.newGame()
        }
        let interval = defaults.double(forKey: "autoAdvance")
        guard interval > 0 else { return }
        let skip = defaults.bool(forKey: "skip")
        var picks = (defaults.string(forKey: "choices") ?? "").split(separator: ",").compactMap { Int($0) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if skip, engine.mode == .story, engine.choices == nil { engine.skipping = true }
            if let buttons = engine.pictureChoices {
                let pick = picks.isEmpty ? buttons[0].number : picks.removeFirst()
                debugLog("Automation picked heroine \(pick)")
                engine.choose(pick)
            } else if let choices = engine.choices {
                let pick = picks.isEmpty ? choices[0].index : picks.removeFirst()
                debugLog("Automation chose \(pick)")
                engine.choose(pick)
            } else if engine.waitingForClick {
                engine.advance()
            }
        }
        #endif
    }
}
