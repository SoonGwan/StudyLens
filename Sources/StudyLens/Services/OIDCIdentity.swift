import Foundation
import Security

struct JWKSet: Decodable {
    let keys: [JWK]
}

struct JWK: Decodable {
    let kty: String
    let kid: String
    let n: String?
    let e: String?
    let use: String?
    let alg: String?
}

struct OIDCIdentity {
    let subject: String
    let email: String?

    static func verify(_ jwt: String, keys: JWKSet, clientID: String, nonce: String, now: Date = Date()) throws -> OIDCIdentity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let jwk = keys.keys.first(where: { $0.kid == kid && $0.kty == "RSA" && ($0.use == nil || $0.use == "sig") && ($0.alg == nil || $0.alg == "RS256") }),
              let modulus = jwk.n.flatMap({ Data(base64URL: $0) }),
              let exponent = jwk.e.flatMap({ Data(base64URL: $0) }),
              !modulus.isEmpty, !exponent.isEmpty,
              let signature = Data(base64URL: parts[2]),
              let payloadData = Data(base64URL: parts[1]) else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let der = derValue(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                    signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count <= 1 || claims["azp"] as? String == clientID else {
            throw ChatGPTAuthError.invalidIdentity
        }
        if let authorizedParty = claims["azp"] as? String, authorizedParty != clientID {
            throw ChatGPTAuthError.invalidIdentity
        }
        if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 + 30 {
            throw ChatGPTAuthError.invalidIdentity
        }
        return .init(subject: subject, email: claims["email"] as? String)
    }

    private static func derInteger(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return derValue(0x02, bytes)
    }

    private static func derValue(_ tag: UInt8, _ value: Data) -> Data {
        var length: [UInt8] = []
        var count = value.count
        if count < 128 { length = [UInt8(count)] }
        else {
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + value
    }
}
