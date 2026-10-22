import Foundation

/// A YU-RIS value: integer (`@` variables), float, or string (`$` variables).
enum Value: Codable, Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)

    // Stored as a plain JSON number or string (tools/import_saves.py writes these).
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let s): try container.encode(s)
        }
    }

    var number: Double {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        case .string(let s): Double(s) ?? 0
        }
    }

    var integer: Int {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        case .string(let s): Int(s) ?? 0
        }
    }

    var text: String {
        switch self {
        case .int(let v): String(v)
        case .double(let v): v == v.rounded() ? String(Int(v)) : String(v)
        case .string(let s): s
        }
    }

    var truthy: Bool {
        switch self {
        case .int(let v): v != 0
        case .double(let v): v != 0
        case .string(let s): !s.isEmpty
        }
    }

    var isString: Bool {
        if case .string = self { return true }
        return false
    }
}

/// Story variables. Arrays are stored per element under "name(i, j)".
struct Variables: Codable, Sendable {
    private(set) var values: [String: Value] = [:]

    /// Arrays the original keeps in its global save (gsd.sd) rather than per save:
    /// flags that persist across playthroughs, such as which routes are open.
    static let globalNames: Set<String> = ["@1134", "$1135"]

    var globals: [String: Value] {
        values.filter { key, _ in Self.globalNames.contains(String(key.prefix { $0 != "(" })) }
    }

    mutating func merge(_ other: [String: Value]) {
        values.merge(other) { _, new in new }
    }

    /// The framework's "keep the current value" markers in sprite animations.
    static let current = -99_999_999
    static let currentRelative = -99_999_998

    init() {
        values["@1078"] = .int(Self.current)
        values["@1076"] = .int(Self.currentRelative)
        values[Self.saturation] = .int(Tint.neutralSaturation)
        values[Self.brightness] = .int(Tint.neutralColor)
    }

    private enum CodingKeys: String, CodingKey { case values }

    /// A save's variables over the framework's starting values: saves imported from the
    /// PC game (tools/import_saves.py) lack them, and a missing camera tint reads as 0,
    /// which draws every picture black.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        merge(try container.decode([String: Value].self, forKey: .values))
    }

    /// The camera tint applied to pictures as they load (es.CM.SD.SET / es.CM.MD.SET).
    static let saturation = "@1085"
    static let brightness = "@1086"

    var tint: Tint? {
        let tint = Tint(saturation: get(Self.saturation).integer, color: get(Self.brightness).integer)
        return tint.isNeutral ? nil : tint
    }

    static func key(_ name: String, _ indices: [Int]) -> String {
        indices.isEmpty ? name : "\(name)(\(indices.map(String.init).joined(separator: ",")))"
    }

    func get(_ name: String, _ indices: [Int] = []) -> Value {
        if let value = values[Self.key(name, indices)] { return value }
        return name.hasPrefix("$") ? .string("") : .int(0)
    }

    mutating func set(_ name: String, _ indices: [Int] = [], _ value: Value) {
        if name.hasPrefix("$") {
            values[Self.key(name, indices)] = .string(value.text)
        } else if case .string = value {
            values[Self.key(name, indices)] = .int(value.integer)
        } else {
            values[Self.key(name, indices)] = value
        }
    }

    func evaluate(_ expr: Expr) -> Value {
        switch expr {
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let s): return .string(s)
        case .reference(let name): return .string(name)
        case .variable(let name, let indices):
            return get(name, indices.map { evaluate($0).integer })
        case .op(let name, let args):
            let values = args.map(evaluate)
            if values.count == 1 {
                let a = values[0]
                switch name {
                case "neg": return a.isInteger ? .int(-a.integer) : .double(-a.number)
                case "str": return .string(a.text)
                case "int": return .int(a.integer)
                default: return a
                }
            }
            guard values.count == 2 else { return .int(0) }
            return Self.apply(name, values[0], values[1])
        }
    }

    private static func apply(_ op: String, _ a: Value, _ b: Value) -> Value {
        func bool(_ v: Bool) -> Value { .int(v ? 1 : 0) }
        if a.isString || b.isString {
            switch op {
            case "+": return .string(a.text + b.text)
            case "==": return bool(a.text == b.text)
            case "!=": return bool(a.text != b.text)
            default: break
            }
        }
        let integers = a.isInteger && b.isInteger
        func arith(_ i: (Int, Int) -> Int, _ d: (Double, Double) -> Double) -> Value {
            integers ? .int(i(a.integer, b.integer)) : .double(d(a.number, b.number))
        }
        switch op {
        case "+": return arith(&+, +)
        case "-": return arith(&-, -)
        case "*": return arith(&*, *)
        case "/":
            if integers { return .int(b.integer == 0 ? 0 : a.integer / b.integer) }
            return .double(b.number == 0 ? 0 : a.number / b.number)
        case "%": return .int(b.integer == 0 ? 0 : a.integer % b.integer)
        case "==": return bool(a.number == b.number)
        case "!=": return bool(a.number != b.number)
        case "<": return bool(a.number < b.number)
        case ">": return bool(a.number > b.number)
        case "<=": return bool(a.number <= b.number)
        case ">=": return bool(a.number >= b.number)
        case "&&": return bool(a.truthy && b.truthy)
        case "||": return bool(a.truthy || b.truthy)
        case "&": return .int(a.integer & b.integer)
        case "|": return .int(a.integer | b.integer)
        case "^": return .int(a.integer ^ b.integer)
        default: return .int(0)
        }
    }
}

private extension Value {
    var isInteger: Bool {
        if case .int = self { return true }
        return false
    }
}
