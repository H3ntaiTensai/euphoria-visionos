import Foundation
import Observation

/// Reader preferences.
@MainActor @Observable
final class Settings {
    static let shared = Settings()

    /// Characters per second for the text reveal; 0 shows text at once.
    var textSpeed: Double { didSet { save() } }
    /// Seconds auto mode waits after a line (plus time for its voice).
    var autoDelay: Double { didSet { save() } }
    var textScale: Double { didSet { save() } }
    var musicVolume: Double { didSet { save() } }
    var effectsVolume: Double { didSet { save() } }
    var voiceVolume: Double { didSet { save() } }
    var muted: Bool { didSet { save() } }
    /// Fades, slides and shakes; off shows each change at once.
    var transitions: Bool { didSet { save() } }
    /// Convert backgrounds and event art into spatial scenes.
    var spatialScenes: Bool { didSet { save() } }
    /// How far characters float in front of the background, 0 (flat) to 1.
    var characterDepth: Double { didSet { save() } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: ["textSpeed": 50.0, "autoDelay": 1.5, "textScale": 1.0, "musicVolume": 0.7,
                                     "effectsVolume": 0.9, "voiceVolume": 1.0, "muted": false, "transitions": true,
                                     "spatialScenes": true, "characterDepth": 0.6])
        textSpeed = defaults.double(forKey: "textSpeed")
        autoDelay = defaults.double(forKey: "autoDelay")
        textScale = defaults.double(forKey: "textScale")
        musicVolume = defaults.double(forKey: "musicVolume")
        effectsVolume = defaults.double(forKey: "effectsVolume")
        voiceVolume = defaults.double(forKey: "voiceVolume")
        muted = defaults.bool(forKey: "muted")
        transitions = defaults.bool(forKey: "transitions")
        spatialScenes = defaults.bool(forKey: "spatialScenes")
        characterDepth = defaults.double(forKey: "characterDepth")
    }

    private func save() {
        defaults.set(textSpeed, forKey: "textSpeed")
        defaults.set(autoDelay, forKey: "autoDelay")
        defaults.set(textScale, forKey: "textScale")
        defaults.set(musicVolume, forKey: "musicVolume")
        defaults.set(effectsVolume, forKey: "effectsVolume")
        defaults.set(voiceVolume, forKey: "voiceVolume")
        defaults.set(muted, forKey: "muted")
        defaults.set(transitions, forKey: "transitions")
        defaults.set(spatialScenes, forKey: "spatialScenes")
        defaults.set(characterDepth, forKey: "characterDepth")
    }
}

/// The original's global variables (@1134, $1135): flags shared by every save,
/// such as which routes the heroine selection offers. Documents/globals.json.
final class GlobalStore: @unchecked Sendable {
    static let shared = GlobalStore()
    private(set) var values: [String: Value]
    private let url = URL.documentsDirectory.appending(path: "globals.json")

    private init() {
        values = (try? JSONDecoder().decode([String: Value].self, from: Data(contentsOf: url))) ?? [:]
    }

    func update(_ globals: [String: Value]) {
        guard globals != values else { return }
        values = globals
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
    }
}

/// Unlocks that persist across playthroughs: seen event art, scene replays,
/// movies, endings. Documents/progress.json (tools/import_saves.py can write it).
@MainActor @Observable
final class Progress {
    static let shared = Progress()

    struct Stored: Codable {
        var seenCG: Set<String> = []
        var replays: Set<String> = []
        var tracks: Set<String> = []
        var movies: Set<String> = []
        var endings: Set<Int> = []

        init() {}

        // Fields added later may be missing from an older file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seenCG = try c.decodeIfPresent(Set<String>.self, forKey: .seenCG) ?? []
            replays = try c.decodeIfPresent(Set<String>.self, forKey: .replays) ?? []
            tracks = try c.decodeIfPresent(Set<String>.self, forKey: .tracks) ?? []
            movies = try c.decodeIfPresent(Set<String>.self, forKey: .movies) ?? []
            endings = try c.decodeIfPresent(Set<Int>.self, forKey: .endings) ?? []
        }
    }

    private(set) var stored: Stored
    private let url = URL.documentsDirectory.appending(path: "progress.json")

    private init() {
        stored = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))) ?? Stored()
    }

    var seenCG: Set<String> { stored.seenCG }
    var replays: Set<String> { stored.replays }
    var tracks: Set<String> { stored.tracks }

    /// A music room track ("m01", "rakuen_full") played in the story.
    func heardTrack(_ file: String) {
        let key = file.lowercased()
        guard !stored.tracks.contains(key) else { return }
        stored.tracks.insert(key)
        save()
    }

    /// Staff comment n (1-based) is open once the original sets @1134(8000 + n).
    func staffUnlocked(_ number: Int) -> Bool {
        GlobalStore.shared.values[Variables.key("@1134", [8000 + number])]?.integer == 1
    }

    func sawCG(_ name: String) {
        let key = (name as NSString).lastPathComponent.lowercased()
        guard !stored.seenCG.contains(key) else { return }
        stored.seenCG.insert(key)
        save()
    }

    func unlockReplay(_ label: String) {
        guard !stored.replays.contains(label) else { return }
        stored.replays.insert(label)
        save()
    }

    func sawMovie(_ name: String) {
        guard !stored.movies.contains(name) else { return }
        stored.movies.insert(name)
        save()
    }

    func reachedEnding(_ number: Int) {
        guard !stored.endings.contains(number) else { return }
        stored.endings.insert(number)
        save()
    }

    /// The original opens the extras menu once the game has been cleared (@1134(1000)).
    var extrasUnlocked: Bool {
        GlobalStore.shared.values[Variables.key("@1134", [1000])]?.integer == 1 || !stored.replays.isEmpty
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
    }
}

/// Save files in the app's Documents folder: numbered slots, a quick save, and
/// an automatic save at every line.
@MainActor @Observable
final class SaveStore {
    static let shared = SaveStore()
    static let autoSlot = "auto"
    static let quickSlot = "quick"
    /// Numbered slots: 30, or more when imported saves use higher numbers.
    var slotCount: Int {
        _ = revision
        let numbers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { $0.hasPrefix("slot") ? Int($0.dropFirst(4).dropLast(5)) : nil }
        return max(30, numbers.max() ?? 0)
    }

    /// Bumped on every write so lists refresh.
    private(set) var revision = 0
    private let folder: URL
    private let queue = DispatchQueue(label: "saves", qos: .utility)

    private init() {
        folder = URL.documentsDirectory.appending(path: "Saves")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func url(_ slot: String) -> URL { folder.appending(path: "\(slot).json") }

    /// Decoded saves, so lists don't re-read files on every redraw.
    private var cache: [String: SaveData] = [:]

    func write(_ data: SaveData, slot: String) {
        cache[slot] = data
        let url = url(slot)
        queue.async {
            guard let encoded = try? JSONEncoder().encode(data) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
        if slot != Self.autoSlot { revision += 1 }
    }

    func read(_ slot: String) -> SaveData? {
        if let save = cache[slot] { return save }
        queue.sync {}
        guard let data = try? Data(contentsOf: url(slot)) else { return nil }
        do {
            let save = try JSONDecoder().decode(SaveData.self, from: data)
            cache[slot] = save
            return save
        } catch {
            debugLog("Cannot read save \(slot): \(error)")
            return nil
        }
    }

    func exists(_ slot: String) -> Bool { FileManager.default.fileExists(atPath: url(slot).path) }
}
