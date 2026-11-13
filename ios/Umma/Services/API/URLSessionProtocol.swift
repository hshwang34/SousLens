import Foundation

/// Seam for tests: `URLSession` conforms; tests may inject a stub or a `URLProtocol`-backed session.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
