import Foundation

/// 零请求兜底数据源:读 Claude 桌面应用替各账号缓存的额度快照。
///
/// 背景:Claude 桌面应用会把它登录过的每个账号的额度百分比,按组织(org)持续写进本机明文文件
/// `~/Library/Application Support/Claude/plan-usage-history.json`(约每 14 分钟一采)。读它
/// **不发任何网络请求、不刷新 token、不碰限流桶**,正好在我们自己的 OAuth 刷新被限流时兜底。
///
/// 结构(实测 version:2):`{ "version": 2, "samples": [ { "t": 毫秒时间戳, "org": "UUID",
/// "u": { "fh": 5小时窗口用量%, "sd": 本周窗口用量% } }, … ] }`。`org` 就是 OAuth profile 的
/// `organization_uuid`(本机 `~/.claude.json` 的 oauthAccount.organizationUuid 与之逐位一致)。
///
/// **局限**(卡片会如实标注,别把它当主源):①只有 fh/sd 两窗,无 Opus/Sonnet 细分与 overage;
/// ②新鲜度取决于桌面应用当时是否在跑、且登录着该账号——它没登录/没在跑的账号数据会冻结;
/// ③schema 随桌面应用版本可能变(version 字段在此),故防御式解析,任何异常都退回 nil。
enum ClaudeDesktopCache {
    /// 一条采样:某账号在某时刻的两窗用量
    struct Sample: Equatable {
        var fiveHourPercent: Double
        var sevenDayPercent: Double
        var at: Date
    }

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// 读文件并取指定 org 的最新一条采样。文件不存在/解析失败/无该 org 一律 nil。
    static func latestSample(orgUUID: String) -> Sample? {
        latestSample(orgUUID: orgUUID, data: try? Data(contentsOf: fileURL))
    }

    /// 纯函数版(data 显式传入),便于单测。
    static func latestSample(orgUUID: String, data: Data?) -> Sample? {
        guard !orgUUID.isEmpty, let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]] else { return nil }
        var best: Sample?
        for s in samples {
            guard (s["org"] as? String) == orgUUID,
                  let t = doubleOf(s["t"]),
                  let u = s["u"] as? [String: Any] else { continue }
            // fh/sd 缺失按 0 处理(桌面应用偶有只报一窗的样本);t 是毫秒
            let sample = Sample(
                fiveHourPercent: clamp(doubleOf(u["fh"]) ?? 0),
                sevenDayPercent: clamp(doubleOf(u["sd"]) ?? 0),
                at: Date(timeIntervalSince1970: t / 1000)
            )
            if best == nil || sample.at > best!.at { best = sample }
        }
        return best
    }

    /// 把一条采样转成 UsageSnapshot(两窗:5 小时 + 本周全部模型)。
    /// fetchedAt 取采样时刻本身——卡片「截至 X」直接反映桌面应用上次采样时间,不谎报为「刚刚」。
    /// resetsAt 缓存里没有,置 nil(按周额度重置排序的键因此缺失,沉底,符合「兜底源信息更少」的预期)。
    static func snapshot(from s: Sample, planType: String?) -> UsageSnapshot {
        UsageSnapshot(
            windows: [
                UsageWindow(key: "five_hour",
                            title: L("5 小时窗口", "5-hour window"),
                            usedPercent: s.fiveHourPercent, resetsAt: nil),
                UsageWindow(key: "seven_day",
                            title: L("本周(全部模型)", "This week (all models)"),
                            usedPercent: s.sevenDayPercent, resetsAt: nil, isAccountWeekly: true),
            ],
            planType: planType, email: nil, creditsBalance: nil, fetchedAt: s.at
        )
    }

    /// 兜底决策(纯函数,便于单测):仅当缓存里有该 org 的采样、且它**比现有展示的快照更新**时,
    /// 才返回缓存快照;否则 nil(现有数据已经更新或一样新,就别用更粗的兜底源盖掉它)。
    /// existingFetchedAt 传 nil(卡片当前空着)时,只要有缓存就用。
    static func fallbackSnapshot(orgUUID: String?, planType: String?,
                                 existingFetchedAt: Date?, data: Data?) -> UsageSnapshot? {
        guard let orgUUID, let sample = latestSample(orgUUID: orgUUID, data: data) else { return nil }
        if let existingFetchedAt, existingFetchedAt >= sample.at { return nil }
        return snapshot(from: sample, planType: planType)
    }

    private static func doubleOf(_ v: Any?) -> Double? {
        (v as? Double) ?? (v as? Int).map(Double.init)
    }
    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 100) }
}
