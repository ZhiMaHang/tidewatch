import Foundation

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func getJSON(url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await send(req)
        if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
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
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)
        let (data, http) = try await send(req)
        if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
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
        if http.statusCode == 401 || http.statusCode == 403 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
