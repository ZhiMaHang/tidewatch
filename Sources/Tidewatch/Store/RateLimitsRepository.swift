import Foundation

/// 各账号最近一次 429 限流的原始响应,落在 Application Support(非机密)。
/// 记录存在 = 该账号「限流粘滞」:自动刷新对它停摆(重启后依旧生效),
/// 只有手动刷新成功才清除——限流后的处置权完全交给用户。
///
/// 磁盘格式与 SnapshotsRepository 同款:uuidString 作键的普通 JSON 对象
/// (合成 Codable 的 [UUID:] 会编成键值交替扁平数组,不可读)。
/// 演进注意:整个字典一次性解码,给 RateLimitRecord 加字段必须用 Optional。
enum RateLimitsRepository {
    static var fileURL: URL { AccountsRepository.directory.appendingPathComponent("ratelimits.json") }

    static func load() -> [UUID: RateLimitRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder.iso.decode([String: RateLimitRecord].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    static func save(_ records: [UUID: RateLimitRecord]) {
        try? FileManager.default.createDirectory(at: AccountsRepository.directory, withIntermediateDirectories: true)
        let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder.iso.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
