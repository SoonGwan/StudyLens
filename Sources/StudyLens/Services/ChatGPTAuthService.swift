import AppKit
import CryptoKit
import Foundation
import Security

enum BillingMode: String, CaseIterable, Identifiable {
    case chatGPT, apiKey
    var id: String { rawValue }
    var title: String { self == .chatGPT ? "ChatGPT 구독 사용량" : "API 키 · 별도 결제" }
}

struct ChatGPTCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
    var permitsInference: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}

struct ChatGPTProfile: Codable, Identifiable {
    var id: String { clientID }
    let clientID: String
    var subject: String?
    var email: String?
    var credentials: ChatGPTCredentials?
    var label: String {
        "\(email ?? "ChatGPT 계정") · \(clientID.suffix(6))"
    }
}

private struct ChatGPTVault: Codable {
    var profiles: [ChatGPTProfile] = []
    var activeClientID: String?
}

enum ChatGPTAuthError: LocalizedError {
    case notConnected, permissionMissing, invalidCallback, denied, invalidIdentity, cancelled, timedOut
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "설정에서 Continue with ChatGPT를 눌러 계정을 연결해 주세요."
        case .permissionMissing: return "이 연결에는 구독 사용 권한이 없습니다. 설정에서 구독 사용 허용을 눌러 주세요."
        case .invalidCallback: return "로그인 응답을 확인할 수 없습니다. 다시 로그인해 주세요."
        case .denied: return "ChatGPT 연결을 허용하지 않았습니다."
        case .invalidIdentity: return "ChatGPT 로그인 서명 또는 계정 정보를 검증하지 못했습니다."
        case .cancelled: return "로그인을 취소했습니다."
        case .timedOut: return "로그인 시간이 초과되었습니다. 다시 시도해 주세요."
        case .oauth(let code): return "ChatGPT 연결 오류: \(code). 설정에서 연결 상태를 확인해 주세요."
        }
    }
}

/// StudyLens 자체의 OAuth 연결만 사용한다. 다른 앱의 인증 파일을 읽지 않는다.
@MainActor
final class ChatGPTAuthService {
    static let resource = "https://api.openai.com/v1"
    static let issuer = "https://auth.openai.com"
    static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private let session: URLSession
    private var vault: ChatGPTVault
    private var callbackServer: OAuthLoopbackServer?
    private var refreshTasks: [String: Task<ChatGPTCredentials, Error>] = [:]
    private var storageError: Error?

    var profiles: [ChatGPTProfile] { vault.profiles }
    var activeClientID: String? { vault.activeClientID }
    var activeProfile: ChatGPTProfile? { vault.profiles.first { $0.clientID == vault.activeClientID } }

    init() {
        session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
        vault = ChatGPTVault()
        do {
            if let data = try KeychainService.loadData(account: "chatgpt-oauth-vault") {
                vault = try JSONDecoder().decode(ChatGPTVault.self, from: data)
            }
        } catch {
            // Do not replace existing account registrations when the keychain cannot be read.
            storageError = error
        }
    }

    private var hostID: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "chatGPTHostID") { return value }
        let value = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: "chatGPTHostID")
        return value
    }

    func selectProfile(_ clientID: String) throws {
        if let storageError { throw storageError }
        guard vault.profiles.contains(where: { $0.clientID == clientID }) else { return }
        vault.activeClientID = clientID
        try persist()
    }

    func cancelSignIn() { callbackServer?.cancel() }

    func signIn(newAccount: Bool = false, requestConsent: Bool = false) async throws {
        if let storageError { throw storageError }
        let previous = newAccount ? nil : activeProfile
        let state = try OAuthUtilities.randomValue()
        let nonce = try OAuthUtilities.randomValue()
        let verifier = try OAuthUtilities.randomValue()
        let server = OAuthLoopbackServer(expectedState: state)
        callbackServer = server
        defer { callbackServer = nil }

        let callback = try await server.authorize { redirectURI in
            let url = Self.authorizationURL(
                profile: previous, hostID: self.hostID, redirectURI: redirectURI,
                state: state, nonce: nonce, verifier: verifier, requestConsent: requestConsent
            )
            guard NSWorkspace.shared.open(url) else { throw ChatGPTAuthError.cancelled }
        }
        let clientID = try OAuthUtilities.issuedClientID(callback: callback, previous: previous?.clientID)
        // Retain the issued registration even if code exchange expires.
        if !vault.profiles.contains(where: { $0.clientID == clientID }) {
            vault.profiles.append(.init(clientID: clientID, subject: nil, email: nil, credentials: nil))
            try persist()
        }

        let token = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID,
            "code": callback.code, "code_verifier": verifier,
            "redirect_uri": callback.redirectURI, "resource": Self.resource
        ])
        guard let idToken = token.idToken else { throw ChatGPTAuthError.invalidIdentity }
        let identity = try await validateIdentity(idToken, clientID: clientID, nonce: nonce)
        if let subject = previous?.subject, subject != identity.subject {
            throw ChatGPTAuthError.invalidIdentity
        }
        guard let index = vault.profiles.firstIndex(where: { $0.clientID == clientID }) else {
            throw ChatGPTAuthError.invalidCallback
        }
        vault.profiles[index].subject = identity.subject
        vault.profiles[index].email = identity.email
        vault.profiles[index].credentials = try token.credentials(idToken: idToken)
        vault.activeClientID = clientID
        try persist()
    }

    static func authorizationURL(
        profile: ChatGPTProfile?, hostID: String, redirectURI: String,
        state: String, nonce: String, verifier: String, requestConsent: Bool
    ) -> URL {
        var fields = [
            "client_id": profile?.clientID ?? "dynamic_agent_client",
            "ext_agent_host_id": hostID, "response_type": "code", "redirect_uri": redirectURI,
            "scope": requestedScopes, "resource": resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": OAuthUtilities.challenge(verifier)
        ]
        if profile == nil { fields["agent_name_hint"] = "StudyLens" }
        if let token = profile?.credentials?.idToken { fields["id_token_hint"] = token }
        if let email = profile?.email { fields["login_hint"] = email }
        if requestConsent { fields["prompt"] = "consent" }
        var components = URLComponents(string: "\(issuer)/api/accounts/authorize")!
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    func accessToken() async throws -> String {
        if let storageError { throw storageError }
        guard let profile = activeProfile, let credentials = profile.credentials else {
            throw ChatGPTAuthError.notConnected
        }
        guard credentials.permitsInference else { throw ChatGPTAuthError.permissionMissing }
        if credentials.expiresAt.timeIntervalSinceNow > 60 { return credentials.accessToken }
        if let task = refreshTasks[profile.clientID] { return try await task.value.accessToken }
        guard let refreshToken = credentials.refreshToken else { throw ChatGPTAuthError.notConnected }

        let task = Task { @MainActor [self] in
            let token = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": profile.clientID,
                "refresh_token": refreshToken, "resource": Self.resource
            ])
            let updated = try token.credentials(idToken: token.idToken ?? credentials.idToken)
            guard updated.refreshToken != nil else { throw ChatGPTAuthError.oauth("missing_refresh_token") }
            guard let index = vault.profiles.firstIndex(where: { $0.clientID == profile.clientID }),
                  vault.profiles[index].credentials?.refreshToken == refreshToken else {
                throw ChatGPTAuthError.notConnected
            }
            vault.profiles[index].credentials = updated
            try persist()
            guard updated.permitsInference else { throw ChatGPTAuthError.permissionMissing }
            return updated
        }
        refreshTasks[profile.clientID] = task
        defer { refreshTasks[profile.clientID] = nil }
        do {
            return try await task.value.accessToken
        } catch ChatGPTAuthError.oauth(let code) {
            let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
            if terminal.contains(code), let index = vault.profiles.firstIndex(where: { $0.clientID == profile.clientID }) {
                vault.profiles[index].credentials = nil
                try persist()
            }
            throw ChatGPTAuthError.oauth(code)
        }
    }

    /// Always clear local tokens; return false if remote revocation was not confirmed.
    func signOut() async throws -> Bool {
        guard let profile = activeProfile else { return true }
        var revoked = true
        if let refreshToken = profile.credentials?.refreshToken {
            do {
                let discovery = try await discoveryDocument()
                guard let endpoint = discovery.revocationEndpoint, Self.isTrustedAuthURL(endpoint) else {
                    throw ChatGPTAuthError.invalidIdentity
                }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = OAuthUtilities.form([
                    "token": refreshToken, "token_type_hint": "refresh_token", "client_id": profile.clientID
                ])
                let (_, response) = try await session.data(for: request)
                revoked = (response as? HTTPURLResponse)?.statusCode == 200
            } catch { revoked = false }
        }
        if let index = vault.profiles.firstIndex(where: { $0.clientID == profile.clientID }) {
            vault.profiles[index].credentials = nil
            try persist()
        }
        return revoked
    }

    private func persist() throws {
        if let storageError { throw storageError }
        try KeychainService.saveData(JSONEncoder().encode(vault), account: "chatgpt-oauth-vault")
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: URL(string: "\(Self.issuer)/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthUtilities.form(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ChatGPTAuthError.oauth(object?["error"] as? String ?? "token_request_failed")
        }
        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    private func discoveryDocument() async throws -> OIDCDiscovery {
        let (data, response) = try await session.data(from: URL(string: "\(Self.issuer)/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTAuthError.invalidIdentity }
        let document = try JSONDecoder().decode(OIDCDiscovery.self, from: data)
        guard document.issuer == Self.issuer, Self.isTrustedAuthURL(document.jwksURI) else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return document
    }

    private func validateIdentity(_ jwt: String, clientID: String, nonce: String) async throws -> OIDCIdentity {
        let discovery = try await discoveryDocument()
        let (data, response) = try await session.data(from: discovery.jwksURI)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTAuthError.invalidIdentity }
        let keys = try JSONDecoder().decode(JWKSet.self, from: data)
        return try OIDCIdentity.verify(jwt, keys: keys, clientID: clientID, nonce: nonce)
    }

    private static func isTrustedAuthURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct OIDCDiscovery: Decodable {
    let issuer: String
    let jwksURI: URL
    let revocationEndpoint: URL?
    enum CodingKeys: String, CodingKey {
        case issuer, jwksURI = "jwks_uri", revocationEndpoint = "revocation_endpoint"
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: TimeInterval
    let scope: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }
    func credentials(idToken: String) throws -> ChatGPTCredentials {
        guard tokenType.lowercased() == "bearer", !accessToken.isEmpty, expiresIn > 0 else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return .init(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                     scopes: scope.split(separator: " ").map(String.init), expiresAt: Date().addingTimeInterval(expiresIn))
    }
}

enum OAuthUtilities {
    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return Data(bytes).base64URL
    }
    static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let value = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }
    static func issuedClientID(callback: OAuthCallback, previous: String?) throws -> String {
        if let previous {
            guard callback.clientID == nil || callback.clientID == previous else { throw ChatGPTAuthError.invalidCallback }
            return previous
        }
        guard let issued = callback.clientID, issued.hasPrefix("oaiapp_"), issued != "dynamic_agent_client" else {
            throw ChatGPTAuthError.invalidCallback
        }
        return issued
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL value: String) {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
}
