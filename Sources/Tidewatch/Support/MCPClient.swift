import Foundation

/// 极简 MCP over HTTP(streamable HTTP transport)客户端:握手 + 调用工具。
/// Claude Design 的 MCP 服务是无状态的(不回 session id),响应是普通 JSON(也兼容 SSE)。
final class MCPClient {
    private let url: URL
    private let headers: [String: String]
    private var nextID = 0

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    /// 调用一个工具,返回 result.content[0].text(通常是一段 JSON 字符串)对应的 Data
    func callToolText(name: String, arguments: [String: Any]) async throws -> Data {
        // 先握手一次(无状态服务器忽略也无妨),再调用
        _ = try? await rpc(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Tidewatch", "version": "0.1"],
        ])
        let obj = try await rpc(method: "tools/call", params: ["name": name, "arguments": arguments])
        if let err = obj["error"] as? [String: Any] {
            throw QuotaError.parse("MCP: \(err["message"] as? String ?? "\(err)")")
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw QuotaError.parse("MCP 响应缺少 result")
        }
        if let isError = result["isError"] as? Bool, isError {
            let msg = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "工具返回错误"
            throw QuotaError.parse("MCP: \(msg)")
        }
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8) else {
            throw QuotaError.parse("MCP 结果不含文本内容")
        }
        return data
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await HTTP.send(req)
        if http.statusCode == 401 { throw QuotaError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parse(data)
    }

    /// body 可能是普通 JSON,或 SSE(多行,含 `data: {...}`)
    static func parse(_ data: Data) throws -> [String: Any] {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
        let text = String(data: data, encoding: .utf8) ?? ""
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if let d = payload.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                return obj
            }
        }
        throw QuotaError.parse("MCP 响应无法解析: \(String(text.prefix(120)))")
    }
}
