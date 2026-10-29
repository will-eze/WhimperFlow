import Foundation

/// 16-bit PCM WAV, the body the dictation server takes. Half the size of
/// float32, and 16-bit is all the recogniser's 16 kHz front end uses.
public enum WAVEncoder {
    public static func encode(_ samples: ArraySlice<Float>, sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(1); put16(1)                               // PCM, mono
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2))
        put16(2); put16(16)                              // block align, bits
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBufferPointer { buffer in
            for v in buffer { put16(UInt16(bitPattern: v)) }
        }
        return data
    }
}

/// Talks to `jarvis-dictate` (Parakeet on the Jarvis server, over Tailscale).
/// One shared keep-alive session, so after the first request each chunk costs
/// a round trip and no TLS handshake. The server keeps no audio and logs no text.
public final class DictationServerClient: @unchecked Sendable {
    public struct Transcript: Equatable, Sendable {
        public var text: String
        /// Recognition time on the server.
        public var serverMs: Int
    }

    public struct Health: Equatable, Sendable {
        public var model: String
    }

    public enum ClientError: LocalizedError {
        case badStatus(Int)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "The dictation server answered \(code)."
            case .badResponse: return "The dictation server sent an unreadable answer."
            }
        }
    }

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Recognises one chunk. `timeout` bounds the whole request, so a slow or
    /// unreachable server hands the chunk to the fallback quickly.
    public func transcribe(wav: Data, timeout: TimeInterval) async throws -> Transcript {
        var request = URLRequest(url: baseURL.appendingPathComponent("dictate"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: wav)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else { throw ClientError.badStatus(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw ClientError.badResponse }
        return Transcript(text: text, serverMs: object["ms"] as? Int ?? 0)
    }

    /// `nil` when the server can't be reached or isn't ready. Also warms the
    /// connection, which is why the app calls it when a dictation starts.
    public func health(timeout: TimeInterval = 3) async -> Health? {
        let request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: timeout)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true else { return nil }
        return Health(model: object["model"] as? String ?? "?")
    }
}

/// Joins chunk transcripts in order. Parakeet ends most chunks with a full stop,
/// even mid-sentence when a cut fell in a short pause, so a chunk that ends in
/// "." and is followed by one starting lower-case loses the stop.
public enum ChunkJoiner {
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if out.isEmpty { out = part; continue }
            if out.hasSuffix("."), !out.hasSuffix(".."), let first = part.first, first.isLowercase {
                out.removeLast()
            }
            out += " " + part
        }
        return out
    }
}
