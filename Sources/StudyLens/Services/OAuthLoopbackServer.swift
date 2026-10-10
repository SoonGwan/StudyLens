import Foundation
import Network

struct OAuthCallback {
    let code: String
    let clientID: String?
    let redirectURI: String

    static func parse(_ url: URL, expectedState: String, redirectURI: String) throws -> OAuthCallback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI),
              components.scheme == expected.scheme, components.host == expected.host,
              components.port == expected.port, components.path == expected.path else {
            throw ChatGPTAuthError.invalidCallback
        }
        let items = components.queryItems ?? []
        // Reject ambiguous duplicate query parameters.
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw ChatGPTAuthError.invalidCallback
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" { throw ChatGPTAuthError.denied }
            throw ChatGPTAuthError.oauth(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatGPTAuthError.invalidCallback
        }
        return .init(code: code, clientID: items.first(where: { $0.name == "client_id" })?.value, redirectURI: redirectURI)
    }
}

/// Listen only on IPv4 loopback and close after the sign-in attempt.
@MainActor
final class OAuthLoopbackServer {
    private let expectedState: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var timer: Task<Void, Never>?
    private var redirectURI = ""

    init(expectedState: String) { self.expectedState = expectedState }

    func authorize(openBrowser: @escaping (String) throws -> Void) async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(ChatGPTAuthError.invalidCallback)); return }
                            self.redirectURI = "http://127.0.0.1:\(port.rawValue)/auth/callback"
                            do { try openBrowser(self.redirectURI) }
                            catch { self.finish(.failure(error)) }
                        case .failed:
                            self.finish(.failure(ChatGPTAuthError.oauth("callback_listener_failed")))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { connection.cancel(); return }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.read(connection, buffer: Data())
                    }
                }
                listener.start(queue: .main)
                timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) }
                    catch { return }
                    self?.finish(.failure(ChatGPTAuthError.timedOut))
                }
            } catch { finish(.failure(error)) }
        }
    }

    func cancel() { finish(.failure(ChatGPTAuthError.cancelled)) }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                let combined = buffer + (data ?? Data())
                guard combined.count <= 16_384, error == nil else { connection.cancel(); return }
                guard let headerEnd = combined.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() } else { self.read(connection, buffer: combined) }
                    return
                }
                let request = String(decoding: combined[..<headerEnd.lowerBound], as: UTF8.self)
                let parts = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                      let url = URL(string: "http://127.0.0.1:\(self.listener?.port?.rawValue ?? 0)\(parts[1])") else {
                    self.respond(connection, status: "404 Not Found", message: "StudyLens login callback only.")
                    return
                }
                do {
                    let callback = try OAuthCallback.parse(url, expectedState: self.expectedState, redirectURI: self.redirectURI)
                    self.respond(connection, status: "200 OK", message: "StudyLens received your login. You can return to the app.") {
                        self.finish(.success(callback))
                    }
                } catch ChatGPTAuthError.invalidCallback {
                    self.respond(connection, status: "400 Bad Request", message: "Invalid login callback.")
                } catch {
                    self.respond(connection, status: "400 Bad Request", message: "Login was not completed.") {
                        self.finish(.failure(error))
                    }
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String, completion: (() -> Void)? = nil) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeAll { $0 === connection }
                completion?()
            }
        })
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        continuation.resume(with: result)
    }
}
