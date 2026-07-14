import Foundation
import Network

/// 极简 HTTP 服务器,只为接住一次 OAuth 回调(GET /auth/callback?code=...&state=...)
final class LocalCallbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    /// 启动并等待回调,返回 query 参数;超时或被取消则抛错
    func waitForCallback(expectedState: String, timeout: TimeInterval = 300) async throws -> [String: String] {
        // 只绑回环地址,拒绝局域网访问
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                    let resumed = Locked(false)
                    listener.newConnectionHandler = { conn in
                        conn.start(queue: .global())
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            guard let data, let request = String(data: data, encoding: .utf8) else {
                                conn.cancel()
                                return
                            }
                            guard let firstLine = request.components(separatedBy: "\r\n").first,
                                  firstLine.hasPrefix("GET ") else {
                                Self.respond(conn, status: "404 Not Found", body: "not found")
                                return
                            }
                            let path = firstLine.components(separatedBy: " ")[1]
                            guard let comps = URLComponents(string: "http://localhost\(path)"),
                                  comps.path.hasSuffix("/callback") else {
                                Self.respond(conn, status: "404 Not Found", body: "not found")
                                return
                            }
                            var params: [String: String] = [:]
                            comps.queryItems?.forEach { params[$0.name] = $0.value }
                            if let state = params["state"], state != expectedState {
                                Self.respond(conn, status: "400 Bad Request", body: "state 不匹配,请回到 QuotaBar 重试")
                                return
                            }
                            Self.respond(conn, status: "200 OK",
                                         body: "<html><body style='font-family:sans-serif;text-align:center;padding-top:80px'><h2>登录成功</h2><p>可以关闭此页面,回到 QuotaBar。</p></body></html>")
                            resumed.withLock { done in
                                if !done { done = true; cont.resume(returning: params) }
                            }
                        }
                    }
                    listener.stateUpdateHandler = { state in
                        if case .failed(let error) = state {
                            resumed.withLock { done in
                                if !done { done = true; cont.resume(throwing: QuotaError.oauth("本地回调端口启动失败: \(error)(可能被 Codex CLI 占用)")) }
                            }
                        }
                    }
                    listener.start(queue: .global())
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw QuotaError.oauth("等待浏览器授权超时")
            }
            defer { self.stop() }
            guard let first = try await group.next() else { throw QuotaError.oauth("回调服务器异常退出") }
            group.cancelAll()
            return first
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

/// 简易锁包装(回调服务器跨队列去重用)
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}
