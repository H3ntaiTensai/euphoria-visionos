import SwiftUI

/// A panel drawn inside the window over the dimmed stage.
struct PanelHost: View {
    let panel: Panel
    let engine: StoryEngine
    let close: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .clipShape(.rect(cornerRadius: StageView.cornerRadius))
                .contentShape(.rect)
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 18 * scale) {
                HStack {
                    Text(title)
                        .font(.game(38 * scale, weight: .semibold))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 22 * scale, weight: .semibold))
                            .frame(width: 52 * scale, height: 52 * scale)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
                }
                switch panel {
                case .history: HistoryPanel(engine: engine)
                case .save: SavePanel(engine: engine, saving: true, close: close)
                case .load: SavePanel(engine: engine, saving: false, close: close)
                case .settings: SettingsPanel(engine: engine)
                case .gallery, .replays, .music, .staff: EmptyView()  // full-window screens, shown by GameView
                }
            }
            .padding(36 * scale)
            .frame(width: 1180 * scale, height: 880 * scale, alignment: .topLeading)
            .roomGlass(in: .rect(cornerRadius: 40 * scale))
            .contentShape(.rect(cornerRadius: 40 * scale))
            .onTapGesture {}
        }
    }

    private var title: String {
        switch panel {
        case .history: "History"
        case .save: "Save"
        case .load: "Load"
        case .settings: "Settings"
        case .gallery: "CG Gallery"
        case .replays: "Scene Replay"
        case .music: "Music Replay"
        case .staff: "Staff Comments"
        }
    }
}

private struct HistoryPanel: View {
    let engine: StoryEngine
    @Environment(\.uiScale) private var scale

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22 * scale) {
                    ForEach(Array(engine.history.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 14 * scale) {
                            VStack(alignment: .leading, spacing: 4 * scale) {
                                if let name = line.name {
                                    Text(name)
                                        .font(.game(24 * scale, weight: .semibold))
                                        .foregroundStyle(CharacterColors.ink(for: line))
                                }
                                Text(line.text)
                                    .font(.game(25 * scale))
                                    .foregroundStyle(line.name == nil ? RoomGlass.ink.opacity(0.72) : RoomGlass.ink)
                            }
                            Spacer(minLength: 0)
                            if let voice = line.voice {
                                Button { engine.audio.replayVoice(voice) } label: {
                                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 22 * scale))
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Play voice")
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.trailing, 12 * scale)
            }
            .onAppear { reader.scrollTo(engine.history.count - 1, anchor: .bottom) }
        }
    }
}

private struct SavePanel: View {
    let engine: StoryEngine
    let saving: Bool
    let close: () -> Void
    private let store = SaveStore.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        let _ = store.revision
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18 * scale), count: 3), spacing: 18 * scale) {
                ForEach(slots, id: \.self) { slot in
                    SlotCard(slot: slot, save: store.read(slot), enabled: saving ? slot != SaveStore.autoSlot && engine.currentSave != nil : store.exists(slot)) {
                        if saving {
                            if let save = engine.currentSave { store.write(save, slot: slot) }
                        } else if let save = store.read(slot) {
                            engine.load(save)
                            close()
                        }
                    }
                }
            }
        }
    }

    private var slots: [String] {
        (saving ? [] : [SaveStore.autoSlot]) + [SaveStore.quickSlot] + (1...store.slotCount).map { "slot\($0)" }
    }
}

private struct SlotCard: View {
    let slot: String
    let save: SaveData?
    let enabled: Bool
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8 * scale) {
                ZStack {
                    Color.black
                    if let name = save?.stage.sprites["BG"]?.image, let image = ArtLibrary.shared.image(name) {
                        Image(uiImage: image).resizable().aspectRatio(4 / 3, contentMode: .fill)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14 * scale))
                Text(label).font(.game(20 * scale, weight: .semibold))
                Text(save?.line?.text ?? "Empty")
                    .font(.game(17 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(14 * scale)
            .background(.black.opacity(0.05), in: .rect(cornerRadius: 22 * scale))
            .contentShape(.hoverEffect, .rect(cornerRadius: 22 * scale))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var label: String {
        let name = slot == SaveStore.autoSlot ? "Auto" : slot == SaveStore.quickSlot ? "Quick" : "No. \(slot.dropFirst(4))"
        guard let date = save?.date else { return name }
        return "\(name) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct SettingsPanel: View {
    let engine: StoryEngine
    @Bindable var settings = Settings.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26 * scale) {
                section("Text")
                slider("Text Speed", value: $settings.textSpeed, range: 0...120, label: settings.textSpeed == 0 ? "Instant" : "\(Int(settings.textSpeed)) cps")
                slider("Auto Delay", value: $settings.autoDelay, range: 0.3...5, label: String(format: "%.1f s", settings.autoDelay))
                slider("Text Size", value: $settings.textScale, range: 0.8...1.4, label: "\(Int(settings.textScale * 100))%")
                Toggle("Only Skip Already-Read Text", isOn: $settings.skipReadOnly)
                Toggle("Keep Skipping After Choices", isOn: $settings.keepSkippingAfterChoices)
                section("Sound")
                slider("Music", value: $settings.musicVolume, range: 0...1, label: "\(Int(settings.musicVolume * 100))%")
                slider("Effects", value: $settings.effectsVolume, range: 0...1, label: "\(Int(settings.effectsVolume * 100))%")
                slider("Voices", value: $settings.voiceVolume, range: 0...1, label: "\(Int(settings.voiceVolume * 100))%")
                Toggle("Mute All", isOn: $settings.muted)
                section("Scene")
                Toggle("Transitions", isOn: $settings.transitions)
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Toggle("Spatial Scenes", isOn: $settings.spatialScenes)
                    Text(SpatialSceneLibrary.shared.isSupported
                         ? "Backgrounds and event CGs gain depth behind the window. Each takes a few seconds to prepare."
                         : "Not available on this device; pictures stay flat.")
                        .font(.game(18 * scale))
                        .foregroundStyle(.secondary)
                }
                slider("Character Depth", value: $settings.characterDepth, range: 0...1, label: "\(Int(settings.characterDepth * 100))%")
                section("Content")
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Toggle("Gory CG Variants", isOn: $settings.goreVariants)
                    Toggle("Waste Matter CG Variants", isOn: $settings.fecesVariants)
                    Toggle("Orgasm Expression Variants", isOn: $settings.orgasmVariants)
                    Text("The original's content options. Turned off, scenes show the milder versions of these pictures from the next one on.")
                        .font(.game(18 * scale))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Toggle("Classic Bonus Menu", isOn: $settings.classicBonus)
                    Text("Shows the gallery, scene replay, music and staff comments with the original PC layout.")
                        .font(.game(18 * scale))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.game(24 * scale))
            .padding(.trailing, 20 * scale)
            // The panel's ink would draw switches black when on, and sliders too heavy.
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .tint(Color(white: 0.42))
        }
        .onChange(of: settings.musicVolume) { engine.audio.refreshVolumes() }
        .onChange(of: settings.effectsVolume) { engine.audio.refreshVolumes() }
        .onChange(of: settings.voiceVolume) { engine.audio.refreshVolumes() }
        .onChange(of: settings.muted) { engine.audio.refreshVolumes() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.game(28 * scale, weight: .semibold)).padding(.top, 8 * scale)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 20 * scale) {
            Text(title).frame(width: 230 * scale, alignment: .leading)
            Slider(value: value, in: range)
            Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 130 * scale, alignment: .trailing)
        }
    }
}
