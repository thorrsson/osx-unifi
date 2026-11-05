import Foundation

/// A lossless JSON value. Editors round-trip full resource documents through this type so a
/// whole-object PUT preserves every documented setting the app does not expose in its forms.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw NetworkAPIError.incompatibleResponse }
        return try JSONValue(foundation: object)
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                if double.rounded() == double, abs(double) < 9_007_199_254_740_992 {
                    self = .int(Int(double))
                } else {
                    self = .double(double)
                }
            } else {
                self = .int(number.intValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = .object(try object.mapValues(JSONValue.init(foundation:)))
        default:
            throw NetworkAPIError.incompatibleResponse
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundation)
        case .object(let values): return values.mapValues(\.foundation)
        }
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let values) = self else { return nil }
            return values[key]
        }
        set {
            guard case .object(var values) = self else { return }
            values[key] = newValue
            self = .object(values)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data()) }
        catch { throw NetworkAPIError.incompatibleResponse }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
