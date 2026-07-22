import Foundation

public struct Fingerprint: Sendable, Equatable {
    public var fingerprint: String
    public var durationSec: Int
    public init(fingerprint: String, durationSec: Int) {
        self.fingerprint = fingerprint; self.durationSec = durationSec
    }
}

/// Computes Chromaprint acoustic fingerprints via `fpcalc`.
public struct Fingerprinter: Sendable {
    public var fpcalcPath: String
    public init(fpcalcPath: String = "/opt/homebrew/bin/fpcalc") { self.fpcalcPath = fpcalcPath }

    public func fingerprint(_ url: URL) throws -> Fingerprint {
        let r = try Shell.run(fpcalcPath, ["-json", url.path])
        guard r.status == 0 else {
            throw NSError(domain: "Fingerprinter", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.stderrString])
        }
        struct Out: Decodable { var duration: Double; var fingerprint: String }
        let out = try JSONDecoder().decode(Out.self, from: r.stdout)
        return Fingerprint(fingerprint: out.fingerprint, durationSec: Int(out.duration.rounded()))
    }
}

public struct AcoustIDRecording: Sendable, Equatable {
    public var artist: String
    public var title: String
    public var score: Double   // 0...1 match confidence from AcoustID
}

/// Looks up a fingerprint against the free AcoustID web service. Requires a free API key;
/// callers should skip acoustic verification gracefully when no key is configured.
public struct AcoustIDClient: Sendable {
    public var http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    public func lookup(_ fp: Fingerprint, apiKey: String) async throws -> [AcoustIDRecording] {
        var comps = URLComponents(string: "https://api.acoustid.org/v2/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "meta", value: "recordings"),
            URLQueryItem(name: "duration", value: String(fp.durationSec)),
            URLQueryItem(name: "fingerprint", value: fp.fingerprint),
        ]
        let data = try await http.get(comps.url!)
        return Self.parse(data)
    }

    public static func parse(_ data: Data) -> [AcoustIDRecording] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        var out: [AcoustIDRecording] = []
        for res in results {
            let score = (res["score"] as? Double) ?? 0
            let recordings = (res["recordings"] as? [[String: Any]]) ?? []
            for rec in recordings {
                let title = (rec["title"] as? String) ?? ""
                let artists = (rec["artists"] as? [[String: Any]]) ?? []
                let artist = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                if !title.isEmpty {
                    out.append(AcoustIDRecording(artist: artist, title: title, score: score))
                }
            }
        }
        return out
    }
}
