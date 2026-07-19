import Foundation

/// 各账号最近一次成功的额度快照,落在 Application Support(非机密)。
/// 用途:重启后先展示上次数据(标注为旧数据),而不是空白——
/// 尤其在 token 端点限流期间,重启不该把仅存的可读数据丢掉。
///
/// 演进注意:整个字典一次性解码,任何一处失败都回落为空(等于全部丢弃)。
/// 给 UsageSnapshot/UsageWindow 加字段必须用 Optional——合成 Codable 对
/// 带默认值的非可选新字段照样抛 keyNotFound,老文件会整体解不出来。
enum SnapshotsRepository {
    static var fileURL: URL { AccountsRepository.directory.appendingPathComponent("snapshots.json") }

    // 磁盘格式用 uuidString 作键:[UUID: T] 的合成 Codable 会编码成键值交替的扁平数组
    // (UUID 非 String/Int 键),既不可读也容易被外部工具误伤;字符串键才是普通 JSON 对象

    static func load() -> [UUID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder.iso.decode([String: UsageSnapshot].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    static func save(_ snapshots: [UUID: UsageSnapshot]) {
        try? FileManager.default.createDirectory(at: AccountsRepository.directory, withIntermediateDirectories: true)
        let raw = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder.iso.encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
