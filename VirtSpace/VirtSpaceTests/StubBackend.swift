//
//  StubBackend.swift
//  VirtSpaceTests
//
//  A scripted backend behind a real APIClient: requests go through a
//  URLProtocol stub and never leave the process. Each StubBackend owns a
//  unique fake host, so suites running in parallel never share routes.
//
//    let backend = StubBackend()
//    backend.on("GET /v1/worlds?offset=0", 200, StubBackend.page([...]))
//    let store = WorldStore(api: backend.makeAPI())
//

import Foundation
@testable import VirtSpace

nonisolated final class StubBackend: @unchecked Sendable {
    /// `status` 0 = the device is offline (URLError.notConnectedToInternet).
    struct Reply { let status: Int; let body: String }

    let host = "\(UUID().uuidString.lowercased()).stub.invalid"
    private let lock = NSLock()
    /// Replies per "METHOD /path?query", used in order; the last one repeats.
    private var routes: [String: [Reply]] = [:]
    private var log: [String] = []

    init() {
        StubURLProtocol.register(host: host) { [unowned self] in self.reply(to: $0) }
    }

    deinit { StubURLProtocol.unregister(host: host) }

    /// A real client whose session only talks to this stub.
    @MainActor func makeAPI() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: "https://\(host)", session: URLSession(configuration: config))
    }

    func on(_ route: String, _ status: Int, _ body: String = "{}") {
        lock.withLock { routes[route, default: []].append(Reply(status: status, body: body)) }
    }

    /// Every request seen, as "METHOD /path?query".
    var calls: [String] { lock.withLock { log } }

    private func reply(to request: URLRequest) -> Reply {
        let url = request.url!
        let key = "\(request.httpMethod ?? "GET") \(url.path)" + (url.query.map { "?\($0)" } ?? "")
        return lock.withLock {
            log.append(key)
            guard var queue = routes[key], let first = queue.first else {
                return Reply(status: 500, body: #"{"error":"no_stub_route"}"#)
            }
            if queue.count > 1 { queue.removeFirst(); routes[key] = queue }
            return first
        }
    }

    // MARK: JSON builders

    static func world(_ id: String, _ status: String) -> String {
        #"{"id":"\#(id)","title":"Scan Nov 5","status":"\#(status)"}"#
    }

    static func page(_ worlds: [String], hasMore: Bool = false, nextOffset: Int? = nil) -> String {
        let next = nextOffset.map(String.init) ?? "null"
        return #"{"worlds":[\#(worlds.joined(separator: ","))],"has_more":\#(hasMore),"next_offset":\#(next)}"#
    }

    static func envelope(_ id: String, _ status: String) -> String {
        #"{"world":\#(world(id, status)),"assets":{}}"#
    }

    static func job(_ id: String, _ status: String, jobId: String?) -> String {
        let job = jobId.map { #""\#($0)""# } ?? "null"
        return #"{"world":\#(world(id, status)),"job_id":\#(job)}"#
    }

    static func error(_ code: String) -> String { #"{"error":"\#(code)"}"# }
}

/// Answers every request from the StubBackend registered for its host.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> StubBackend.Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        _ = lock.withLock { handlers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let handler = request.url?.host.flatMap { host in Self.lock.withLock { Self.handlers[host] } }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = handler(request)
        guard reply.status != 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
