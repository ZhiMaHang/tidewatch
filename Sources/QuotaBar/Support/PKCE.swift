import Foundation
import CryptoKit

struct PKCE {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = PKCE.randomURLSafe(64)
        state = PKCE.randomURLSafe(32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncoded()
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // 极少见,但绝不能让 verifier/state 变成全零
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
