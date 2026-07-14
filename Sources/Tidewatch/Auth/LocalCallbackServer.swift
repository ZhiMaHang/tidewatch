import Foundation
import Network

/// 极简 HTTP 服务器,只为接住一次 OAuth 回调(GET /auth/callback?code=...&state=...)
final class LocalCallbackServer: @unchecked Sendable {
    private let listenerBox = Locked<NWListener?>(nil)
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    /// 启动并等待回调,返回 query 参数;超时、取消或端口占用都会抛错(不会悬挂)
    func waitForCallback(expectedState: String, timeout: TimeInterval = 300) async throws -> [String: String] {
        // 只绑回环地址,拒绝局域网访问
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listenerBox.withLock { $0 = listener }

        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                    let resumed = Locked(false)
                    func finish(_ result: Result<[String: String], Error>) {
                        resumed.withLock { done -> Void in
                            guard !done else { return }
                            done = true
                            cont.resume(with: result)
                        }
                    }
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
                            var query: [String: String] = [:]
                            comps.queryItems?.forEach { query[$0.name] = $0.value }
                            // state 必须存在且匹配,缺失一律拒绝
                            guard query["state"] == expectedState else {
                                Self.respond(conn, status: "400 Bad Request", body: L("state 校验失败,请回到 Tidewatch 重试", "State check failed, please retry from Tidewatch"))
                                return
                            }
                            let okTitle = L("登录成功", "Signed in")
                            let okBody = L("可以关闭此页面,回到 Tidewatch。", "You can close this page and return to Tidewatch.")
                            Self.respond(conn, status: "200 OK",
                                         body: "<html><body style='font-family:sans-serif;text-align:center;padding-top:80px'><h2>\(okTitle)</h2><p>\(okBody)</p></body></html>")
                            finish(.success(query))
                        }
                    }
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error):
                            finish(.failure(QuotaError.oauth(L("本地回调端口 \(self.port) 启动失败: \(error)(可能被 Codex CLI 占用,稍后再试)",
                                                               "Local callback port \(self.port) failed to start: \(error) (may be in use by the Codex CLI, try again later)"))))
                        case .cancelled:
                            // 超时/用户取消触发 stop() 时,由这里兜底恢复 continuation,避免任务组永远排不空
                            finish(.failure(QuotaError.oauth(L("登录已取消", "Login cancelled"))))
                        default:
                            break
                        }
                    }
                    listener.start(queue: .global())
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw QuotaError.oauth(L("等待浏览器授权超时", "Timed out waiting for browser authorization"))
            }
            defer { self.stop() }
            guard let first = try await group.next() else {
                throw QuotaError.oauth(L("回调服务器异常退出", "Callback server exited unexpectedly"))
            }
            group.cancelAll()
            return first
        }
    }

    func stop() {
        listenerBox.withLock { listener -> Void in
            listener?.cancel()
            listener = nil
        }
    }

    private static func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

/// 简易锁包装(跨队列共享可变状态用)
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    @discardableResult
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
