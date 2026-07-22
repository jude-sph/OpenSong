import Foundation

public struct ProbeResult: Sendable, Equatable {
    public var durationSec: Double
    public var bitrateKbps: Int
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var tags: [String: String]   // lowercased keys
}

/// Reads audio metadata via `ffprobe` (JSON output).
public struct AudioProbe: Sendable {
    public var ffprobePath: String
    public init(ffprobePath: String = "/opt/homebrew/bin/ffprobe") {
        self.ffprobePath = ffprobePath
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case failed(String)
        case noAudioStream
        public var description: String {
            switch self {
            case .failed(let m): return "ffprobe failed: \(m)"
            case .noAudioStream: return "no audio stream found"
            }
        }
    }

    // Minimal ffprobe JSON model.
    private struct Probe: Decodable {
        struct Stream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var sample_rate: String?
            var channels: Int?
            var bit_rate: String?
        }
        struct Format: Decodable {
            var duration: String?
            var bit_rate: String?
            var tags: [String: String]?
        }
        var streams: [Stream]
        var format: Format
    }

    public func probe(_ url: URL) throws -> ProbeResult {
        let r = try Shell.run(ffprobePath, [
            "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path
        ])
        guard r.status == 0 else { throw ProbeError.failed(r.stderrString) }
        let decoded = try JSONDecoder().decode(Probe.self, from: r.stdout)
        guard let audio = decoded.streams.first(where: { $0.codec_type == "audio" }) else {
            throw ProbeError.noAudioStream
        }
        let duration = Double(decoded.format.duration ?? "") ?? 0
        let bitrateStr = decoded.format.bit_rate ?? audio.bit_rate ?? "0"
        let bitrateKbps = (Int(bitrateStr) ?? 0) / 1000
        let sampleRate = Int(audio.sample_rate ?? "0") ?? 0
        var tags: [String: String] = [:]
        for (k, v) in decoded.format.tags ?? [:] { tags[k.lowercased()] = v }
        return ProbeResult(durationSec: duration, bitrateKbps: bitrateKbps,
                           codec: audio.codec_name ?? "unknown", sampleRate: sampleRate,
                           channels: audio.channels ?? 0, tags: tags)
    }
}
