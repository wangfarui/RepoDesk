import CoreFoundation
import Foundation

enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(data: Data) throws {
        self = try JSONValue(any: JSONSerialization.jsonObject(with: data))
    }

    init(any: Any) throws {
        switch any {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init(any:)))
        default:
            throw CocoaError(.propertyListReadCorrupt)
        }
    }

    func encodedData() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue)
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    private var anyValue: Any {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .number(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.anyValue)
        case .object(let values):
            values.mapValues(\.anyValue)
        }
    }
}

extension JSONValue {
    static func integer(_ value: Int) -> JSONValue {
        .number(Double(value))
    }

    static func uri(_ url: URL) -> JSONValue {
        .string(url.absoluteString)
    }
}
