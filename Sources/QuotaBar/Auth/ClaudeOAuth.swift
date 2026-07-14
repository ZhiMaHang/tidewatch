import Foundation

/// Claude 账号的应用内登录:PKCE + 浏览器授权 + 粘贴授权码(与 Claude Code CLI 同一套 OAuth 客户端)
enum ClaudeOAuth {
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: ClaudeProvider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return comps.url!
    }

    /// 用户从回调页复制的内容形如 "code#state"
    static func exchange(pastedCode: String, pkce: PKCE) async throws -> ClaudeCredentials {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaError.oauth("授权码为空") }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        // 回调页展示 "code#state";code 里若混入 &xxx 参数也一并清掉
        let code = parts[0].components(separatedBy: "&")[0]
        let state = parts.count > 1 ? parts[1] : pkce.state

        let data = try await HTTP.postJSON(url: ClaudeProvider.tokenURL, body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": ClaudeProvider.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth("换取 token 失败")
        }
        var expiresAt: Double?
        if let expiresIn = obj["expires_in"] as? Double {
            expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        return ClaudeCredentials(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresAt: expiresAt,
            scopes: (obj["scope"] as? String)?.components(separatedBy: " "),
            subscriptionType: nil
        )
    }
}
