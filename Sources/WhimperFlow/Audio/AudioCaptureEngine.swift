import AVFoundation
import AudioToolbox

/// Microphone capture: feeds PCM buffers to the recognizer and RMS levels to
/// the HUD waveform.
final class AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// Called on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Normalized 0…1 loudness, called on the main thread.
    var onLevel: ((Float) -> Void)?

    func start(deviceUID: String?, voiceProcessing: Bool = false) throws {
        guard !isRunning else { return }

        if let uid = deviceUID, let deviceID = AudioDevices.deviceID(forUID: uid) {
            setInputDevice(deviceID)
        }

        let input = engine.inputNode
        // Apple's echo-cancellation + noise-suppression DSP. Best effort: some
        // devices refuse it, and plain capture works fine without.
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try? input.setVoiceProcessingEnabled(voiceProcessing)
        }
        // On some Macs the voice-processed input surfaces the raw mic array
        // (e.g. 5 channels) with a near-silent first channel, which starves
        // the recognizer. A working VP stream is mono; anything else, revert.
        if input.isVoiceProcessingEnabled, input.outputFormat(forBus: 0).channelCount != 1 {
            try? input.setVoiceProcessingEnabled(false)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "WhimperFlow.Audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No usable audio input device."
            ])
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            let level = AudioCaptureEngine.normalizedLevel(of: buffer)
            DispatchQueue.main.async { self.onLevel?(level) }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// RMS → dB → 0…1, tuned so normal speech sweeps most of the range.
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50 dB…-5 dB to 0…1.
        return min(1, max(0, (db + 50) / 45))
    }
}
