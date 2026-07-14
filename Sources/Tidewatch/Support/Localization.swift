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
}

/// 就地二选一取本地化文案。co-located,避免 key 对不上。
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}
