import Foundation

/// Codex/ChatGPT 账号的应用内登录:PKCE + 浏览器授权 + localhost 回调(与 Codex CLI 同一套 OAuth 客户端)
enum CodexOAuth {
    static let authorizeBase = "https://auth.openai.com/oauth/authorize"
    static let callbackPort: UInt16 = 1455
    static var redirectURI: String { "http://localhost:\(callbackPort)/auth/callback" }
    static let scopes = "openid profile email offline_access"

    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexProvider.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        ]
        return comps.url!
    }

    static func exchange(code: String, pkce: PKCE) async throws -> CodexTokens {
        let data = try await HTTP.postJSON(url: CodexProvider.tokenURL, body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": CodexProvider.clientID,
            "code_verifier": pkce.verifier,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth("换取 token 失败")
        }
        let idToken = obj["id_token"] as? String
        return CodexTokens(
            access_token: access,
            account_id: idToken.flatMap(CodexProvider.accountID(fromIDToken:)),
            id_token: idToken,
            refresh_token: obj["refresh_token"] as? String
        )
    }
}
