import AVFoundation

/// Plays the original's sound channels. Channels come in groups of ten:
/// 1–10 BGM, 11–20 sound effects, 21–30 voice, 41–50 more effects,
/// 51–60 and 81–90 looping background voices.
@MainActor
final class AudioDirector {
    enum Kind: String, Codable { case bgm, se, voice }

    struct Playing: Codable, Equatable {
        var file: String
        var volume: Float
        var loops: Bool
    }

    private var players: [Int: AVAudioPlayer] = [:]
    /// What each looping channel is playing, so a save can restore the music.
    private(set) var looping: [Int: Playing] = [:]
    var settings = Settings.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
    }

    static func kind(of channel: Int) -> Kind {
        switch (channel - 1) / 10 {
        case 0: .bgm
        case 2, 5, 8: .voice
        default: .se
        }
    }

    private func gain(_ kind: Kind) -> Float {
        guard !settings.muted else { return 0 }
        let level: Double = switch kind {
        case .bgm: settings.musicVolume
        case .se: settings.effectsVolume
        case .voice: settings.voiceVolume
        }
        return Float(level)
    }

    /// es.SND: an empty file stops the channel (fading over `fadeMs`).
    func play(channel: Int, file: String, fadeMs: Int, volume: Int, loop: Int) {
        let kind = Self.kind(of: channel)
        if file.isEmpty {
            stop(channel: channel, fadeMs: fadeMs)
            return
        }
        let library = StoryLibrary.shared
        guard let url = kind == .bgm ? library.bgmURL(file) : library.assetURL(file) else {
            debugLog("Missing sound \(file)")
            return
        }
        players[channel]?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            debugLog("Cannot play \(url.lastPathComponent)")
            return
        }
        let level = volume < 0 ? 1 : Float(volume) / 256
        // -1 means "the channel's default": loop for music and background voices,
        // play once for spoken lines (channels 21–30).
        let loopsForever = loop < 0 && !Self.isLineVoice(channel)
        player.numberOfLoops = loopsForever ? -1 : max(loop - 1, 0)
        let target = level * gain(kind)
        if fadeMs > 0 {
            player.volume = 0
            player.play()
            player.setVolume(target, fadeDuration: Double(fadeMs) / 1000)
        } else {
            player.volume = target
            player.play()
        }
        players[channel] = player
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "traceSound") { debugLog("SND ch\(channel) \(file) loops=\(player.numberOfLoops)") }
        #endif
        if loopsForever {
            looping[channel] = Playing(file: file, volume: level, loops: true)
        } else {
            looping[channel] = nil
        }
    }

    func stop(channel: Int, fadeMs: Int) {
        looping[channel] = nil
        guard let player = players.removeValue(forKey: channel) else { return }
        if fadeMs > 0 {
            player.setVolume(0, fadeDuration: Double(fadeMs) / 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(fadeMs) / 1000) { player.stop() }
        } else {
            player.stop()
        }
    }

    /// Channels 21–30: the voice of the line on screen.
    static func isLineVoice(_ channel: Int) -> Bool { (channel - 1) / 10 == 2 }

    var isVoicePlaying: Bool {
        players.contains { channel, player in Self.kind(of: channel) == .voice && looping[channel] == nil && player.isPlaying }
    }

    /// Voices stop when the reader moves past their line.
    func stopVoices() {
        for channel in players.keys where Self.kind(of: channel) == .voice && looping[channel] == nil {
            stop(channel: channel, fadeMs: 0)
        }
    }

    func stopAll() {
        for channel in Array(players.keys) { stop(channel: channel, fadeMs: 0) }
    }

    func restore(_ channels: [Int: Playing]) {
        stopAll()
        for (channel, sound) in channels {
            play(channel: channel, file: sound.file, fadeMs: 500, volume: Int(sound.volume * 256), loop: -1)
        }
    }

    /// Applies volume settings to what is already playing.
    func refreshVolumes() {
        for (channel, player) in players {
            let level = looping[channel]?.volume ?? 1
            player.volume = level * gain(Self.kind(of: channel))
        }
    }

    /// Plays one voice file (from the history panel).
    func replayVoice(_ file: String) {
        play(channel: 29, file: file, fadeMs: 0, volume: -1, loop: 1)
    }
}
