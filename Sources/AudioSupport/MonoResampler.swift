import AVFoundation

/// Turns capture buffers of any format into 16 kHz mono float samples, the
/// input the dictation server's recogniser expects.
///
/// Channels are averaged before resampling. Letting `AVAudioConverter` reduce
/// channels itself keeps only the first, which on multi-channel inputs (a
/// voice-processed mic array, an aggregate device) can be the near-silent one;
/// that is ACCURACY_PLAN finding 3. Streaming: the converter keeps its filter
/// state between buffers, so feeding a dictation buffer by buffer gives the
/// same samples as converting it whole.
public final class MonoResampler {
    public static let outputRate: Double = 16_000

    private let inputRate: Double
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                       channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate,
                                         channels: 1, interleaved: false) else { return nil }
        inputRate = inputFormat.sampleRate
        monoFormat = mono
        outputFormat = output
        // Already 16 kHz: averaging the channels is all there is to do.
        converter = inputRate == Self.outputRate ? nil : AVAudioConverter(from: mono, to: output)
        if inputRate != Self.outputRate, converter == nil { return nil }
    }

    /// Converts one buffer. Float32 deinterleaved input only, which is what
    /// `AVAudioEngine` taps and `AVAudioFile.processingFormat` deliver.
    public func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = downmix(buffer) else { return [] }
        return convert(mono, endOfStream: false)
    }

    /// Drains the converter's last few samples at the end of a dictation.
    public func flush() -> [Float] {
        guard converter != nil, let empty = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1) else { return [] }
        return convert(empty, endOfStream: true)
    }

    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let source = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += source[c][i] }
            out[i] = sum * scale
        }
        return mono
    }

    private func convert(_ mono: AVAudioPCMBuffer, endOfStream: Bool) -> [Float] {
        guard let converter else {
            guard let data = mono.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: Int(mono.frameLength)))
        }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * Self.outputRate / inputRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied || endOfStream {
                status.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// Reads a whole audio file as 16 kHz mono samples.
    public static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let resampler = MonoResampler(inputFormat: file.processingFormat) else {
            throw NSError(domain: "MonoResampler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "can't convert \(url.lastPathComponent) to 16 kHz mono"
            ])
        }
        var samples: [Float] = []
        let block: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block) else { break }
            try file.read(into: buffer, frameCount: block)
            if buffer.frameLength == 0 { break }
            samples += resampler.process(buffer)
        }
        return samples + resampler.flush()
    }
}
