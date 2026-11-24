import Foundation

/// Sends OpenSong library files into Apple Music (Music.app) — the reverse of the Phase 3 import.
///
/// Uses Music's own scripting `add` command rather than the "Automatically Add to Music" folder:
/// the folder *moves* whatever lands in it and reports nothing back, whereas `add` tells us per
/// file whether it worked and respects the user's "Copy files to Music Media folder" setting.
/// Songs Music already has are skipped so repeated clicks never create duplicates.
public enum AppleMusicExport {
    /// One OpenSong song to send.
    public struct Item: Sendable, Equatable {
        public var path: String
        public var title: String
        public var artist: String
        public var album: String
        public var durationSec: Double
        public init(path: String, title: String, artist: String, album: String, durationSec: Double) {
            self.path = path; self.title = title; self.artist = artist
            self.album = album; self.durationSec = durationSec
        }
    }

    /// Extensions Music.app can add natively. Anything else (FLAC, Opus, Ogg, WebM…) is converted.
    public static let nativeExtensions: Set<String> = ["mp3", "m4a", "aac", "m4b", "m4p", "wav", "aif", "aiff", "aifc"]
    /// Lossless sources convert to ALAC (no quality loss); lossy ones to 256k AAC.
    public static let losslessExtensions: Set<String> = ["flac", "ape", "wv", "alac"]

    public static func isNative(_ path: String) -> Bool {
        nativeExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Split `items` into those Music already holds and those to add. A song counts as already in
    /// Music when Music references the very same file, or a track with the same title + artist
    /// (normalized) is corroborated by album or duration — the same rule the import side uses.
    /// `knownPaths` adds file locations fetched separately (Music won't return locations in bulk
    /// for a library that also holds cloud tracks).
    public static func plan(_ items: [Item], existing: [AppleMusicTrack],
                            knownPaths: [String] = []) -> (toAdd: [Item], alreadyIn: [Item]) {
        let paths = Set(existing.compactMap { $0.location.map(canonical) } + knownPaths.map(canonical))
        var byKey: [String: [AppleMusicTrack]] = [:]
        for t in existing {
            byKey[AppleMusicCompare.normalize(t.name) + "␟" + AppleMusicCompare.normalize(t.artist), default: []].append(t)
        }
        var toAdd: [Item] = [], already: [Item] = []
        var seen = Set<String>()   // the same file selected twice (e.g. via album + song) adds once
        for it in items {
            let p = canonical(it.path)
            guard seen.insert(p).inserted else { continue }
            let key = AppleMusicCompare.normalize(it.title) + "␟" + AppleMusicCompare.normalize(it.artist)
            let lib = AppleMusicCompare.LibraryTrack(title: it.title, artist: it.artist,
                                                     album: it.album, durationSec: it.durationSec)
            let inMusic = paths.contains(p)
                || (byKey[key]?.contains { AppleMusicCompare.matches($0, lib) } ?? false)
            if inMusic { already.append(it) } else { toAdd.append(it) }
        }
        return (toAdd, already)
    }

    static func canonical(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping
    }

    /// ffmpeg arguments converting `src` into a Music-compatible `.m4a` at `dst`, keeping tags and
    /// cover art.
    public static func convertArgs(src: String, dst: String) -> [String] {
        let lossless = losslessExtensions.contains((src as NSString).pathExtension.lowercased())
        var args = ["-y", "-i", src, "-map", "0:a:0", "-map", "0:v?", "-map_metadata", "0"]
        args += lossless ? ["-c:a", "alac"] : ["-c:a", "aac", "-b:a", "256k"]
        args += ["-c:v", "copy", "-disposition:v", "attached_pic", dst]
        return args
    }
}

extension AppleMusicBridge {
    /// Every track in the Music library (flat; including album-less ones, unlike `libraryAlbums`).
    public func libraryTracks(trackLimit: Int = 50000) throws -> [AppleMusicTrack] {
        let r = try Shell.run(osascriptPath, ["-l", "JavaScript", "-e", Self.libraryScript(trackLimit: trackLimit)])
        guard r.status == 0 else { throw AMError.failed(r.stderrString) }
        return AppleMusicParser.parse(r.stdout).first?.tracks ?? []
    }

    /// POSIX paths of every local file in the Music library. Asked of the library's file tracks
    /// only, since a bulk `location` read over all tracks fails as soon as one is cloud-only.
    public func libraryFileLocations() throws -> [String] {
        let script = """
        function run() {
          const ft = Application('Music').libraryPlaylists[0].fileTracks;
          const out = [];
          for (const l of ft.location()) { try { if (l) out.push(Path(l).toString()); } catch (e) {} }
          return JSON.stringify(out);
        }
        """
        let r = try Shell.run(osascriptPath, ["-l", "JavaScript", "-e", script])
        guard r.status == 0 else { throw AMError.failed(r.stderrString) }
        return ((try? JSONSerialization.jsonObject(with: r.stdout)) as? [String]) ?? []
    }

    /// Add local files to Music. Returns the paths Music refused (each with its error text);
    /// an empty result means everything was added.
    public func addFiles(_ paths: [String]) throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let json = String(data: try JSONSerialization.data(withJSONObject: paths), encoding: .utf8)!
        let script = """
        function run() {
          const Music = Application('Music');
          try { Music.launch(); } catch (e) {}
          const paths = \(json);
          const failed = {};
          for (const p of paths) {
            try { Music.add(Path(p)); } catch (e) { failed[p] = String(e); }
          }
          return JSON.stringify(failed);
        }
        """
        let r = try Shell.run(osascriptPath, ["-l", "JavaScript", "-e", script])
        guard r.status == 0 else { throw AMError.failed(r.stderrString) }
        let obj = (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: String]
        return obj ?? [:]
    }
}

/// Outcome of asking Music to sync its cloud library.
public enum CloudLibraryUpdate: Sendable, Equatable {
    case triggered
    case unavailable          // no "Update Cloud Library" item (Sync Library off) or it stayed disabled
    case needsAccessibility   // macOS hasn't allowed OpenSong to press other apps' menu items
    case failed(String)

    /// Map the UI script's output/error text to an outcome. Pure, so it's testable.
    public static func parse(status: Int32, stdout: String, stderr: String) -> CloudLibraryUpdate {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 {
            switch out {
            case "clicked": return .triggered
            case "disabled", "missing": return .unavailable
            default: return .failed(out)
            }
        }
        // -25211 / "assistive access": Accessibility not granted; -1743: not allowed to control System Events.
        if stderr.contains("-25211") || stderr.contains("-1743")
            || stderr.localizedCaseInsensitiveContains("assistive") {
            return .needsAccessibility
        }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension AppleMusicBridge {
    /// Press Music's File ▸ Library ▸ Update Cloud Library. Music has no scripting command for this,
    /// so it's a UI script (needs Accessibility permission). The item stays disabled until Music has
    /// a window, hence the `reopen`; we never bring Music to the front.
    public func updateCloudLibrary() -> CloudLibraryUpdate {
        let script = """
        tell application "Music" to reopen
        tell application "System Events"
          tell process "Music"
            repeat with attempt from 1 to 6
              set state to "missing"
              repeat with mi in (menu items of menu 1 of menu bar item 3 of menu bar 1)
                try
                  repeat with sub in (menu items of menu 1 of mi)
                    if (name of sub as text) contains "Cloud Library" then
                      if enabled of sub then
                        click sub
                        return "clicked"
                      end if
                      set state to "disabled"
                    end if
                  end repeat
                end try
              end repeat
              if state is "missing" then return "missing"
              delay 0.5
            end repeat
            return state
          end tell
        end tell
        """
        do {
            let r = try Shell.run(osascriptPath, ["-e", script])
            return .parse(status: r.status, stdout: r.stdoutString, stderr: r.stderrString)
        } catch {
            return .failed("\(error)")
        }
    }
}
