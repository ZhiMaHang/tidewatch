import Foundation

/// App 版本号的单一事实源。打包后从 Info.plist 读 `CFBundleShortVersionString`;
/// 开发态(`swift run`,无 bundle plist)回退到内置常量。
enum AppVersion {
    /// 与 `scripts/build-app.sh` 写进 Info.plist 的 CFBundleShortVersionString 保持一致
    static let fallback = "0.1.0"

    static var current: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        return fallback
    }
}

/// 一次版本检查的结果。仅当线上版本严格高于本机版本时才构造。
struct UpdateInfo: Equatable {
    let latest: String
    let notesZh: String?
    let notesEn: String?
    let url: URL?

    /// 按运行时语言取 release notes,缺一种就回退另一种(latest.json 里的文案由服务端给,双语可选)
    var localizedNotes: String? {
        let zh = notesZh?.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = notesEn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let (primary, fallback) = AppLanguage.current == .zh ? (zh, en) : (en, zh)
        if let p = primary, !p.isEmpty { return p }
        if let f = fallback, !f.isEmpty { return f }
        return nil
    }
}

/// 匿名版本检查:向自有域拉一个静态 `latest.json`,判断是否有新版。
///
/// 隐私红线(用户 2026-07-14 批准范围,一步不越):
/// - 请求里**只带当前版本号**(query `v` + User-Agent),绝不带账号/用量/邮箱/设备指纹;
/// - 不收发 cookie;走 HTTPS;端点落自有域(智码航官网 offical / 1Panel + OpenResty)。
///
/// 这个 GET 本身在 OpenResty 访问日志里按版本号被动计数(装机/留存的间接度量),**无需任何后端服务**——
/// 服务端只放一个静态 JSON 文件。
enum UpdateChecker {
    /// 端点落自有域(offical,zhimahang.com,静态门户,1Panel + OpenResty 托管)。零后端。
    static let endpoint = URL(string: "https://zhimahang.com/tidewatch/latest.json")!

    /// 手动检查用的详细结果(能区分「已是最新」与「检查失败」,给用户明确反馈)。
    enum CheckResult: Equatable {
        case newer(UpdateInfo)   // 有严格更新的线上版本
        case upToDate(String)    // 已是最新(带当前版本号)
        case failed              // 网络错误 / 非 2xx / 解析失败
    }

    /// 拉取并判断:返回 non-nil 仅当线上版本严格高于本机版本。
    /// 自动回路用(失败/已是最新都返回 nil 并静默,绝不打断用户)。
    static func fetchIfNewer() async -> UpdateInfo? {
        if case .newer(let info) = await checkNow() { return info }
        return nil
    }

    /// 拉取一次并返回详细结果。手动「立即检查更新」用它区分反馈。
    static func checkNow() async -> CheckResult {
        let current = AppVersion.current
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return .failed }
        // 版本号放 query,方便 OpenResty 访问日志按版本分段计数(装机/留存度量)。只带版本号,别的都不带。
        comps.queryItems = [URLQueryItem(name: "v", value: current)]
        guard let url = comps.url else { return .failed }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 覆盖 URLSession 默认 UA(默认会带 CFNetwork/Darwin 版本 = 粗粒度设备指纹);这里只留版本号。
        req.setValue("Tidewatch/\(current) (version-check)", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false             // 不收发 cookie,杜绝被动追踪
        req.cachePolicy = .reloadIgnoringLocalCacheData // 确保 GET 真到达服务器,访问日志计数才准

        guard let (data, resp) = try? await HTTP.session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(LatestPayload.self, from: data) else {
            return .failed
        }
        let latest = payload.latest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latest.isEmpty else { return .failed }
        guard isNewer(latest, than: current) else { return .upToDate(current) }
        return .newer(UpdateInfo(latest: latest,
                                 notesZh: payload.notes,
                                 notesEn: payload.notes_en,
                                 url: payload.url.flatMap(URL.init(string:))))
    }

    /// 语义化版本比较:`lhs` 是否严格新于 `rhs`。
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }

    /// 按 `.` 拆成数字逐段比较;`-`/`+` 后的 pre-release/build 元数据一律截断忽略;非数字段按 0 处理(防御式)。
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func numbers(_ s: String) -> [Int] {
            let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = numbers(a), pb = numbers(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// `latest.json` 结构。字段全部可选(除 latest),缺字段/多字段都容错。
private struct LatestPayload: Decodable {
    let latest: String       // 线上最新版本号,如 "0.2.0"(必填)
    let notes: String?       // release notes(中文)
    let notes_en: String?    // release notes(英文)
    let url: String?         // 下载/更新落地页 URL(点「下载更新」打开)
}
