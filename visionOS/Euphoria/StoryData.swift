import Foundation

/// An expression from the original scripts: a literal, a variable read, or an
/// operator applied to sub-expressions. Produced by tools/build_story.py.
indirect enum Expr: Decodable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case variable(String, [Expr])
    case reference(String)
    case op(String, [Expr])

    private struct Node: Decodable {
        let v: String?
        let i: [Expr]?
        let r: String?
        let o: String?
        let a: [Expr]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            let node = try container.decode(Node.self)
            if let name = node.v {
                self = .variable(name, node.i ?? [])
            } else if let name = node.r {
                self = .reference(name)
            } else if let name = node.o {
                self = .op(name, node.a ?? [])
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown expression")
            }
        }
    }
}

/// One instruction of a story script. See tools/build_story.py for the format.
struct Op: Decodable, Sendable {
    let op: String
    /// say: shown name, character, text (or text expression), waits for a click.
    let n: String?
    let c: String?
    let t: String?
    let e: Expr?
    let w: Bool?
    /// call: macro name and positional arguments.
    let m: String?
    let a: [Expr?]?
    /// if / elif: condition; if / elif / jmp: jump target.
    let q: Expr?
    let j: Int?
    /// go: label.
    let l: Expr?
    /// let: variable, operator, value (in e).
    let v: Expr?
    let o: String?
    /// wait: milliseconds.
    let ms: Double?
    /// x: an original command the app does not run.
    let cmd: String?
}

struct ScriptFile: Decodable, Sendable {
    let path: String
    let ops: [Op]
}

/// The converted story and its asset index, loaded from the app bundle.
final class StoryLibrary: @unchecked Sendable {
    static let shared = StoryLibrary()

    struct Index: Decodable {
        let scripts: [String: String]
        let labels: [String: [Int]]
        let bgm: [String: String]
        let names: [String: String]
        let assets: [String: String]
        let start: String
        let gallery: [GallerySet]
        let replays: [Replay]
        /// Music room tracks, in the original's order (files under bgm/).
        let music: [String]
        /// Staff comment labels, STAFF_01 ... STAFF_17.
        let staff: [String]
        /// Picture variants behind the content options ("gore", "feces", "orgasm"), lowercase.
        /// Gore lists [shown, without gore]; the others [both on, gore only, option only, neither].
        /// Absent from story data converted before they were added.
        let cutins: [String: [[String]]]?
    }

    /// A CG gallery entry: a thumbnail and its pictures, in the original's order.
    struct GallerySet: Decodable, Identifiable {
        let thumb: String
        let pictures: [String]
        /// The character tab it is listed under, 1–6.
        let group: Int
        var id: String { thumb }
    }

    /// A scene replay: its thumbnail and the label where the scene starts.
    struct Replay: Decodable, Identifiable {
        let thumb: String
        let label: String
        /// The character tab it is listed under, 1–6.
        let group: Int
        var id: String { label }
    }

    let root: URL
    let index: Index
    private var cache: [Int: ScriptFile] = [:]
    private let lock = NSLock()

    private init() {
        root = Bundle.main.url(forResource: "Game", withExtension: nil)!
        let data = try! Data(contentsOf: root.appending(path: "story/index.json"))
        index = try! JSONDecoder().decode(Index.self, from: data)
    }

    func script(_ id: Int) -> ScriptFile? {
        lock.lock()
        defer { lock.unlock() }
        if let script = cache[id] { return script }
        let url = root.appending(path: String(format: "story/%05d.json", id))
        guard let data = try? Data(contentsOf: url),
              let script = try? JSONDecoder().decode(ScriptFile.self, from: data) else {
            debugLog("Missing story script \(id)")
            return nil
        }
        cache[id] = script
        return script
    }

    func label(_ name: String) -> (script: Int, ip: Int)? {
        guard let entry = index.labels[name], entry.count == 2 else { return nil }
        return (entry[0], entry[1])
    }

    /// Resolves an original asset name ("bg_0011a", "bg/red", "KAN_M01_0071").
    func assetURL(_ name: String) -> URL? {
        var key = name.lowercased()
        if key.hasPrefix("ev/") || key.hasPrefix("bg/") || key.hasPrefix("tip/") || key.hasPrefix("stand/")
            || key.hasPrefix("thumb_") {
            if let path = index.assets[key] { return root.appending(path: path) }
            key = String(key[key.index(after: key.lastIndex(of: "/")!)...])
        }
        guard let path = index.assets[key] else { return nil }
        return root.appending(path: path)
    }

    func bgmURL(_ name: String) -> URL? {
        let file = index.bgm[name.lowercased()] ?? name.lowercased()
        return assetURL(file)
    }
}
