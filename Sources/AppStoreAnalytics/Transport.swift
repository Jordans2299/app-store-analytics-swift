import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol AnalyticsTransport: Sendable {
    func send(batch: EventBatch, projectKey: String, endpoint: URL) async throws -> BatchResponse
    func deleteInstallation(id: UUID, secret: String, projectKey: String, endpoint: URL) async throws
}

struct URLSessionAnalyticsTransport: AnalyticsTransport {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(batch: EventBatch, projectKey: String, endpoint: URL) async throws -> BatchResponse {
        var request = URLRequest(url: endpoint.appendingPathComponent("events/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectKey, forHTTPHeaderField: "X-Project-Key")
        request.httpBody = try JSONEncoder().encode(batch)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(BatchResponse.self, from: data)
    }

    func deleteInstallation(id: UUID, secret: String, projectKey: String, endpoint: URL) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("installations/\(id.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectKey, forHTTPHeaderField: "X-Project-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["installationSecret": secret])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}

