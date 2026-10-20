import Foundation
import Observation

/// A line of dialogue or narration as the reader sees it.
struct Line: Codable, Equatable, Sendable {
    /// Shown speaker name ("???" while a character is still unknown).
    var name: String?
    /// The character behind the name, for colors.
    var who: String?
    var text: String
    var voice: String?
}

/// A picture button on the heroine selection screen (ES.CSEL).
struct PictureButton: Equatable, Identifiable {
    let number: Int
    /// Top-left corner on the original 1024×768 screen.
    let origin: CGPoint
    var id: Int { number }
    var art: String { String(format: "sys/csel/btn_c%02d_off", number) }
    var hover: String { String(format: "sys/csel/btn_c%02d_over", number) }
}

struct Choice: Equatable, Identifiable {
    let index: Int
    let text: String
    let enabled: Bool
    var id: Int { index }
}

/// The original's choice setup (ES.SEL.GO / ES.SEL.E), kept until ES.SEL.SET shows it.
struct Selection: Codable, Equatable {
    var labels: [String] = []
    var enabled: [Bool] = []
}

struct ReturnFrame: Codable, Equatable {
    var script: Int
    var ip: Int
}

/// Everything needed to resume the story at a line or a choice.
struct SaveData: Codable {
    var script: Int
    var ip: Int
    var frames: [ReturnFrame]
    var vars: Variables
    var stage: Stage
    var selection: Selection
    var music: [Int: AudioDirector.Playing]
    var line: Line?
    var date: Date
    /// Imported saves: replay silently from this instruction to `ip` to rebuild the
    /// scene, then restore `vars`. See tools/import_saves.py.
    var catchUpFrom: Int?
    /// Recent lines for the History panel, oldest first (absent in older saves).
    var history: [Line]?
}

/// Runs the converted story: the original's control flow and variables, with
/// the ERIS framework calls (see Eris.swift) implemented natively.
@MainActor @Observable
final class StoryEngine {
    enum Mode { case title, story }

    var mode: Mode = .title
    /// The line on screen.
    var line: Line?
    /// Counts lines shown, so a line identical to the previous one still reads as new.
    var lineSerial = 0
    var choices: [Choice]?
    /// The heroine selection screen, while it is shown.
    var pictureChoices: [PictureButton]?
    var stage = Stage()
    var history: [Line] = []
    /// True while the story waits for the reader to continue.
    var waitingForClick = false
    var skipping = false
    var autoPlay = false

    @ObservationIgnored var vars = Variables()
    @ObservationIgnored var selection = Selection()
    @ObservationIgnored var pending = PendingSprite()
    @ObservationIgnored let audio = AudioDirector()
    @ObservationIgnored let library = StoryLibrary.shared
    @ObservationIgnored var settings = Settings.shared
    /// The last voice started, attached to the next line for the history.
    @ObservationIgnored var lastVoice: String?

    @ObservationIgnored private var script = 0
    @ObservationIgnored private var ip = 0
    @ObservationIgnored private var frames: [ReturnFrame] = []
    // Observed: the Save and Q.Save controls enable once there is a point to save.
    private(set) var savePoint: SaveData?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var clickWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var choiceWaiter: CheckedContinuation<Int, Never>?
    @ObservationIgnored private var movieWaiter: CheckedContinuation<Void, Never>?
    /// The movie playing over the stage (opening, endings).
    var movie: URL?
    /// What the extras are replaying: a scene, or a staff comment.
    enum ReplayKind { case scene, staff }
    /// Set while replaying from the extras: no autosaves, and the end returns to its list.
    private(set) var replay: ReplayKind?
    var replaying: Bool { replay != nil }
    /// Set when a replay finishes, so the interface can reopen its list.
    var finishedReplay: ReplayKind?
    /// Message text size set by the script (es.TextSizeChange); nil is the original's 22.
    var textSize: Int?
    @ObservationIgnored private var skipWait = false
    /// When each named sprite event queue (es.SP.SET.SET's "E01", "E02") is free again.
    @ObservationIgnored var eventQueues: [String: TimeInterval] = [:]
    /// Pauses queued on sprites with nothing to draw, which es.SP.WA.SET still waits for.
    @ObservationIgnored var spriteHolds: [String: TimeInterval] = [:]
    @ObservationIgnored private var carriedText = ""
    /// Where the line being carried began: its first piece.
    @ObservationIgnored private var carriedStart = 0
    @ObservationIgnored private var carriedSpeaker: (String?, String?)?
    @ObservationIgnored private var reported: Set<String> = []
    /// While replaying an imported save up to its line: the target and the save's variables.
    @ObservationIgnored private var catchUp: (target: Int, script: Int, vars: Variables)?
    @ObservationIgnored var catchUpMusic: [Int: AudioDirector.Playing] = [:]
    var catchingUp: Bool { catchUp != nil }

    // MARK: - Starting and stopping

    func newGame(at label: String? = nil) {
        reset()
        guard jump(to: label ?? library.index.start) else { return }
        mode = .story
        prefetchScenes()
        run()
    }

    func load(_ data: SaveData) {
        reset()
        vars = data.vars
        vars.merge(GlobalStore.shared.values)
        stage = data.stage.settled
        history = data.history ?? []
        selection = data.selection
        frames = data.frames
        script = data.script
        ip = data.ip
        if let start = data.catchUpFrom, start < data.ip {
            var saved = data.vars
            saved.merge(GlobalStore.shared.values)
            catchUp = (data.ip, data.script, saved)
            catchUpMusic = [:]
            ip = start
        } else {
            audio.restore(data.music)
        }
        // The saved scene's picture first, then what follows it.
        if let sprite = stage.sprites["BG"], let background = sprite.image, SpatialSceneLibrary.isEligible(background),
           let source = SpatialSource(background, tint: sprite.tint) {
            SpatialSceneLibrary.shared.prefetch([source])
        }
        prefetchScenes()
        mode = .story
        run()
    }

    func returnToTitle() {
        stopRunner()
        audio.stopAll()
        if let replay { finishedReplay = replay }
        replay = nil
        mode = .title
    }

    /// Replays a scene or staff comment from the extras (the original's ES.RPMODE.JUMP and
    /// ES.STAFFMODE.JUMP): its label with the replay flag @1182 set (1 scene, 2 staff
    /// comment), which makes its end call ES.SCENARIO.END.
    func startReplay(_ label: String, kind: ReplayKind = .scene) {
        reset()
        guard jump(to: label) else { return }
        vars.set("@1182", [], .int(kind == .staff ? 2 : 1))
        replay = kind
        prefetchScenes()
        mode = .story
        run()
    }

    private func reset() {
        stopRunner()
        audio.stopAll()
        vars = Variables()
        vars.merge(GlobalStore.shared.values)
        catchUp = nil
        selection = Selection()
        pending = PendingSprite()
        stage = Stage()
        frames = []
        history = []
        line = nil
        choices = nil
        pictureChoices = nil
        carriedText = ""
        carriedSpeaker = nil
        // Loading a save in the middle of a replay leaves the replay.
        replay = nil
        eventQueues = [:]
        spriteHolds = [:]
        savePoint = nil
        textSize = nil
        skipping = false
        autoPlay = false
    }

    private func stopRunner() {
        runner?.cancel()
        runner = nil
        clickWaiter?.resume()
        clickWaiter = nil
        choiceWaiter?.resume(returning: -1)
        choiceWaiter = nil
        movieWaiter?.resume()
        movieWaiter = nil
        movie = nil
        waitingForClick = false
    }

    private func run() {
        runner?.cancel()
        runner = Task { [weak self] in await self?.loop() }
    }

    private func loop() async {
        var steps = 0
        while !Task.isCancelled, mode == .story {
            guard let file = library.script(script), ip < file.ops.count else {
                debugLog("Story ran off the end of script \(script)")
                returnToTitle()
                return
            }
            if let pending = catchUp, (script == pending.script && ip >= pending.target) {
                finishCatchUp()
            }
            let op = file.ops[ip]
            let here = ip
            ip += 1
            await execute(op, at: here)
            steps += 1
            if steps % 4000 == 0 { await Task.yield() }
        }
    }

    // MARK: - Instructions

    private func execute(_ op: Op, at here: Int) async {
        switch op.op {
        case "say":
            let text = op.t ?? op.e.map { vars.evaluate($0).text } ?? ""
            guard op.w ?? true else {
                // A line split around an inserted name ("Keisuke: “" + $1137(2000) + "!!”"):
                // the speaker is on the first piece, and a save resumes there.
                if carriedText.isEmpty {
                    carriedStart = here
                    if op.n != nil { carriedSpeaker = (op.n, op.c) }
                }
                carriedText += text
                return
            }
            if catchUp != nil {
                carriedText = ""
                carriedSpeaker = nil
                lastVoice = nil
                return
            }
            let speaker = op.n != nil ? (op.n, op.c) : carriedSpeaker ?? (nil, nil)
            let shown = Line(name: speaker.0, who: speaker.1, text: carriedText + text, voice: lastVoice)
            let start = carriedText.isEmpty ? here : carriedStart
            carriedText = ""
            carriedSpeaker = nil
            lastVoice = nil
            // "Only skip already-read text" (the original's option, off by default).
            let unread = ReadLog.shared.markRead(script: script, ip: start)
            if skipping, unread, settings.skipReadOnly, !replaying { skipping = false }
            line = shown
            lineSerial += 1
            markSavePoint(at: start)
            history.append(shown)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "traceLines") { debugLog("LINE \(library.index.scripts[String(script)] ?? "?") \(shown.name ?? "-"): \(shown.text.prefix(60))") }
            #endif
            if history.count > 300 { history.removeFirst(history.count - 300) }
            prefetchScenes()
            await waitForClick()
            audio.stopVoices()
        case "call":
            let name = op.m ?? op.e.map { vars.evaluate($0).text } ?? ""
            let args = Args(values: (op.a ?? []).map { $0.map(vars.evaluate) })
            if let target = library.label(name) {
                // A story-level helper written in the original script language.
                frames.append(ReturnFrame(script: script, ip: ip))
                for (n, value) in args.values.enumerated() {
                    guard let value else { continue }
                    vars.set("@50", [n + 1], value)
                    vars.set("@51", [n + 1], value)
                    vars.set("$52", [n + 1], value)
                }
                script = target.script
                ip = target.ip
            } else {
                await callFramework(name, args, at: here)
            }
        case "if":
            if let q = op.q, !vars.evaluate(q).truthy, let j = op.j { ip = j }
        case "elif":
            if let q = op.q, !vars.evaluate(q).truthy, let j = op.j { ip = j }
        case "jmp":
            if let j = op.j { ip = j }
        case "go":
            let name = op.l.map { vars.evaluate($0).text } ?? ""
            if !jump(to: name) { returnToTitle() }
        case "let":
            guard let target = op.v, let value = op.e else { return }
            assign(target, op.o ?? "=", vars.evaluate(value))
            if case .variable(let name, _) = target, Variables.globalNames.contains(name) {
                GlobalStore.shared.update(vars.globals)
            }
        case "wait":
            await pause(seconds: (op.ms ?? 0) / 1000)
        case "ret":
            if let frame = frames.popLast() {
                script = frame.script
                ip = frame.ip
            } else {
                returnToTitle()
            }
        case "end":
            returnToTitle()
        case "nop":
            break
        default:
            report("Unsupported command \(op.cmd ?? op.op)")
        }
    }

    @discardableResult
    func jump(to label: String) -> Bool {
        if let target = library.label(label) {
            script = target.script
            ip = target.ip
            return true
        }
        if label != "SCENARIO_TITLE" { debugLog("Unknown label \(label)") }
        return false
    }

    private func assign(_ target: Expr, _ op: String, _ value: Value) {
        guard case .variable(let name, let indexExprs) = target else { return }
        let indices = indexExprs.map { vars.evaluate($0).integer }
        let old = vars.get(name, indices)
        let result: Value
        switch op {
        case "+=": result = name.hasPrefix("$") ? .string(old.text + value.text) : .int(old.integer + value.integer)
        case "-=": result = .int(old.integer - value.integer)
        case "*=": result = .int(old.integer * value.integer)
        case "/=": result = .int(value.integer == 0 ? 0 : old.integer / value.integer)
        default: result = value
        }
        vars.set(name, indices, result)
    }

    func report(_ message: String) {
        guard !reported.contains(message) else { return }
        reported.insert(message)
        debugLog(message)
    }

    /// An imported save reached its line: restore its variables and the scene's music.
    private func finishCatchUp() {
        guard let pending = catchUp else { return }
        catchUp = nil
        // The save's flags, with the camera tint the replayed scene left in effect.
        let saturation = vars.get(Variables.saturation)
        let brightness = vars.get(Variables.brightness)
        vars = pending.vars
        vars.set(Variables.saturation, [], saturation)
        vars.set(Variables.brightness, [], brightness)
        stage = stage.settled
        eventQueues = [:]
        spriteHolds = [:]
        audio.restore(catchUpMusic)
        skipping = false
    }

    /// A choice met while catching up ends the replay there.
    func abandonCatchUp() {
        guard catchUp != nil else { return }
        debugLog("Catch-up stopped at a choice before the saved line")
        finishCatchUp()
    }

    // MARK: - Waiting

    /// Waits for the reader (tap, auto mode, or skip).
    func waitForClick() async {
        if catchUp != nil { return }
        if skipping {
            try? await Task.sleep(for: .milliseconds(30))
            return
        }
        waitingForClick = true
        await withCheckedContinuation { clickWaiter = $0 }
        waitingForClick = false
    }

    func waitForChoice() async -> Int {
        await withCheckedContinuation { choiceWaiter = $0 }
    }

    /// A timed pause; a tap ends it early and finishes running animations.
    func pause(seconds: Double) async {
        guard seconds > 0, !skipping, catchUp == nil, !Task.isCancelled else { return }
        skipWait = false
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end, !skipWait, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
        }
        if skipWait {
            stage = stage.settled
            eventQueues = [:]
            spriteHolds = [:]
            skipWait = false
        }
    }

    func pause(until time: TimeInterval) async {
        await pause(seconds: time - Date.timeIntervalSinceReferenceDate)
    }

    /// The reader's tap: continue past the line, or cut a pause short.
    func advance() {
        if let waiter = clickWaiter {
            clickWaiter = nil
            // Cut the line's voice the moment the reader moves on, before the story
            // runs ahead to the next one.
            audio.stopVoices()
            waiter.resume()
        } else if choices == nil && pictureChoices == nil {
            skipWait = true
        }
    }

    /// Plays a movie over everything and waits until it ends or the reader skips it.
    /// Skip mode doesn't pass over movies, as in the original: a tap ends one.
    func playMovie(_ url: URL) async {
        guard !catchingUp, !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            movieWaiter = continuation
            movie = url
        }
        movie = nil
    }

    /// The movie ended or was skipped.
    func movieFinished() {
        guard let waiter = movieWaiter else { return }
        movieWaiter = nil
        waiter.resume()
    }

    func choose(_ index: Int) {
        guard let waiter = choiceWaiter else { return }
        choiceWaiter = nil
        waiter.resume(returning: index)
    }

    /// Queues spatial scenes for the next backgrounds and event CGs the story will
    /// show, following jumps into other scripts. Branches are read in script order.
    func prefetchScenes() {
        guard settings.spatialScenes, SpatialSceneLibrary.shared.isSupported else { return }
        guard !skipping else {
            // Skipping outruns any prediction: drop it, and look ahead again once reading resumes.
            SpatialSceneLibrary.shared.lookahead([])
            return
        }
        // Upcoming pictures, under the tint in force now (a flashback's sepia carries on).
        var urls: [SpatialSource] = []
        let tint = vars.tint
        var cursor = (script: script, ip: ip)
        var strings: [String: String] = [:]
        var visited: Set<Int> = []
        var budget = 2000
        while budget > 0, urls.count < Self.lookaheadCount, let ops = library.script(cursor.script)?.ops,
              cursor.ip < ops.count {
            let op = ops[cursor.ip]
            cursor.ip += 1
            budget -= 1
            switch op.op {
            case "call":
                // MAC.BG / MAC.EV name the picture first; the sprite builder's es.SP.CG.SET
                // (how many CG variations are swapped in) names it second.
                guard let name = op.m else { continue }
                let argument = name.hasPrefix("MAC.BG") || name.hasPrefix("MAC.EV") ? 0 : name == "es.SP.CG.SET" ? 1 : nil
                guard let argument, let values = op.a, values.count > argument,
                      case .string(let named)? = values[argument] else { continue }
                // The variant the content options will show (MAC.EV's ninth argument picks the table).
                func number(_ index: Int) -> Int? {
                    guard index < values.count, case .int(let value)? = values[index] else { return nil }
                    return value
                }
                let picture = name == "MAC.EV" ? cutinVariant(named, type: 2, mode: number(8) ?? 0, unlock: false)
                    : name == "es.SP.CG.SET" ? cutinVariant(named, type: number(0) ?? 0, unlock: false) : named
                guard SpatialSceneLibrary.isEligible(picture), let source = SpatialSource(picture, tint: tint),
                      !urls.contains(source) else { continue }
                urls.append(source)
            case "let":
                if case .variable(let name, _)? = op.v, case .string(let value)? = op.e { strings[name] = value }
            case "go":
                var label: String?
                if case .string(let literal)? = op.l { label = literal }
                if case .variable(let name, _)? = op.l { label = strings[name] }
                if let label, let target = library.label(label), !visited.contains(target.script * 100_000 + target.ip) {
                    visited.insert(target.script * 100_000 + target.ip)
                    cursor = target
                }
            default:
                break
            }
        }
        SpatialSceneLibrary.shared.lookahead(urls)
    }

    /// How many upcoming pictures to prepare ahead of the reader.
    static let lookaheadCount = 4

    // MARK: - Saving

    func markSavePoint(at here: Int) {
        guard !replaying else { return }
        savePoint = SaveData(script: script, ip: here, frames: frames, vars: vars, stage: stage.settled,
                             selection: selection, music: audio.looping, line: line, date: .now,
                             history: Array(history.suffix(100)))
        if let savePoint { SaveStore.shared.write(savePoint, slot: SaveStore.autoSlot) }
    }

    var currentSave: SaveData? { savePoint.map { var copy = $0; copy.date = .now; return copy } }
}

/// Positional arguments of a framework call (1-based, as in the original).
struct Args {
    let values: [Value?]

    func value(_ n: Int) -> Value? { n >= 1 && n <= values.count ? values[n - 1] : nil }
    func int(_ n: Int, _ fallback: Int = 0) -> Int { value(n)?.integer ?? fallback }
    func double(_ n: Int, _ fallback: Double = 0) -> Double { value(n)?.number ?? fallback }
    func string(_ n: Int) -> String { value(n)?.text ?? "" }
    func strings(_ range: ClosedRange<Int>) -> [String] { range.map(string) }
    /// The framework's "start from the current value" markers.
    func isCurrent(_ n: Int) -> Bool {
        let v = int(n)
        return v == Variables.current || v == Variables.currentRelative
    }
    func isRelative(_ n: Int) -> Bool { int(n) == Variables.currentRelative }
}
