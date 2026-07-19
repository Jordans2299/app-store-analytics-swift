import Foundation

actor AnalyticsClient {
    private let projectKey: String
    private let configuration: AnalyticsConfiguration
    private let persistence: AnalyticsPersistence
    private let transport: AnalyticsTransport
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let formatter: ISO8601DateFormatter
    private var queue: [AnalyticsEvent] = []
    private var enabled: Bool
    private var installationId: UUID
    private var installationSecret: String?
    private var sessionId = UUID()
    private var sessionStartedAt: Date?
    private var lastBackgroundAt: Date?
    private var isFlushing = false
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?

    private var installationKey: String { "asa.\(projectKey).installation_id" }
    private var secretKey: String { "asa.\(projectKey).installation_secret" }
    private var firstOpenKey: String { "asa.\(projectKey).first_open_sent" }

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
        queue = await persistence.loadEvents()
        if let stored = await persistence.string(for: installationKey), let id = UUID(uuidString: stored) {
            installationId = id
        } else {
            await persistence.setString(installationId.uuidString.lowercased(), for: installationKey)
        }
        installationSecret = await persistence.string(for: secretKey)
        guard enabled else { return }
        if !(await persistence.bool(for: firstOpenKey)) {
            await append(name: "first_open", properties: [:])
            await persistence.setBool(true, for: firstOpenKey)
        }
        await beginSessionIfNeeded()
    }

    func currentInstallationId() -> UUID { installationId }

    func setCollectionEnabled(_ value: Bool) async {
        enabled = value
        if value {
            await beginSessionIfNeeded()
        } else {
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
            queue.removeAll()
            await persistence.saveEvents(queue)
        }
    }

    func track(_ name: String, properties: [String: AnalyticsValue]) async {
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
        guard enabled else { return }
        if let lastBackgroundAt, now().timeIntervalSince(lastBackgroundAt) < configuration.sessionTimeout {
            sessionStartedAt = now()
            self.lastBackgroundAt = nil
            return
        }
        await beginSessionIfNeeded(forceNew: true)
    }

    func enteredBackground() async {
        guard enabled, let started = sessionStartedAt else { return }
        let duration = max(0, Int(now().timeIntervalSince(started)))
        await append(name: "session_ended", properties: ["duration_seconds": .integer(duration)])
        sessionStartedAt = nil
        lastBackgroundAt = now()
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
        installationSecret = nil
        installationId = UUID()
        await persistence.setString(installationId.uuidString.lowercased(), for: installationKey)
        sessionId = UUID()
        sessionStartedAt = nil
        if enabled { await start() }
    }

    private func beginSessionIfNeeded(forceNew: Bool = false) async {
        guard sessionStartedAt == nil || forceNew else { return }
        sessionId = UUID()
        sessionStartedAt = now()
        await append(name: "session_started", properties: [:])
    }

    private func append(name: String, properties: [String: AnalyticsValue]) async {
        let event = AnalyticsEvent(
            id: UUID(), name: name, timestamp: formatter.string(from: now()), installationId: installationId,
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
            sdkVersion: "0.1.0"
        )
    }
}
