@testable import Tidewatch
import Foundation
import Testing

/// Claude 桌面应用缓存(plan-usage-history.json)兜底源的纯逻辑测试:解析、取最新、org 隔离、
/// 兜底「更新才用」的精度,以及组织 UUID 从 profile 响应里的防御式抽取。全部零文件零网络。
@Suite("桌面缓存兜底")
struct ClaudeDesktopCacheTests {

    /// 造一份 plan-usage-history.json 字节。t 用毫秒。
    func history(_ rows: [(t: Double, org: String, fh: Double, sd: Double)]) -> Data {
        let samples = rows.map { "{\"t\": \($0.t), \"org\": \"\($0.org)\", \"u\": {\"fh\": \($0.fh), \"sd\": \($0.sd)}}" }
            .joined(separator: ",")
        return Data("{\"version\": 2, \"samples\": [\(samples)]}".utf8)
    }

    @Test("取指定 org 的最新一条,而非文件里的最后一条")
    func latestPerOrg() {
        let data = history([
            (t: 1_000, org: "A", fh: 10, sd: 20),
            (t: 3_000, org: "A", fh: 30, sd: 40), // A 的最新在中间
            (t: 2_000, org: "B", fh: 99, sd: 99), // B 更晚出现但不是 A
        ])
        let s = ClaudeDesktopCache.latestSample(orgUUID: "A", data: data)
        #expect(s?.fiveHourPercent == 30)
        #expect(s?.sevenDayPercent == 40)
        #expect(s?.at == Date(timeIntervalSince1970: 3.0)) // 3000ms
    }

    @Test("org 隔离:查不到的 org 返回 nil,不串到别的账号")
    func orgIsolation() {
        let data = history([(t: 1_000, org: "A", fh: 10, sd: 20)])
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "ZZZ", data: data) == nil)
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "", data: data) == nil)
    }

    @Test("坏数据一律 nil,不崩")
    func garbageIsNil() {
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "A", data: nil) == nil)
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "A", data: Data("not json".utf8)) == nil)
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "A", data: Data("{\"version\":2}".utf8)) == nil)
        // 缺 u 的样本跳过
        let noU = Data("{\"samples\":[{\"t\":1000,\"org\":\"A\"}]}".utf8)
        #expect(ClaudeDesktopCache.latestSample(orgUUID: "A", data: noU) == nil)
    }

    @Test("百分比夹到 0–100")
    func clamped() {
        let data = history([(t: 1_000, org: "A", fh: 150, sd: -5)])
        let s = ClaudeDesktopCache.latestSample(orgUUID: "A", data: data)
        #expect(s?.fiveHourPercent == 100)
        #expect(s?.sevenDayPercent == 0)
    }

    @Test("兜底快照:缓存比现有更新才用,否则不盖")
    func fallbackOnlyWhenNewer() {
        let data = history([(t: 5_000, org: "A", fh: 21, sd: 87)]) // 缓存采样 = 5.0s
        let cacheAt = Date(timeIntervalSince1970: 5.0)

        // 现有更旧 → 用缓存
        let older = cacheAt.addingTimeInterval(-100)
        let snap = ClaudeDesktopCache.fallbackSnapshot(orgUUID: "A", planType: "claude_max",
                                                       existingFetchedAt: older, data: data)
        #expect(snap != nil)
        #expect(snap?.fetchedAt == cacheAt)
        #expect(snap?.windows.count == 2)
        #expect(snap?.windows.first(where: { $0.key == "seven_day" })?.usedPercent == 87)
        #expect(snap?.windows.first(where: { $0.key == "seven_day" })?.isAccountWeekly == true)

        // 现有更新或同时刻 → 不盖(返回 nil)
        #expect(ClaudeDesktopCache.fallbackSnapshot(orgUUID: "A", planType: nil,
                existingFetchedAt: cacheAt.addingTimeInterval(1), data: data) == nil)
        #expect(ClaudeDesktopCache.fallbackSnapshot(orgUUID: "A", planType: nil,
                existingFetchedAt: cacheAt, data: data) == nil)

        // 卡片当前空着(existing = nil)→ 只要有缓存就用
        #expect(ClaudeDesktopCache.fallbackSnapshot(orgUUID: "A", planType: nil,
                existingFetchedAt: nil, data: data) != nil)

        // 没学到 org → 不兜底
        #expect(ClaudeDesktopCache.fallbackSnapshot(orgUUID: nil, planType: nil,
                existingFetchedAt: nil, data: data) == nil)
    }

    @Test("组织 UUID 防御式抽取:覆盖多种可能的字段路径")
    func parseOrgUUID() {
        // organization.uuid(最可能)
        #expect(ClaudeProvider.parseOrgUUID(["organization": ["uuid": "org-1"]]) == "org-1")
        // organization.id
        #expect(ClaudeProvider.parseOrgUUID(["organization": ["id": "org-2"]]) == "org-2")
        // snake_case 顶层(桌面应用本地存储所用字段名)
        #expect(ClaudeProvider.parseOrgUUID(["organization_uuid": "org-3"]) == "org-3")
        // account.organization_uuid
        #expect(ClaudeProvider.parseOrgUUID(["account": ["organization_uuid": "org-4"]]) == "org-4")
        // 都没有 → nil;空串按 nil
        #expect(ClaudeProvider.parseOrgUUID(["account": ["email": "x@y.com"]]) == nil)
        #expect(ClaudeProvider.parseOrgUUID(["organization": ["uuid": ""]]) == nil)
    }
}
