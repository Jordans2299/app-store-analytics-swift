import Foundation

protocol AnalyticsPersistence: Sendable {
    func loadEvents() async -> [AnalyticsEvent]
    func saveEvents(_ events: [AnalyticsEvent]) async
    func string(for key: String) async -> String?
    func setString(_ value: String?, for key: String) async
    func bool(for key: String) async -> Bool
    func setBool(_ value: Bool, for key: String) async
}

actor FileAnalyticsPersistence: AnalyticsPersistence {
    private let defaults: UserDefaults
    private let queueURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(projectKey: String, directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "unknown-app"
        let safeProject = projectKey.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let folder = base.appendingPathComponent("AppStoreAnalytics/\(bundle)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.queueURL = folder.appendingPathComponent("\(safeProject)-queue.json")
    }

    func loadEvents() -> [AnalyticsEvent] {
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        return (try? decoder.decode([AnalyticsEvent].self, from: data)) ?? []
    }

    func saveEvents(_ events: [AnalyticsEvent]) {
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    func string(for key: String) -> String? { defaults.string(forKey: key) }
    func setString(_ value: String?, for key: String) { defaults.set(value, forKey: key) }
    func bool(for key: String) -> Bool { defaults.bool(forKey: key) }
    func setBool(_ value: Bool, for key: String) { defaults.set(value, forKey: key) }
}

