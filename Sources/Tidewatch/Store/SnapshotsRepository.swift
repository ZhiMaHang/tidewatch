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

    static func load() -> [UUID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder.iso.decode([UUID: UsageSnapshot].self, from: data)) ?? [:]
    }

    static func save(_ snapshots: [UUID: UsageSnapshot]) {
        try? FileManager.default.createDirectory(at: AccountsRepository.directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
