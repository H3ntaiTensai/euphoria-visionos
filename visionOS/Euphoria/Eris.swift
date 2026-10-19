import Foundation

/// A tween requested by es.SP.A/X/Y/Z.SET: `from` nil starts at the current value.
struct TweenSpec {
    var from: Double?
    var to: Double
    var relative: Bool
    var ms: Double
    var curve: Int
}

/// The sprite the framework is building: es.SP.CG.SET / ST.SET and the
/// tween calls fill it in, es.SP.SET.SET applies it to a named sprite.
struct PendingSprite {
    var image: String?
    /// es.SP.ST.SET: crossfade a character's new pose over this many milliseconds.
    var crossfadeMs: Double?
    var alpha: TweenSpec?
    var x: TweenSpec?
    var y: TweenSpec?
    var z: TweenSpec?
    var transition: TweenSpec?
    var rule: String?
    var quakeX: (amplitude: Double, ms: Double)?
    var quakeY: (amplitude: Double, ms: Double)?
    var blur: TweenSpec?
    var swayX: (amplitude: Double, ms: Double)?
    var swayY: (amplitude: Double, ms: Double)?
    var holdMs: Double?
}

/// Native implementations of the ERIS framework calls the story makes.
extension StoryEngine {
    private var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    /// Seconds for an animation, honoring skip mode and the Transitions setting.
    func seconds(_ ms: Double) -> Double {
        guard !skipping, !catchingUp, settings.transitions, ms > 0 else { return 0 }
        return ms / 1000
    }

    private func tween(_ args: Args, _ fromIndex: Int) -> TweenSpec {
        TweenSpec(from: args.isCurrent(fromIndex) ? nil : args.double(fromIndex),
                  to: args.double(fromIndex + 1), relative: args.isRelative(fromIndex),
                  ms: args.double(fromIndex + 2), curve: args.int(fromIndex + 3))
    }

    func callFramework(_ name: String, _ args: Args, at here: Int) async {
        switch name {
        // Building sprites.
        case "es.SP.CG.SET":
            pending.image = args.string(2)
        case "es.SP.ST.SET", "es.SP.ST_G.SET":
            pending.image = args.string(2)
            pending.crossfadeMs = args.double(3)
        case "es.SP.A.SET": pending.alpha = tween(args, 1)
        case "es.SP.X.SET": pending.x = tween(args, 1)
        case "es.SP.Y.SET": pending.y = tween(args, 1)
        case "es.SP.Z.SET": pending.z = tween(args, 1)
        case "es.SP.TR.SET": pending.rule = args.string(1)
        case "es.SP.TP.SET": pending.transition = tween(args, 1)
        case "es.SP.QX.SET": pending.quakeX = (args.double(1), args.double(2))
        case "es.SP.QY.SET": pending.quakeY = (args.double(1), args.double(2))
        case "es.SP.NOP.SET": pending.holdMs = args.double(1)
        case "es.SP.BX.SET", "es.SP.BY.SET": pending.blur = tween(args, 1)
        case "es.SP.CLX.SET": pending.swayX = (args.double(1), args.double(2))
        case "es.SP.CLY.SET": pending.swayY = (args.double(1), args.double(2))
        case "es.SP.SET.SET":
            commit(args.string(1))
        case "es.SP.WA.SET":
            if let sprite = stage.sprites[args.string(1)] {
                await pause(until: sprite.busyUntil)
            }
        case "es.SP.DEL.SET":
            stage.sprites[args.string(1)] = nil
        case "es.SP.DELALL.SET", "es.SP.DELALL2.SET":
            removeAll(keeping: Set(args.strings(1...4).filter { !$0.isEmpty }))
        case "es.WA.SET":
            let ms = args.int(1)
            if ms < 0 { if !catchingUp { await waitForClick() } } else { await pause(seconds: Double(ms) / 1000) }

        // Scene macros.
        case "MAC.BG":
            await showBackground(args.string(1), kind: "bg", z: args.double(2, -1), ms: args.int(3, -1),
                                 rule: args.string(4))
        case "MAC.EV":
            await showBackground(args.string(1), kind: "ev", z: args.double(2, -1), ms: args.int(3, -1),
                                 rule: args.string(4))
            if args.int(8) != 0 {
                pending = PendingSprite(image: "ev/\(args.string(1))_w")
                commit("EV_W")
            }
        case "MAC.BG_C", "MAC.EV_C", "MAC.EV_G_C", "MAC.EV_G_O_C", "MAC.EV_G_A_C":
            var bg = stage.sprite(named: "BG")
            bg.image = args.string(1)
            bg.tint = vars.tint
            bg.previous = nil
            bg.fade = .constant(1)
            stage.sprites["BG"] = bg
            if name.hasPrefix("MAC.EV") { Progress.shared.sawCG(args.string(1)) }
        case "MAC.FOUT":
            line = nil
            var cover = stage.sprite(named: "LNO_FD")
            let color = args.string(3)
            cover.image = color.isEmpty ? "black" : color
            cover.previous = nil
            cover.rule = args.string(2).isEmpty ? nil : args.string(2)
            cover.alpha = Tween(from: 0, to: 256, start: now, duration: seconds(args.double(1)))
            stage.sprites["LNO_FD"] = cover
            await pause(until: cover.busyUntil)
            removeAll(keeping: [])
        case "MAC.FIN":
            guard var cover = stage.sprites["LNO_FD"] else { return }
            cover.rule = args.string(2).isEmpty ? nil : args.string(2)
            cover.alpha = Tween(from: cover.alpha.value(at: now), to: 0, start: now, duration: seconds(args.double(1)))
            stage.sprites["LNO_FD"] = cover
            if args.int(4) == 1 {
                await pause(until: cover.busyUntil)
                stage.sprites["LNO_FD"] = nil
            }
        case "MAC.FLASH":
            guard args.int(2) > 0 else { return }
            var flash = stage.sprite(named: "MAC_FLASH")
            flash.image = "white"
            flash.alpha = Tween(from: 256, to: 0, start: now, duration: max(seconds(args.double(1)), 0.05),
                                curve: args.int(3))
            stage.sprites["MAC_FLASH"] = flash
            if args.int(4) == 1 { await pause(until: flash.busyUntil) }

        // Camera tint for pictures loaded from now on (flashbacks: sepia).
        case "es.CM.SD.SET":
            vars.set(Variables.saturation, [], .int(args.int(1, Tint.neutralSaturation)))
        case "es.CM.MD.SET":
            vars.set(Variables.brightness, [], .int(args.int(1, Tint.neutralColor)))

        // Sound.
        case "es.SND":
            let channel = args.int(1)
            let file = args.string(2)
            if AudioDirector.kind(of: channel) == .voice, !file.isEmpty, (channel - 1) / 10 == 2 {
                lastVoice = file
            }
            if catchingUp {
                // Rebuilding an imported save's scene: remember the music, play nothing.
                if file.isEmpty { catchUpMusic[channel] = nil }
                else if args.int(5, 1) < 0, !AudioDirector.isLineVoice(channel) { catchUpMusic[channel] = .init(file: file, volume: args.int(4, -1) < 0 ? 1 : Float(args.int(4)) / 256, loops: true) }
                return
            }
            if AudioDirector.kind(of: channel) == .bgm, !file.isEmpty {
                Progress.shared.heardTrack(library.index.bgm[file.lowercased()] ?? file)
            }
            guard !(skipping && AudioDirector.kind(of: channel) == .voice) else { return }
            audio.play(channel: channel, file: file, fadeMs: args.int(3), volume: args.int(4, -1), loop: args.int(5, 1))

        // Choices.
        case "ES.SEL.GO":
            selection.labels = args.strings(1...10)
        case "ES.SEL.E":
            selection.enabled = (1...10).map { args.value($0).map(\.truthy) ?? true }
        case "ES.SEL.SET":
            await presentChoices(args.strings(1...10), at: here)
        case "ES.SEL.N":
            break
        case "ES.CSEL.SET":
            await presentHeroineSelection(at: here)

        // Progress and extras.
        case "es.RPMODE.CG.FLAG.SET":
            Progress.shared.unlockReplay(args.string(1))
        case "ES.SCENARIO.END":
            if replaying {
                returnToTitle()
            } else {
                Progress.shared.reachedEnding(args.int(1))
            }
        case "es.MOVIEPLAY.SET":
            let name = args.string(1)
            Progress.shared.sawMovie(name)
            if let url = library.assetURL(name) {
                await playMovie(url)
            } else {
                report("Missing movie \(name)")
            }

        case "es.TextSizeChange":
            let size = args.int(1, -1)
            textSize = size > 0 ? size : nil
        case "es.RND":
            // A random whole number from PINT to PINT2, returned in @54(1) (the eyecatch's random voice).
            let low = args.int(1), high = args.int(2)
            vars.set("@54", [1], .int(Int.random(in: min(low, high)...max(low, high))))

        // Bookkeeping the native app does not need: save positions, the
        // backlog, debug markers, camera presets, text counters, auto mode.
        case "es.POSDATA.SET", "es.GSD.SAVE", "es.MakeLog", "es.LSD.INIT", "es.SAVEDEL",
             "es.CM.GO.SET", "es.TEXTCOUNTMODE",
             "es.TEXTCOUNT1.SET", "es.TEXTCOUNT2.SET", "es.TEXTCOUNT1.SHOW.SET", "es.TEXTCOUNT2.SHOW.SET",
             "es.SP.FINISH.SET", "es.SP.BL.SET", "es.SP.SK.SET", "es.MG.AUTO", "es.MG.AUTO.END", "es.DAY.DEL.SET",
             "es.FSM.USR.LXYZ.INIT":
            break
        default:
            report("Unimplemented framework call \(name)")
        }
    }

    /// es.SP.SET.SET: apply what was built to the named sprite.
    func commit(_ name: String) {
        let time = now
        let isNew = stage.sprites[name] == nil
        var sprite = stage.sprite(named: name)
        if let image = pending.image {
            let fadeMs = pending.crossfadeMs ?? pending.transition?.ms ?? 0
            if !isNew, let old = sprite.image, old.lowercased() != image.lowercased() {
                sprite.previous = old
                sprite.fade = Tween(from: 0, to: 1, start: time, duration: seconds(fadeMs))
            } else {
                sprite.previous = nil
                sprite.fade = .constant(1)
                if isNew, pending.alpha == nil, pending.transition == nil, let ms = pending.crossfadeMs {
                    sprite.alpha = Tween(from: 0, to: 256, start: time, duration: seconds(ms))
                }
            }
            sprite.image = image
            sprite.tint = vars.tint
            if image.lowercased().hasPrefix("ev_") || image.lowercased().hasPrefix("ev/") {
                Progress.shared.sawCG(image)
            }
        }
        sprite.rule = pending.rule ?? sprite.rule
        func apply(_ spec: TweenSpec?, _ keyPath: WritableKeyPath<Sprite, Tween>) {
            guard let spec else { return }
            let current = sprite[keyPath: keyPath].value(at: time)
            let from = spec.from ?? current
            let to = spec.relative ? current + spec.to : spec.to
            sprite[keyPath: keyPath] = Tween(from: from, to: to, start: time, duration: seconds(spec.ms), curve: spec.curve)
        }
        apply(pending.alpha, \.alpha)
        apply(pending.x, \.x)
        apply(pending.y, \.y)
        apply(pending.z, \.z)
        if let transition = pending.transition {
            // A rule transition on its own: reveal (0→256) or hide (256→0) the sprite.
            let from = transition.from.map { min($0, 256) } ?? sprite.alpha.value(at: time)
            sprite.alpha = Tween(from: from, to: min(transition.to, 256), start: time, duration: seconds(transition.ms))
        }
        if pending.quakeX != nil || pending.quakeY != nil {
            let duration = max(pending.quakeX?.ms ?? 0, pending.quakeY?.ms ?? 0)
            sprite.quake = Quake(x: pending.quakeX?.amplitude ?? 0, y: pending.quakeY?.amplitude ?? 0,
                                 start: time, duration: seconds(duration))
        }
        if let spec = pending.blur {
            let current = sprite.blur?.value(at: time) ?? 0
            sprite.blur = Tween(from: spec.from ?? current, to: spec.relative ? current + spec.to : spec.to,
                                start: time, duration: seconds(spec.ms), curve: spec.curve)
        }
        if pending.swayX != nil || pending.swayY != nil {
            let period = max(pending.swayX?.ms ?? 0, pending.swayY?.ms ?? 0) / 1000
            sprite.sway = Sway(x: pending.swayX?.amplitude ?? 0, y: pending.swayY?.amplitude ?? 0,
                               period: max(period, 0.05), start: time)
        }
        if let hold = pending.holdMs {
            sprite.fade.duration = max(sprite.fade.duration, (time - sprite.fade.start) + seconds(hold))
        }
        stage.sprites[name] = sprite
        pending = PendingSprite()
    }

    private func removeAll(keeping names: Set<String>) {
        let keep = names.union(["LNO_FD", "MAC_FLASH"])
        stage.sprites = stage.sprites.filter { keep.contains($0.key) }
    }

    /// MAC.BG / MAC.EV: the new picture fades in over everything, then replaces the scene.
    private func showBackground(_ file: String, kind: String, z: Double, ms: Int, rule: String) async {
        line = nil
        let time = now
        var front = stage.sprite(named: "BGF")
        front.image = file
        front.tint = vars.tint
        front.previous = nil
        front.fade = .constant(1)
        front.rule = rule.isEmpty ? nil : rule
        front.z = .constant(z < 0 ? Screen.baseDepth : z)
        front.alpha = Tween(from: 0, to: 256, start: time, duration: seconds(Double(ms < 0 ? 500 : ms)))
        stage.sprites["BGF"] = front
        if kind == "ev" { Progress.shared.sawCG(file) }
        await pause(until: front.busyUntil)
        var background = stage.sprite(named: "BG")
        background.image = file
        background.tint = front.tint
        background.previous = nil
        background.fade = .constant(1)
        background.alpha = .constant(256)
        background.x = .constant(0)
        background.y = .constant(0)
        background.z = front.z
        background.quake = nil
        stage.sprites = stage.sprites.filter { ["LNO_FD", "MAC_FLASH"].contains($0.key) }
        stage.sprites["BG"] = background
    }

    private func presentChoices(_ texts: [String], at here: Int) async {
        let options = texts.enumerated().compactMap { index, text -> Choice? in
            let caption = Self.choiceCaption(text)
            guard !caption.isEmpty else { return nil }
            let enabled = index < selection.enabled.count ? selection.enabled[index] : true
            return Choice(index: index, text: caption, enabled: enabled)
        }
        guard !options.isEmpty else { return }
        abandonCatchUp()
        skipping = false
        markSavePoint(at: here)
        choices = options
        let picked = await waitForChoice()
        choices = nil
        guard picked >= 0, picked < selection.labels.count else { return }
        if let option = options.first(where: { $0.index == picked }) {
            history.append(Line(name: nil, who: nil, text: "▸ \(option.text)", voice: nil))
        }
        vars.set("$1110", [], .string(selection.labels[picked]))
        selection = Selection()
    }

    /// ES.CSEL: pick whose room to visit. Options 1–5 are open while @1136(8000 + n) is 1;
    /// the pick is returned in @1143(93, 5). Positions are from the original's screen design.
    private func presentHeroineSelection(at here: Int) async {
        let origins = [CGPoint(x: 89, y: 66), CGPoint(x: 513, y: 62), CGPoint(x: 30, y: 362),
                       CGPoint(x: 350, y: 331), CGPoint(x: 650, y: 344)]
        let buttons = origins.enumerated().compactMap { index, origin -> PictureButton? in
            vars.get("@1136", [8001 + index]).integer == 1 ? PictureButton(number: index + 1, origin: origin) : nil
        }
        guard !buttons.isEmpty else { return }
        abandonCatchUp()
        skipping = false
        markSavePoint(at: here)
        line = nil
        pictureChoices = buttons
        let picked = await waitForChoice()
        pictureChoices = nil
        guard picked > 0 else { return }
        vars.set("@1143", [93, 5], .int(picked))
    }

    /// "“Head towards the door.“" → "Head towards the door."
    static func choiceCaption(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"‘’ ").union(.whitespaces))
    }
}
