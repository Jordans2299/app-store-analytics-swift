import XCTest
@testable import AppStoreAnalytics

actor MemoryPersistence: AnalyticsPersistence {
    var events: [AnalyticsEvent] = []
    var strings: [String: String] = [:]
    var bools: [String: Bool] = [:]
    func loadEvents() -> [AnalyticsEvent] { events }
    func saveEvents(_ value: [AnalyticsEvent]) { events = value }
    func string(for key: String) -> String? { strings[key] }
    func setString(_ value: String?, for key: String) { strings[key] = value }
    func bool(for key: String) -> Bool { bools[key] ?? false }
    func setBool(_ value: Bool, for key: String) { bools[key] = value }
    func eventSnapshot() -> [AnalyticsEvent] { events }
}

actor RecordingTransport: AnalyticsTransport {
    var batches: [EventBatch] = []
    var deleted: [UUID] = []
    func send(batch: EventBatch, projectKey: String, endpoint: URL) async throws -> BatchResponse {
        batches.append(batch)
        return BatchResponse(accepted: batch.events.count, duplicates: 0, installationSecret: "a-secure-installation-secret-with-32-characters")
    }
    func deleteInstallation(id: UUID, secret: String, projectKey: String, endpoint: URL) async throws { deleted.append(id) }
    func batchCount() -> Int { batches.count }
}

final class AppStoreAnalyticsTests: XCTestCase {
    func testValidatorRejectsSensitiveKeys() throws {
        XCTAssertThrowsError(try EventValidator.validate(name: "purchase", properties: ["email": .string("private@example.com")]))
        XCTAssertNoThrow(try EventValidator.validate(name: "first_model_run", properties: ["model_family": .string("local")]))
    }

    func testFirstOpenSessionAndCustomEventAreQueued() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport
        )
        await client.start()
        await client.track("first_model_run", properties: [:])
        let events = await persistence.eventSnapshot()
        XCTAssertEqual(events.map(\.name), ["first_open", "session_started", "first_model_run"])
        XCTAssertEqual(Set(events.map(\.installationId)).count, 1)
    }

    func testFlushStoresInstallationSecretAndClearsQueue() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport
        )
        await client.start()
        await client.flush()
        let events = await persistence.eventSnapshot()
        let batchCount = await transport.batchCount()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(batchCount, 1)
    }
}
