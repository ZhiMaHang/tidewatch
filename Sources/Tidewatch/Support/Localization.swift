import Foundation

/// 界面固定中文(用户 2026-07-15 拍板去掉英文,只保留中文)。
/// 保留 L(zh, en) 的双参签名,几百个调用点一个不动;若将来恢复双语,
/// 还原本文件 + 菜单里的语言 Picker 即可(完整实现见 v0.1.2 的 git 历史)。
@inline(__always)
func L(_ zh: String, _ en: String) -> String { zh }

/// 日期/时间格式化用的 locale,与界面语言保持一致(固定中文)。
enum AppLanguage {
    static let locale = Locale(identifier: "zh_CN")
}

extension Date {
    /// 跟随 App 界面语言(而非系统 locale)格式化日期/时间。
    func localized(date: Date.FormatStyle.DateStyle = .abbreviated,
                   time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(AppLanguage.locale))
    }
}
