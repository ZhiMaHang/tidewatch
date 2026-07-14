import Foundation

/// 语言模式:跟随系统 / 强制中文 / 强制英文。持久化在 UserDefaults。
enum LanguageMode: String, CaseIterable, Identifiable, Equatable {
    case system, zh, en
    var id: String { rawValue }

    static let storageKey = "languageMode"

    /// 菜单里显示的名字。"跟随系统"随当前语言变;中/英固定,方便用户认。
    var label: String {
        switch self {
        case .system: return L("跟随系统", "Follow system")
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    static var stored: LanguageMode {
        LanguageMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

/// 运行时语言。优先用用户手动选的语言;选"跟随系统"或未设时,按系统首选语言
/// (简/繁/港台任一 zh 变体→中文,其它→英文)判定。
enum AppLanguage {
    case zh, en

    static var current: AppLanguage {
        switch LanguageMode.stored {
        case .zh: return .zh
        case .en: return .en
        case .system:
            let lang = (Locale.preferredLanguages.first ?? "en").lowercased()
            return lang.hasPrefix("zh") ? .zh : .en
        }
    }

    /// 界面语言对应的 Locale,用于日期/时间格式化。用固定 locale(而非系统 locale)
    /// 让日期与界面文字语言始终一致——否则英文界面下 `Date.formatted` 仍会显示"年月日"。
    static var locale: Locale {
        current == .zh ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
    }
}

extension Date {
    /// 跟随 App 界面语言(而非系统 locale)格式化日期/时间。
    func localized(date: Date.FormatStyle.DateStyle = .abbreviated,
                   time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(AppLanguage.locale))
    }
}

/// 就地二选一取本地化文案。co-located,避免 key 对不上。
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}
