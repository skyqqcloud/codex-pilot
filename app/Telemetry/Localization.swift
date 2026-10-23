import Foundation

/// Presentation-only localization. Call IDs, models, message contents and
/// measurement values remain independent of the selected app language.
enum L10n {
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    static let isChinese = locale.language.languageCode?.identifier == "zh"

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main, locale: locale)
    }

    /// Fixed labels returned by the backend use the same catalog as native UI.
    /// Never use this to translate user messages or model output.
    static func key(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
