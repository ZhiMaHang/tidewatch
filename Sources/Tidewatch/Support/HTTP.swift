import Foundation

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        // 要容得下 token 端点偶发的 40-60s 慢响应,不能低于单请求超时
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    static let maxRetries = 3

    /// 瞬时网络/TLS 错误自动重试(最多 maxRetries 次 + 递增退避)。
    /// 只重试"请求没到服务器/没拿到响应"这类错误(如 TLS 握手失败、连不上、超时),
    /// 这类重试对 GET 和 token 刷新都安全;拿到 HTTP 响应(含 4xx/5xx)不在此重试。
    static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            } catch let error as URLError where attempt < maxRetries && isTransient(error) {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(400 * attempt)) // 0.4s / 0.8s / 1.2s
            }
        }
    }

    /// 是否属于可安全重试的瞬时传输错误
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed,      // A TLS error caused the secure connection to fail
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .badServerResponse,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// 非 2xx 时的错误正文:带上端点 host(区分 usage/token 端点)与 Retry-After(限流剩余时长),便于诊断
    static func errorBody(_ http: HTTPURLResponse, _ data: Data) -> String {
        var prefix = "[\(http.url?.host ?? "?")\(http.url?.path ?? "")"
        if let ra = http.value(forHTTPHeaderField: "Retry-After") { prefix += " Retry-After:\(ra)s" }
        prefix += "] "
        return prefix + (String(data: data, encoding: .utf8) ?? "")
    }

    static func getJSON(url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await send(req)
        // 只有 401 才代表凭据失效;403 可能是 WAF/权限/套餐问题,绝不能触发 refresh token 轮转
        if http.statusCode == 401 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, errorBody(http, data))
        }
        return data
    }

    static func postForm(url: URL, fields: [String: String], headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        let body = fields.map { "\(enc($0.key))=\(enc($0.value))" }.sorted().joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, http) = try await send(req)
        // 只有 401 才代表凭据失效;403 可能是 WAF/权限/套餐问题,绝不能触发 refresh token 轮转
        if http.statusCode == 401 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, errorBody(http, data))
        }
        return data
    }

    static func postJSON(url: URL, body: [String: Any], headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // token 端点高负载时响应可达 40-60s
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(req)
        // 只有 401 才代表凭据失效;403 可能是 WAF/权限/套餐问题,绝不能触发 refresh token 轮转
        if http.statusCode == 401 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, errorBody(http, data))
        }
        return data
    }
}
