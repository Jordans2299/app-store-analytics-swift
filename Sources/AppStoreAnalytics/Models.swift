import Foundation

public enum AnalyticsValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct AnalyticsConfiguration: Sendable {
    public var endpoint: URL
    public var collectionEnabled: Bool
    public var sessionTimeout: TimeInterval
    public var flushAt: Int
    public var maxQueueSize: Int

    public init(
        endpoint: URL = URL(string: "https://ingest.example.com/v1")!,
        collectionEnabled: Bool = true,
        sessionTimeout: TimeInterval = 30 * 60,
        flushAt: Int = 20,
        maxQueueSize: Int = 1_000
    ) {
        self.endpoint = endpoint
        self.collectionEnabled = collectionEnabled
        self.sessionTimeout = sessionTimeout
        self.flushAt = min(max(flushAt, 1), 50)
        self.maxQueueSize = min(max(maxQueueSize, 50), 1_000)
    }
}

struct EventContext: Codable, Sendable {
    let appVersion: String
    let appBuild: String
    let platform: String
    let osVersion: String
    let sdkVersion: String
}

struct AnalyticsEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let timestamp: String
    let installationId: UUID
    let sessionId: UUID
    let properties: [String: AnalyticsValue]
    let context: EventContext
}

struct EventBatch: Codable, Sendable {
    let schemaVersion: Int
    let installationSecret: String?
    let events: [AnalyticsEvent]
}

struct BatchResponse: Decodable, Sendable {
    let accepted: Int
    let duplicates: Int
    let installationSecret: String?
}

enum AnalyticsValidationError: Error, Equatable {
    case invalidEventName
    case tooManyProperties
    case blockedProperty(String)
    case stringTooLong(String)
    case eventTooLarge
}

enum EventValidator {
    static let blockedKeys: Set<String> = ["address", "advertising_id", "email", "idfa", "name", "phone", "user", "user_id", "userid"]

    static func validate(name: String, properties: [String: AnalyticsValue]) throws {
        let expression = try NSRegularExpression(pattern: "^[a-z][a-z0-9_]{0,63}$")
        let range = NSRange(location: 0, length: name.utf16.count)
        guard expression.firstMatch(in: name, range: range) != nil else { throw AnalyticsValidationError.invalidEventName }
        guard properties.count <= 25 else { throw AnalyticsValidationError.tooManyProperties }
        for (key, value) in properties {
            guard key.count <= 64 else { throw AnalyticsValidationError.stringTooLong(key) }
            guard !blockedKeys.contains(key.lowercased()) else { throw AnalyticsValidationError.blockedProperty(key) }
            if case .string(let string) = value, string.count > 256 { throw AnalyticsValidationError.stringTooLong(key) }
        }
    }
}

