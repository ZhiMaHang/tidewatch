import Foundation

/// Claude Design 的应用内登录:PKCE + 浏览器授权 + 粘贴授权码。
/// 与主 Claude 登录同款 paste-code 流,但独立 client / scope / host(platform.claude.com)。
enum ClaudeDesignOAuth {
    // 授权走 claude.ai 消费端登录(你平时登 Claude 的地方),不走 platform/console 计费站。
    // redirect / token 保持 platform(design client 注册的回调与令牌端点,刷新已验证可用)。
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let scopes = "user:design:read user:design:write"

    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: DesignProvider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return comps.url!
    }

    static func exchange(pastedCode: String, pkce: PKCE) async throws -> DesignCredentials {
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaError.oauth(L("授权码为空", "Authorization code is empty")) }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0].components(separatedBy: "&")[0]
        let state = parts.count > 1 ? parts[1] : pkce.state

        let data = try await HTTP.postJSON(url: tokenURL, body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": DesignProvider.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw QuotaError.oauth(L("换取 token 失败", "Failed to exchange the token"))
        }
        var expiresAt: Double?
        if let ei = obj["expires_in"] as? Double { expiresAt = (Date().timeIntervalSince1970 + ei) * 1000 }
        return DesignCredentials(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresAt: expiresAt,
            clientId: DesignProvider.clientID,
            scopes: (obj["scope"] as? String)?.components(separatedBy: " ") ?? ["user:design:read", "user:design:write"]
        )
    }
}
