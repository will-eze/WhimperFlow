import AppKit

/// Subtle system-sound feedback for session transitions.
final class SoundCues {
    enum Cue {
        case begin, end, success, cancel

        var soundName: String {
            switch self {
            case .begin: return "Pop"
            case .end: return "Tink"
            case .success: return "Morse"
            case .cancel: return "Basso"
            }
        }
    }

    func play(_ cue: Cue) {
        guard let sound = NSSound(named: cue.soundName) else { return }
        sound.volume = 0.28
        sound.play()
    }
}
