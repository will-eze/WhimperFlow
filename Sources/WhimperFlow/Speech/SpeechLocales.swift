import Foundation
import Speech

struct SpeechLocaleOption: Identifiable, Equatable {
    let identifier: String
    let displayName: String
    let supportsOnDevice: Bool
    var id: String { identifier }
}

/// Locale catalog for the settings language picker. On-device support depends
/// on which Dictation languages are downloaded in System Settings.
enum SpeechLocales {
    static func options() -> [SpeechLocaleOption] {
        SFSpeechRecognizer.supportedLocales()
            .map { locale -> SpeechLocaleOption in
                let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                let onDevice = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
                return SpeechLocaleOption(identifier: locale.identifier, displayName: name, supportsOnDevice: onDevice)
            }
            .sorted {
                $0.supportsOnDevice != $1.supportsOnDevice
                    ? $0.supportsOnDevice
                    : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }
}
