import Foundation

/// 按凭据存储粒度串行化"读 token → 请求 → 刷新 → 写回"全过程。
/// refresh token 单次有效会轮转,同一存储绝不允许两个刷新并发,
/// 排队者获得锁后必须重新读 token(拿到前一次刷新后的新 token)。
actor KeyedLocks {
    static let shared = KeyedLocks()

    private var locked = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if !locked.contains(key) {
            locked.insert(key)
            return
        }
        await withCheckedContinuation { cont in
            waiters[key, default: []].append(cont)
        }
    }

    func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume() // 锁直接移交给下一个等待者
        } else {
            locked.remove(key)
        }
    }

    /// 串行执行 body;不要在 body 里再嵌套同 key 的 withLock(会死锁)
    func run<T: Sendable>(_ key: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(key)
        do {
            let result = try await body()
            release(key)
            return result
        } catch {
            release(key)
            throw error
        }
    }
}

/// 凭据存储的锁 key:同一个底层存储(文件/钥匙串条目)共用一把锁
func credentialLockKey(_ account: Account) -> String {
    switch account.source {
    case .managed:
        return "managed:\(account.id.uuidString)"
    case .codexAuthFile(let path):
        return "codex-file:\(URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)"
    case .claudeCLI(let path):
        return "claude-cli:\(path ?? "default")"
    case .glmApiKey:
        return "glm:\(account.id.uuidString)"
    }
}
