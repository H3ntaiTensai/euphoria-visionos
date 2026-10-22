import Foundation

/// The original game's screen size. Positions in the scripts are in these pixels.
enum Screen {
    static let size = CGSize(width: 1024, height: 768)
    /// The depth at which a sprite is drawn at its natural size (scale = 200 / z).
    static let baseDepth = 200.0
}

/// A value moving from `from` to `to` over `duration` seconds from `start`.
struct Tween: Codable, Equatable, Sendable {
    var from: Double
    var to: Double
    var start: TimeInterval = 0
    var duration: Double = 0
    /// 0 linear, positive decelerates, negative accelerates (the original's accel flag).
    var curve: Int = 0

    static func constant(_ value: Double) -> Tween { Tween(from: value, to: value) }

    var end: TimeInterval { start + duration }

    func value(at time: TimeInterval) -> Double {
        // A change queued for later (a sprite event queue) holds its start value until then.
        guard duration > 0 else { return time < start ? from : to }
        let p = min(max((time - start) / duration, 0), 1)
        let eased: Double = curve > 0 ? 1 - (1 - p) * (1 - p) : curve < 0 ? p * p : p
        return from + (to - from) * eased
    }

    var settled: Tween { .constant(to) }
}

/// A decaying shake, from the original's QX / QY quake commands.
struct Quake: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var start: TimeInterval
    var duration: Double

    func offset(at time: TimeInterval) -> CGSize {
        let elapsed = time - start
        guard elapsed >= 0, elapsed < duration, duration > 0 else { return .zero }
        let decay = 1 - elapsed / duration
        let phase = elapsed * 2 * .pi * 14
        return CGSize(width: x * sin(phase) * decay, height: y * cos(phase * 1.3) * decay)
    }
}

/// The camera tint a picture was loaded under (es.CM.SD / es.CM.MD).
struct Tint: Codable, Hashable, Sendable {
    /// The original's saturation, 128 = unchanged.
    var saturation: Int
    /// Per-channel brightness as 0xRRGGBB, 0x808080 = unchanged.
    var color: Int

    static let neutralSaturation = 128
    static let neutralColor = 0x808080

    var isNeutral: Bool { saturation == Self.neutralSaturation && color == Self.neutralColor }
    var red: Double { Double((color >> 16) & 0xFF) / 128 }
    var green: Double { Double((color >> 8) & 0xFF) / 128 }
    var blue: Double { Double(color & 0xFF) / 128 }
}

/// A continuous shake that lasts until the sprite is changed (es.SP.CLX / CLY).
struct Sway: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    /// Seconds per cycle.
    var period: Double
    var start: TimeInterval

    func offset(at time: TimeInterval) -> CGSize {
        let phase = (time - start) / max(period, 0.02) * 2 * .pi
        return CGSize(width: x * sin(phase), height: y * sin(phase * 1.37))
    }
}

/// A named picture on the stage: background, event CG, character, overlay.
struct Sprite: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var image: String?
    /// The image being replaced, drawn until `fade` reaches 1.
    var previous: String?
    var fade = Tween.constant(1)
    /// A transition mask (cg/tr) for the fade, as in the original.
    var rule: String?
    /// Opacity in the original's 0–256 scale.
    var alpha = Tween.constant(256)
    var x = Tween.constant(0)
    var y = Tween.constant(0)
    var z = Tween.constant(Screen.baseDepth)
    var quake: Quake?
    var order: Int
    /// The tint the current picture was loaded under; nil when neutral.
    var tint: Tint?
    /// Blur in the original's units (es.SP.BX / BY); nil is sharp.
    var blur: Tween?
    var sway: Sway?
    /// es.SP.NOP.SET: the sprite counts as busy until then (es.SP.WA.SET waits for it).
    var holdUntil: TimeInterval?

    var busyUntil: TimeInterval {
        [fade.end, alpha.end, x.end, y.end, z.end, blur?.end ?? 0, quake.map { $0.start + $0.duration } ?? 0,
         holdUntil ?? 0].max() ?? 0
    }

    /// A background or event CG shown full screen, opaque and still: the moments a
    /// spatial scene can stand in for the flat picture. Usually the background, but
    /// scenes also lay whole event CGs over it on other layers (SP001, AVI_ONa,
    /// OBUTSU_ONa), often beside a cross-section; those cover it entirely.
    func isStillPicture(at time: TimeInterval) -> Bool {
        // A finished crossfade leaves `previous` set; once busyUntil has passed, the old
        // picture is no longer drawn. A camera tint is baked into the scene.
        guard !Self.covers.contains(id), let image, blur == nil, sway == nil, quake == nil,
              busyUntil <= time else { return false }
        // Drawn at its pixel size, so it covers the screen only when it is screen-sized.
        return alpha.to >= 256 && abs(x.to) < 0.5 && abs(y.to) < 0.5 && abs(z.to - Screen.baseDepth) < 0.5
            && SpatialSceneLibrary.isEligible(image)
            && (ArtLibrary.shared.pixelSize(image)?.width ?? 0) >= Screen.size.width - 1
    }

    /// Framework layers drawn over the scene (an event CG's overlay, the incoming
    /// background, fades, flashes) that never become spatial scenes themselves.
    private static let covers: Set<String> = ["EV_W", "BGF", "LNO_FD", "MAC_FLASH"]

    var settled: Sprite {
        var copy = self
        copy.previous = nil
        copy.fade = fade.settled
        copy.alpha = alpha.settled
        copy.x = x.settled
        copy.y = y.settled
        copy.z = z.settled
        copy.quake = nil
        copy.blur = blur?.settled
        copy.holdUntil = nil
        return copy
    }
}

struct Stage: Codable, Equatable, Sendable {
    var sprites: [String: Sprite] = [:]
    var nextOrder = 0

    /// Back to front. The framework's fixed layers keep their places; the rest stack by
    /// depth as the original's draw priority does (es.SP.DRAW: nearer, a smaller z, on
    /// top), and in creation order at the same depth. A cross-section at z 199.99 thus
    /// stays in front of the event CG laid over the background after it.
    var ordered: [Sprite] {
        sprites.values.sorted { a, b in
            guard Self.fixedOrder(a.id) == nil, Self.fixedOrder(b.id) == nil, a.z.to != b.z.to else {
                return a.order < b.order
            }
            return a.z.to > b.z.to
        }
    }

    var busyUntil: TimeInterval { sprites.values.map(\.busyUntil).max() ?? 0 }

    /// A sprite sways for as long as it is shown, so the stage keeps animating.
    var hasSway: Bool { sprites.values.contains { $0.sway != nil } }

    /// Layers the framework keeps at fixed depths; everything else stacks in creation order.
    static func fixedOrder(_ name: String) -> Int? {
        switch name {
        case "BG": -1_000_000
        case "EV_W": -999_999
        case "BGF": 900_000
        case "LNO_FD": 1_000_000
        case "MAC_FLASH": 1_000_001
        default: nil
        }
    }

    mutating func sprite(named name: String) -> Sprite {
        if let sprite = sprites[name] { return sprite }
        let order = Self.fixedOrder(name) ?? { nextOrder += 1; return nextOrder }()
        return Sprite(id: name, order: order)
    }

    var settled: Stage {
        var copy = self
        copy.sprites = sprites.mapValues(\.settled)
        return copy
    }
}
