import Foundation

public enum SpectralVerdict: Sendable, Equatable {
    case good
    case suspicious(String)   // e.g. "cutoff 15 kHz well below 320 kbps expectation"

    public var isGood: Bool { if case .good = self { return true } else { return false } }
}

/// Estimates the real audio bandwidth (frequency cutoff) via ffmpeg band-energy analysis,
/// to flag upsampled / low-quality sources masquerading as high bitrate.
public struct SpectralAnalyzer: Sendable {
    public var ffmpegPath: String
    public init(ffmpegPath: String = "/opt/homebrew/bin/ffmpeg") { self.ffmpegPath = ffmpegPath }

    private static let bands: [Int] = [4000, 6000, 8000, 10000, 12000, 14000, 16000, 18000, 20000]

    /// RMS level (dB) of a 2 kHz-wide band centered at `centerHz`.
    private func bandRMSdB(_ url: URL, _ centerHz: Int) throws -> Double {
        let r = try Shell.run(ffmpegPath, [
            "-hide_banner", "-i", url.path,
            "-af", "bandpass=f=\(centerHz):width_type=h:w=2000,astats=measure_perchannel=none:measure_overall=RMS_level",
            "-f", "null", "-"
        ])
        // astats prints "RMS level dB: -xx.xx" (or "-inf") to stderr.
        let text = r.stderrString
        var value = -120.0
        if let range = text.range(of: #"RMS level dB:\s*(-?[\d.]+|-?inf)"#, options: .regularExpression) {
            let frag = String(text[range])
            if frag.contains("inf") { value = -120 }
            else if let m = frag.range(of: #"-?[\d.]+"#, options: .regularExpression) {
                value = Double(frag[m]) ?? -120
            }
        }
        return value
    }

    /// Estimated frequency cutoff in Hz: the highest band whose energy stays within ~35 dB
    /// of the strongest band (below that, it's in the noise floor).
    public func cutoffHz(_ url: URL) throws -> Double {
        let energies = try Self.bands.map { try bandRMSdB(url, $0) }
        guard let peak = energies.max() else { return 0 }
        // 25 dB below the strongest band. (A 2 kHz analysis bandpass smears a hard edge
        // upward by a few kHz, so detected cutoff runs a bit high — fine for flagging.)
        let threshold = peak - 25
        var cutoff = Double(Self.bands.first ?? 0)
        for (i, e) in energies.enumerated() where e >= threshold {
            cutoff = Double(Self.bands[i])
        }
        return cutoff
    }

    /// Expected cutoff (Hz) for a claimed bitrate; a real cutoff well below suggests
    /// the file was upsampled from a lower-quality source.
    public func verdict(cutoffHz: Double, bitrateKbps: Int) -> SpectralVerdict {
        let expected: Double
        switch bitrateKbps {
        case ..<160: expected = 16000
        case 160..<224: expected = 18000
        case 224..<288: expected = 19000
        default: expected = 20000    // 288k+ / lossless
        }
        if cutoffHz < expected - 3000 {
            return .suspicious("cutoff \(Int(cutoffHz / 1000)) kHz below \(bitrateKbps) kbps expectation")
        }
        return .good
    }

    /// Render a spectrogram PNG (for the UI "quality reveal").
    public func spectrogram(_ url: URL, to png: URL, size: String = "640x320") throws {
        let r = try Shell.run(ffmpegPath, [
            "-y", "-hide_banner", "-i", url.path,
            "-lavfi", "showspectrumpic=s=\(size):legend=disabled", png.path
        ])
        guard r.status == 0 else {
            throw NSError(domain: "SpectralAnalyzer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
    }
}
