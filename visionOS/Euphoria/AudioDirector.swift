import AVFoundation

/// Plays the original's sound channels. Channels come in groups of ten:
/// 1–10 BGM, 11–20 sound effects, 21–30 voice, 41–50 more effects,
/// 51–60 and 81–90 looping background voices, 111–120 system voices (the title call).
@MainActor
final class AudioDirector {
    enum Kind: String, Codable { case bgm, se, voice }

    struct Playing: Codable, Equatable {
        var file: String
        var volume: Float
        var loops: Bool
    }

    private var players: [Int: AVAudioPlayer] = [:]
    /// Each playing channel's own volume (es.SND's), 0–1, before the settings apply.
    private var levels: [Int: Float] = [:]
    /// What each looping channel is playing, so a save can restore the music.
    private(set) var looping: [Int: Playing] = [:]
    var settings = Settings.shared
    /// The music's volume while a line is voiced (es.SND.SETVOL.TASK's @2496):
    /// 1, or the original's voice highlight level, 180/256.
    private var duck: Float = 1
    /// The background voices' volume (51–60, 81–90): 0 while a line is voiced, so a
    /// heroine's looping breaths and moans never play over her own spoken lines.
    private var backgroundVoices: Float = 1
    /// Music and effects while a voice replays from the History panel: lower than the
    /// voice highlight, so the old line stands out (the original's backlog only applies
    /// the highlight).
    private var replayLevel: Float = 1
    static let historyReplayLevel: Float = 0.3
    private var duckWatcher: Task<Void, Never>?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
    }

    static func kind(of channel: Int) -> Kind {
        switch (channel - 1) / 10 {
        case 0: .bgm
        case 2, 5, 8, 11, 14: .voice
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

    /// How many times a sound plays, as YU-RIS counts: 0 is forever. -1 takes the
    /// channel group's default from es.SND (ten channels per group): music, effects
    /// on 31–100 and background voices loop; effects on 11–20, line voices and the
    /// system groups play once.
    static func plays(channel: Int, loop: Int) -> Int {
        if loop >= 0 { return loop }
        switch (channel - 1) / 10 {
        case 1, 2, 10, 11, 13, 14: return 1
        default: return 0
        }
    }

    /// Music groups the original lowers under a voiced line: 1–10, 31–40, 61–70.
    private static func isDucked(_ channel: Int) -> Bool { [0, 3, 6].contains((channel - 1) / 10) }

    /// es.SND's music groups (1–10, 31–40, 61–70, 91–100, 121–130), which the original
    /// treats specially: a track already playing isn't restarted, and changes fade.
    static func isMusicGroup(_ channel: Int) -> Bool { [0, 3, 6, 9, 12].contains((channel - 1) / 10) }

    /// The fade es.SND uses when the script gives none (-1): a second (@1138(25, 1))
    /// for music fading out, and for music fading in over a track it replaces; none
    /// for anything else.
    private static let musicFadeMs = 1000

    /// Looping background voices: 51–60 and 81–90.
    private static func isBackgroundVoice(_ channel: Int) -> Bool { [5, 8].contains((channel - 1) / 10) }

    private func target(_ channel: Int) -> Float {
        let kind = Self.kind(of: channel)
        // Music takes the lower of the voice highlight and a History replay's level.
        let lowered: Float = Self.isDucked(channel) ? min(duck, replayLevel) : kind == .voice ? 1 : replayLevel
        return (levels[channel] ?? 1) * gain(kind) * lowered * (Self.isBackgroundVoice(channel) ? backgroundVoices : 1)
    }

    /// es.SND: an empty file stops the channel (fading over `fadeMs`; -1 is the
    /// channel's default fade).
    func play(channel: Int, file: String, fadeMs: Int, volume: Int, loop: Int) {
        let kind = Self.kind(of: channel)
        let music = Self.isMusicGroup(channel)
        let fadeOut = fadeMs >= 0 ? fadeMs : (music ? Self.musicFadeMs : 0)
        if file.isEmpty {
            stop(channel: channel, fadeMs: fadeOut)
            return
        }
        let level = volume < 0 ? 1 : Float(volume) / 256
        if music, let current = looping[channel], current.file.lowercased() == file.lowercased(),
           let player = players[channel], player.isPlaying {
            // The track asked for is already playing: as the original, it carries on
            // and only its volume follows.
            levels[channel] = level
            looping[channel]?.volume = level
            player.setVolume(target(channel), fadeDuration: Double(max(fadeMs, 0)) / 1000)
            return
        }
        let library = StoryLibrary.shared
        guard let url = kind == .bgm ? library.bgmURL(file) : library.assetURL(file) else {
            debugLog("Missing sound \(file)")
            return
        }
        // The sound it replaces fades out underneath (a crossfade for music).
        let replacing = players[channel] != nil
        stop(channel: channel, fadeMs: replacing ? fadeOut : 0)
        let fadeIn = fadeMs >= 0 ? fadeMs : (music && replacing ? Self.musicFadeMs : 0)
        if Self.isLineVoice(channel) {
            // One spoken line at a time, as the original cuts the last one off.
            for other in players.keys where other != channel && Self.isLineVoice(other) {
                stop(channel: other, fadeMs: 0)
            }
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            debugLog("Cannot play \(url.lastPathComponent)")
            return
        }
        let plays = Self.plays(channel: channel, loop: loop)
        let loopsForever = plays == 0
        player.numberOfLoops = loopsForever ? -1 : plays - 1
        levels[channel] = level
        players[channel] = player
        if Self.isLineVoice(channel) {
            // A story line's voice ends any History replay's lowering (replayVoice sets it again).
            setReplayLevel(1, seconds: 0.3)
            duckForVoice()
        }
        let target = target(channel)
        if fadeIn > 0 {
            player.volume = 0
            player.play()
            player.setVolume(target, fadeDuration: Double(fadeIn) / 1000)
        } else {
            player.volume = target
            player.play()
        }
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
        levels[channel] = nil
        guard let player = players.removeValue(forKey: channel) else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "traceSound") { debugLog("SND ch\(channel) stop fade=\(fadeMs)") }
        #endif
        if fadeMs > 0 {
            player.setVolume(0, fadeDuration: Double(fadeMs) / 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(fadeMs) / 1000) { player.stop() }
        } else {
            player.stop()
        }
    }

    /// While a line is voiced: the music fades to 180/256 over a second, as the
    /// original's voice highlight (es.SND.SETVOL.TASK); and the background voices fade
    /// out quickly, so they fill only the gaps between spoken lines. Once no line is
    /// voiced, the music comes back over a second and the background voices over half.
    private func duckForVoice() {
        setDuck(180 / 256, seconds: 1)
        setBackgroundVoices(0, seconds: 0.15)
        guard duckWatcher == nil else { return }
        duckWatcher = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if !self.isLineVoicePlaying {
                    self.setDuck(1, seconds: 1)
                    self.setReplayLevel(1, seconds: 1)
                    self.setBackgroundVoices(1, seconds: 0.5)
                    self.duckWatcher = nil
                    return
                }
            }
        }
    }

    private func setDuck(_ value: Float, seconds: Double) {
        guard duck != value else { return }
        duck = value
        for (channel, player) in players where Self.isDucked(channel) {
            player.setVolume(target(channel), fadeDuration: seconds)
        }
    }

    private func setReplayLevel(_ value: Float, seconds: Double) {
        guard replayLevel != value else { return }
        replayLevel = value
        for (channel, player) in players where Self.kind(of: channel) != .voice {
            player.setVolume(target(channel), fadeDuration: seconds)
        }
    }

    private func setBackgroundVoices(_ value: Float, seconds: Double) {
        guard backgroundVoices != value else { return }
        backgroundVoices = value
        for (channel, player) in players where Self.isBackgroundVoice(channel) {
            player.setVolume(target(channel), fadeDuration: seconds)
        }
    }

    private var isLineVoicePlaying: Bool {
        players.contains { channel, player in Self.isLineVoice(channel) && player.isPlaying }
    }

    /// Where a channel's sound is, for the music room's now-playing bar.
    func progress(channel: Int) -> (time: TimeInterval, duration: TimeInterval)? {
        players[channel].map { ($0.currentTime, $0.duration) }
    }

    /// Pauses or resumes a channel without losing its place.
    func setPaused(_ paused: Bool, channel: Int) {
        guard let player = players[channel] else { return }
        if paused { player.pause() } else { player.play() }
    }

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
        duckWatcher?.cancel()
        duckWatcher = nil
        duck = 1
        replayLevel = 1
        backgroundVoices = 1
    }

    /// A save's looping sounds (all of them loop forever).
    func restore(_ channels: [Int: Playing]) {
        stopAll()
        for (channel, sound) in channels {
            play(channel: channel, file: sound.file, fadeMs: 500, volume: Int(sound.volume * 256), loop: 0)
        }
    }

    /// Applies volume settings to what is already playing.
    func refreshVolumes() {
        for (channel, player) in players {
            player.volume = target(channel)
        }
    }

    /// Plays one voice file (from the history panel), with the other sounds lowered
    /// until it ends and the background voices silent, as under any spoken line.
    func replayVoice(_ file: String) {
        play(channel: 29, file: file, fadeMs: 0, volume: -1, loop: 1)
        guard players[29] != nil else { return }
        setReplayLevel(Self.historyReplayLevel, seconds: 0.3)
    }
}

/// The original's interface sounds (se/sys000–sys006), played on their own so any
/// view can use them. The original also plays sys001 when the pointer reaches a
/// button; visionOS doesn't tell apps where someone is looking, so that one is left out.
@MainActor
enum SystemSound {
    /// A button press (es.BT.SE.SET's second sound on the title and menus).
    static let click = "sys002"
    /// A tab or character selection in the bonus screens.
    static let tab = "sys005"

    private static var players: [AVAudioPlayer] = []

    static func play(_ name: String?) {
        let settings = Settings.shared
        guard let name, !settings.muted, settings.effectsVolume > 0,
              let url = StoryLibrary.shared.assetURL(name),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = Float(settings.effectsVolume)
        player.play()
        // Kept until finished; quick presses overlap as in the original.
        players.removeAll { !$0.isPlaying }
        players.append(player)
    }
}
