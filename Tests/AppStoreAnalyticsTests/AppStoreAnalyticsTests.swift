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
    func sentEvents() -> [AnalyticsEvent] { batches.flatMap(\.events) }
}

/// Persistence whose first `loadEvents` waits until the test releases it, to hold `start()` mid-way.
actor HeldPersistence: AnalyticsPersistence {
    var events: [AnalyticsEvent] = []
    var strings: [String: String] = [:]
    var bools: [String: Bool] = [:]
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    func loadEvents() async -> [AnalyticsEvent] {
        if !released {
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        return events
    }
    func waitUntilLoadIsHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func releaseLoad() { released = true; held?.resume(); held = nil }
    func saveEvents(_ value: [AnalyticsEvent]) { events = value }
    func string(for key: String) -> String? { strings[key] }
    func setString(_ value: String?, for key: String) { strings[key] = value }
    func bool(for key: String) -> Bool { bools[key] ?? false }
    func setBool(_ value: Bool, for key: String) { bools[key] = value }
    func eventSnapshot() -> [AnalyticsEvent] { events }
}

/// A clock the tests move by hand, so session expiry is exercised without waiting for it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_760_000_000)) { current = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(minutes: Double) { lock.lock(); current = current.addingTimeInterval(minutes * 60); lock.unlock() }
}

final class AppStoreAnalyticsTests: XCTestCase {
    /// Backgrounding flushes, so an event is either still queued or already sent. Both count.
    func allEvents(_ persistence: MemoryPersistence, _ transport: RecordingTransport) async -> [AnalyticsEvent] {
        await transport.sentEvents() + persistence.eventSnapshot()
    }

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

    func testBriefBackgroundResumesTheExistingSession() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport
        )
        await client.start()
        await client.enteredBackground()
        let sentEvents = await transport.sentEvents()
        let startedSession = sentEvents.first(where: { $0.name == "session_started" })?.sessionId
        await client.enteredForeground()
        await client.track("first_model_run", properties: [:])
        let queuedEvents = await persistence.eventSnapshot()
        let resumedEvent = queuedEvents.last

        XCTAssertEqual(resumedEvent?.sessionId, startedSession)
    }

    func testTransientActivationDoesNotOpenASecondSession() async throws {
        let persistence = MemoryPersistence()
        let clock = TestClock()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: RecordingTransport(), now: { clock.now() }
        )
        await client.start()
        // A Control Centre pull or a notification banner: the app becomes active again without
        // ever having entered the background.
        clock.advance(minutes: 1)
        await client.enteredForeground()
        clock.advance(minutes: 1)
        await client.enteredForeground()
        let events = await persistence.eventSnapshot()

        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func testFirstOpenSharesTheSessionItBelongsTo() async throws {
        let persistence = MemoryPersistence()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: RecordingTransport()
        )
        await client.start()
        let events = await persistence.eventSnapshot()
        let firstOpen = events.first(where: { $0.name == "first_open" })
        let sessionStarted = events.first(where: { $0.name == "session_started" })

        XCTAssertNotNil(firstOpen)
        XCTAssertEqual(firstOpen?.sessionId, sessionStarted?.sessionId)
    }

    func testInactivityEndsTheSessionAndOpensANewOne() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let clock = TestClock()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport, now: { clock.now() }
        )
        await client.start()
        clock.advance(minutes: 4)
        await client.enteredBackground()
        clock.advance(minutes: 31)
        await client.enteredForeground()
        let events = await allEvents(persistence, transport)
        let ended = events.first(where: { $0.name == "session_ended" })
        let starts = events.filter { $0.name == "session_started" }

        XCTAssertEqual(starts.count, 2)
        XCTAssertNotNil(ended)
        // Four minutes of foreground use, and none of the 31 minutes the app spent in the background.
        XCTAssertEqual(ended?.properties["duration_seconds"], .integer(240))
        XCTAssertEqual(ended?.sessionId, starts.first?.sessionId)
        XCTAssertNotEqual(starts.first?.sessionId, starts.last?.sessionId)
    }

    func testSessionSurvivesARelaunchInsideTheTimeout() async throws {
        let persistence = MemoryPersistence()
        let clock = TestClock()
        let configuration = AnalyticsConfiguration(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50)
        let transport = RecordingTransport()
        let first = AnalyticsClient(
            projectKey: "test", configuration: configuration,
            persistence: persistence, transport: transport, now: { clock.now() }
        )
        await first.start()
        await first.enteredBackground()
        clock.advance(minutes: 5)
        // The app was killed and launched again, which is a new process but the same session.
        let second = AnalyticsClient(
            projectKey: "test", configuration: configuration,
            persistence: persistence, transport: transport, now: { clock.now() }
        )
        await second.start()
        let events = await allEvents(persistence, transport)

        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(events.filter { $0.name == "first_open" }.count, 1)
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func testDeferredSessionEndIsTimestampedAtTheLastActivity() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let clock = TestClock()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport, now: { clock.now() }
        )
        await client.start()
        clock.advance(minutes: 2)
        await client.enteredBackground()
        let backgroundedAt = clock.now()
        clock.advance(minutes: 90)
        await client.enteredForeground()
        let events = await allEvents(persistence, transport)
        let ended = events.first(where: { $0.name == "session_ended" })

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(ended?.timestamp, formatter.string(from: backgroundedAt))
    }

    func makeClient(_ persistence: MemoryPersistence, _ transport: RecordingTransport, _ clock: TestClock) -> AnalyticsClient {
        AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport, now: { clock.now() }
        )
    }

    func testColdLaunchFollowedByActivationOpensOneSession() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let clock = TestClock()
        let client = makeClient(persistence, transport, clock)
        // Every cold launch: `configure` starts the client, then the launch's own didBecomeActive arrives.
        await client.start()
        await client.enteredForeground()
        await client.track("first_model_run", properties: [:])
        let events = await allEvents(persistence, transport)

        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func testActivationRacingStartStillOpensOneSession() async throws {
        let persistence = HeldPersistence()
        let storedInstallation = UUID()
        await persistence.setString(storedInstallation.uuidString.lowercased(), for: "asa.test.installation_id")
        await persistence.setBool(true, for: "asa.test.first_open_sent")
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: RecordingTransport()
        )
        // didBecomeActive and an early `track` reach the actor while `start()` is suspended loading
        // the queue. Without the start gate they open a session under a throwaway installation id.
        let started = Task { await client.start() }
        await persistence.waitUntilLoadIsHeld()
        let activated = Task { await client.enteredForeground() }
        let tracked = Task { await client.track("first_model_run", properties: [:]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await persistence.releaseLoad()
        _ = await (started.value, activated.value, tracked.value)
        let events = await persistence.eventSnapshot()

        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(events.filter { $0.name == "first_model_run" }.count, 1)
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
        XCTAssertEqual(Set(events.map(\.installationId)), [storedInstallation])
    }

    func testBackgroundInsideTheTimeoutKeepsOneSession() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let clock = TestClock()
        let client = makeClient(persistence, transport, clock)
        await client.start()
        await client.enteredForeground()
        clock.advance(minutes: 3)
        await client.enteredBackground()
        clock.advance(minutes: 29)
        await client.enteredForeground()
        let events = await allEvents(persistence, transport)

        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(events.filter { $0.name == "session_ended" }.count, 0)
        XCTAssertEqual(Set(events.map(\.sessionId)).count, 1)
    }

    func testMacFocusChangesInsideTheTimeoutDoNotEndTheSession() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let clock = TestClock()
        let client = makeClient(persistence, transport, clock)
        await client.start()
        await client.enteredForeground()
        // On macOS every click into another app is didResignActive, mapped to `enteredBackground`.
        for _ in 0..<10 {
            clock.advance(minutes: 2)
            await client.enteredBackground()
            clock.advance(minutes: 1)
            await client.enteredForeground()
        }
        var events = await allEvents(persistence, transport)
        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 1)
        XCTAssertEqual(events.filter { $0.name == "session_ended" }.count, 0)

        // Leaving it alone past the timeout closes that one session exactly once, with its
        // twenty minutes of focus and none of the ten spent in other apps.
        clock.advance(minutes: 2)
        await client.enteredBackground()
        clock.advance(minutes: 45)
        await client.enteredForeground()
        events = await allEvents(persistence, transport)
        let ended = events.filter { $0.name == "session_ended" }
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.properties["duration_seconds"], .integer(22 * 60))
        XCTAssertEqual(events.filter { $0.name == "session_started" }.count, 2)
    }

    func testEventsReportTheCurrentSDKVersion() async throws {
        let persistence = MemoryPersistence()
        let client = makeClient(persistence, RecordingTransport(), TestClock())
        await client.start()
        let events = await persistence.eventSnapshot()

        XCTAssertNotEqual(AnalyticsClient.sdkVersion, "0.1.0")
        XCTAssertEqual(Set(events.map(\.context.sdkVersion)), [AnalyticsClient.sdkVersion])
    }

    func testDisablingCollectionDeletesQueuedEvents() async throws {
        let persistence = MemoryPersistence()
        let transport = RecordingTransport()
        let client = AnalyticsClient(
            projectKey: "test", configuration: .init(endpoint: URL(string: "https://example.com/v1")!, flushAt: 50),
            persistence: persistence, transport: transport
        )
        await client.start()
        await client.track("first_model_run", properties: [:])
        await client.setCollectionEnabled(false)

        let events = await persistence.eventSnapshot()
        XCTAssertTrue(events.isEmpty)
    }
}
