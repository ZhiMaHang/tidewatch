import Foundation

/// 运行时语言:系统首选语言是中文(简体/繁体/港台任一变体,标识符以 zh 开头)就用中文,其它一律英文。
/// 不走 SPM 资源打包的 .strings,直接在代码里按语言取串,便于把繁体也归到中文。
enum AppLanguage {
    case zh, en

    static let current: AppLanguage = {
        let lang = (Locale.preferredLanguages.first ?? "en").lowercased()
        return lang.hasPrefix("zh") ? .zh : .en
    }()
}

/// 就地二选一取本地化文案。co-located,避免 key 对不上。
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}
