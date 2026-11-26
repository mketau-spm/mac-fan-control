import Foundation

/// Localized string for `key` from Localizable.strings (the system language, English as fallback).
/// With arguments, the translation is a printf-style format: L("error.save", reason).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}
