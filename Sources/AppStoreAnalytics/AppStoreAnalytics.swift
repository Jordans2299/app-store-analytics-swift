import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum AppStoreAnalytics {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var client: AnalyticsClient?
        var observer: LifecycleObserver?
        var installationId: UUID?

        func configure(client: AnalyticsClient) {
            lock.lock(); defer { lock.unlock() }
            self.client = client
            installationId = nil
        }

        func setInstallationId(_ value: UUID) {
            lock.lock(); defer { lock.unlock() }
            installationId = value
        }

        func setObserver(_ value: LifecycleObserver) {
            lock.lock(); defer { lock.unlock() }
            observer = value
        }

        func currentClient() -> AnalyticsClient? {
            lock.lock(); defer { lock.unlock() }
            return client
        }

        func currentInstallationId() -> UUID? {
            lock.lock(); defer { lock.unlock() }
            return installationId
        }
    }
    private static let state = State()

    public static func configure(projectKey: String, configuration: AnalyticsConfiguration = .init()) {
        let persistence = FileAnalyticsPersistence(projectKey: projectKey)
        let client = AnalyticsClient(projectKey: projectKey, configuration: configuration, persistence: persistence)
        state.configure(client: client)
        Task {
            await client.start()
            let id = await client.currentInstallationId()
            state.setInstallationId(id)
        }
        Task { @MainActor in
            let observer = LifecycleObserver(
                foreground: { Task { await client.enteredForeground() } },
                background: { Task { await client.enteredBackground() } }
            )
            state.setObserver(observer)
        }
    }

    public static func track(_ event: String, properties: [String: AnalyticsValue] = [:]) {
        guard let client = currentClient() else { return }
        Task { await client.track(event, properties: properties) }
    }

    public static func setCollectionEnabled(_ enabled: Bool) {
        guard let client = currentClient() else { return }
        Task { await client.setCollectionEnabled(enabled) }
    }

    public static func flush() {
        guard let client = currentClient() else { return }
        Task { await client.flush() }
    }

    public static func reset(deleteRemoteData: Bool = true) {
        guard let client = currentClient() else { return }
        Task {
            await client.reset(deleteRemoteData: deleteRemoteData)
            let id = await client.currentInstallationId()
            state.setInstallationId(id)
        }
    }

    public static var installationID: UUID? {
        state.currentInstallationId()
    }

    private static func currentClient() -> AnalyticsClient? {
        state.currentClient()
    }
}

@MainActor
private final class LifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    init(foreground: @escaping @Sendable () -> Void, background: @escaping @Sendable () -> Void) {
        #if canImport(UIKit)
        tokens.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in foreground() })
        tokens.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in background() })
        #elseif canImport(AppKit)
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in foreground() })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in background() })
        #endif
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
