import Foundation

/// A session as this SDK defines it: one period of use, ended by `sessionTimeout` of inactivity
/// rather than by every trip to the background. It is persisted so a session survives the app
/// being killed and relaunched inside the timeout, and so the session it replaces can still be
/// closed with an accurate duration.
struct SessionState: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    /// Last event or backgrounding. The timeout is measured from here, and a `session_ended`
    /// emitted later is timestamped here so it lands on the day the use actually happened.
    var lastActivityAt: Date
    /// Foreground time banked so far, which is what `duration_seconds` reports.
    var engagedSeconds: Double
}

actor AnalyticsClient {
    /// Reported on every event. Bump it with each tagged release so the data can tell installs apart.
    static let sdkVersion = "0.2.0"

    private let projectKey: String
    private let configuration: AnalyticsConfiguration
    private let persistence: AnalyticsPersistence
    private let transport: AnalyticsTransport
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let stateEncoder = JSONEncoder()
    private let stateDecoder = JSONDecoder()
    private let formatter: ISO8601DateFormatter
    private var queue: [AnalyticsEvent] = []
    private var enabled: Bool
    private var installationId: UUID
    private var installationSecret: String?
    private var sessionId = UUID()
    private var session: SessionState?
    /// When the current uninterrupted foreground stretch began, or nil while backgrounded.
    private var foregroundSince: Date?
    private var isFlushing = false
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    /// False until `start()` has loaded the installation and restored the session. The actor is
    /// reentrant, so a launch's `didBecomeActive` or an early `track` could otherwise run while
    /// `start()` is suspended on persistence, and open a session under a throwaway installation id.
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    private var installationKey: String { "asa.\(projectKey).installation_id" }
    private var secretKey: String { "asa.\(projectKey).installation_secret" }
    private var firstOpenKey: String { "asa.\(projectKey).first_open_sent" }
    private var sessionKey: String { "asa.\(projectKey).session" }

    init(
        projectKey: String,
        configuration: AnalyticsConfiguration,
        persistence: AnalyticsPersistence,
        transport: AnalyticsTransport = URLSessionAnalyticsTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectKey = projectKey
        self.configuration = configuration
        self.persistence = persistence
        self.transport = transport
        self.now = now
        self.enabled = configuration.collectionEnabled
        self.installationId = UUID()
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() async {
        defer { markStarted() }
        queue = await persistence.loadEvents()
        if let stored = await persistence.string(for: installationKey), let id = UUID(uuidString: stored) {
            installationId = id
        } else {
            await persistence.setString(installationId.uuidString.lowercased(), for: installationKey)
        }
        installationSecret = await persistence.string(for: secretKey)
        guard enabled else { return }
        await restoreSession()
        // The session is settled before `first_open` is appended so that the very first event of an
        // installation carries the session it actually belongs to. It used to be stamped with a
        // throwaway identifier that no other event ever shared.
        let started = await rotateSessionIfNeeded()
        if !(await persistence.bool(for: firstOpenKey)) {
            await append(name: "first_open", properties: [:])
            await persistence.setBool(true, for: firstOpenKey)
        }
        if started { await append(name: "session_started", properties: [:]) }
    }

    func currentInstallationId() -> UUID { installationId }

    private func markStarted() {
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func setCollectionEnabled(_ value: Bool) async {
        await waitUntilStarted()
        enabled = value
        if value {
            if await rotateSessionIfNeeded() { await append(name: "session_started", properties: [:]) }
        } else {
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
            queue.removeAll()
            await persistence.saveEvents(queue)
        }
    }

    func track(_ name: String, properties: [String: AnalyticsValue]) async {
        await waitUntilStarted()
        guard enabled else { return }
        do { try EventValidator.validate(name: name, properties: properties) }
        catch {
            #if DEBUG
            print("[AppStoreAnalytics] Rejected event \(name): \(error)")
            #endif
            return
        }
        await append(name: name, properties: properties)
    }

    func enteredForeground() async {
        await waitUntilStarted()
        guard enabled else { return }
        // Every activation asks the same question (is the previous session still alive?) instead
        // of treating "did not come back from the background" as proof that it is not. An iOS
        // app becomes active again after a Control Centre pull, a notification banner or an
        // app-switcher peek without ever backgrounding, and those used to open a new session each.
        if await rotateSessionIfNeeded() { await append(name: "session_started", properties: [:]) }
    }

    func enteredBackground() async {
        await waitUntilStarted()
        guard enabled, var current = session else { return }
        // Backgrounding banks the foreground time and stops the clock. It does not end the session:
        // a session ends only when the timeout passes with no activity, which is the same rule the
        // products this data is compared against use.
        let moment = now()
        bankForegroundTime(into: &current, until: moment)
        current.lastActivityAt = moment
        session = current
        await persistSession()
        await flush()
    }

    func flush() async {
        guard enabled, !isFlushing, !queue.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batchEvents = Array(queue.prefix(50))
        do {
            let response = try await transport.send(
                batch: EventBatch(schemaVersion: 1, installationSecret: installationSecret, events: batchEvents),
                projectKey: projectKey,
                endpoint: configuration.endpoint
            )
            if let secret = response.installationSecret {
                installationSecret = secret
                await persistence.setString(secret, for: secretKey)
            }
            let sent = Set(batchEvents.map(\.id))
            queue.removeAll { sent.contains($0.id) }
            await persistence.saveEvents(queue)
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
        } catch {
            #if DEBUG
            print("[AppStoreAnalytics] Flush deferred: \(error)")
            #endif
            scheduleRetry()
        }
    }

    func reset(deleteRemoteData: Bool) async {
        if deleteRemoteData, let installationSecret {
            try? await transport.deleteInstallation(id: installationId, secret: installationSecret, projectKey: projectKey, endpoint: configuration.endpoint)
        }
        queue.removeAll()
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        await persistence.saveEvents(queue)
        await persistence.setString(nil, for: secretKey)
        await persistence.setBool(false, for: firstOpenKey)
        await persistence.setString(nil, for: sessionKey)
        installationSecret = nil
        installationId = UUID()
        await persistence.setString(installationId.uuidString.lowercased(), for: installationKey)
        sessionId = UUID()
        session = nil
        foregroundSince = nil
        if enabled { await start() }
    }

    /// Resumes the stored session when it is still inside the timeout, and otherwise closes it and
    /// opens a new one. Returns whether a new session began, so the caller can order
    /// `session_started` against the events around it.
    private func rotateSessionIfNeeded() async -> Bool {
        let moment = now()
        if var current = session, moment.timeIntervalSince(current.lastActivityAt) < configuration.sessionTimeout {
            // A foreground that follows a background restarts the clock; one that follows a
            // transient interruption never stopped it, so the stretch in progress is left alone.
            if foregroundSince == nil { foregroundSince = moment }
            current.lastActivityAt = moment
            session = current
            await persistSession()
            return false
        }
        if var expired = session {
            bankForegroundTime(into: &expired, until: expired.lastActivityAt)
            await endSession(expired)
        }
        let opened = SessionState(id: UUID(), startedAt: moment, lastActivityAt: moment, engagedSeconds: 0)
        session = opened
        sessionId = opened.id
        foregroundSince = moment
        await persistSession()
        return true
    }

    /// Closes an expired session, attributing the event to that session and timestamping it at the
    /// last activity it saw rather than at the moment the expiry was noticed.
    private func endSession(_ state: SessionState) async {
        sessionId = state.id
        session = nil
        foregroundSince = nil
        await persistence.setString(nil, for: sessionKey)
        await append(
            name: "session_ended",
            properties: ["duration_seconds": .integer(max(0, Int(state.engagedSeconds.rounded())))],
            at: state.lastActivityAt
        )
    }

    private func bankForegroundTime(into state: inout SessionState, until moment: Date) {
        guard let since = foregroundSince else { return }
        state.engagedSeconds += max(0, moment.timeIntervalSince(since))
        foregroundSince = nil
    }

    private func restoreSession() async {
        guard let stored = await persistence.string(for: sessionKey), let data = stored.data(using: .utf8) else { return }
        guard let state = try? stateDecoder.decode(SessionState.self, from: data) else { return }
        session = state
        sessionId = state.id
        // The process is new, so nothing is banked yet: the clock starts when the session is
        // resumed or replaced, a few statements from here.
        foregroundSince = nil
    }

    private func persistSession() async {
        guard let session, let data = try? stateEncoder.encode(session), let text = String(data: data, encoding: .utf8) else { return }
        await persistence.setString(text, for: sessionKey)
    }

    /// `at` backdates an event to when it happened. Only the deferred `session_ended` uses it, and
    /// a backdated event is never treated as activity: it is the record of activity already past.
    private func append(name: String, properties: [String: AnalyticsValue], at moment: Date? = nil) async {
        let occurredAt = moment ?? now()
        if moment == nil, var current = session {
            current.lastActivityAt = occurredAt
            session = current
            await persistSession()
        }
        let event = AnalyticsEvent(
            id: UUID(), name: name, timestamp: formatter.string(from: occurredAt), installationId: installationId,
            sessionId: sessionId, properties: properties, context: Self.context()
        )
        guard let encoded = try? encoder.encode(event), encoded.count <= 8 * 1_024 else { return }
        queue.append(event)
        if queue.count > configuration.maxQueueSize { queue.removeFirst(queue.count - configuration.maxQueueSize) }
        await persistence.saveEvents(queue)
        if queue.count >= configuration.flushAt { await flush() }
    }

    private func scheduleRetry() {
        guard enabled, retryTask == nil, !queue.isEmpty else { return }
        retryAttempt += 1
        let exponential = min(300.0, pow(2.0, Double(retryAttempt - 1)))
        let delay = exponential * Double.random(in: 0.75...1.25)
        let nanoseconds = UInt64(delay * 1_000_000_000)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.retryAfterDelay()
        }
    }

    private func retryAfterDelay() async {
        retryTask = nil
        await flush()
    }

    private static func context() -> EventContext {
        let info = Bundle.main.infoDictionary ?? [:]
        return EventContext(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown",
            platform: {
                #if os(iOS)
                "ios"
                #else
                "macos"
                #endif
            }(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sdkVersion: AnalyticsClient.sdkVersion
        )
    }
}
