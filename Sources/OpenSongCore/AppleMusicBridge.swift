import Foundation

/// Reads the user's Apple Music library via a JXA (`osascript -l JavaScript`) script that
/// emits JSON. The osascript call is thin; parsing/comparison live in testable pure code.
/// First use triggers a one-time macOS Automation permission prompt.
public struct AppleMusicBridge: Sendable {
    public var osascriptPath: String
    public init(osascriptPath: String = "/usr/bin/osascript") { self.osascriptPath = osascriptPath }

    public enum AMError: Error, CustomStringConvertible {
        case failed(String)
        public var description: String { if case .failed(let m) = self { return m }; return "error" }
    }

    /// JXA: emit the first `playlistLimit` user playlists (with tracks) as JSON.
    /// Fetches each track property in BULK (one Apple Event per property per playlist)
    /// instead of per-track — orders of magnitude faster on large libraries.
    private static func script(playlistLimit: Int, tracksPerPlaylist: Int) -> String {
        """
        function run() {
          const Music = Application('Music');
          try { Music.launch(); } catch (e) {}
          const out = [];
          const pls = Music.userPlaylists();
          const n = Math.min(pls.length, \(playlistLimit));
          for (let i = 0; i < n; i++) {
            const pl = pls[i];
            let name; try { name = pl.name(); } catch (e) { continue; }
            let smart = false, cls = '';
            try { smart = pl.smart(); } catch (e) {}
            try { cls = Automation.getDisplayString(pl.class()); } catch (e) { try { cls = String(pl.class()); } catch (e2) {} }
            let names = [], artists = [], albums = [], durs = [], locs = [], clouds = [];
            try { names = pl.tracks.name(); } catch (e) {}
            try { artists = pl.tracks.artist(); } catch (e) {}
            try { albums = pl.tracks.album(); } catch (e) {}
            try { durs = pl.tracks.duration(); } catch (e) {}
            try { locs = pl.tracks.location(); } catch (e) {}
            try { clouds = pl.tracks.cloudStatus(); } catch (e) {}
            const tracks = [];
            const m = Math.min(names.length, \(tracksPerPlaylist));
            for (let j = 0; j < m; j++) {
              let loc = null;
              try { if (locs[j]) loc = Path(locs[j]).toString(); } catch (e) {}
              const cs = clouds[j] ? String(clouds[j]) : '';
              tracks.push({
                name: names[j] || '', artist: artists[j] || '', album: albums[j] || '',
                duration: durs[j] || 0, location: loc,
                cloud: (cs === 'subscription' || cs === 'matched')
              });
            }
            out.push({name: name, kind: 'playlist', smart: smart, cls: cls, tracks: tracks});
          }
          return JSON.stringify({collections: out});
        }
        """
    }

    /// Fetch a single playlist's cover artwork, writing the raw image bytes to `path`.
    /// Uses AppleScript (which can write `raw data` to a file). Returns true on success.
    public func writePlaylistArtwork(named name: String, to path: String) -> Bool {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
          try
            set d to raw data of artwork 1 of playlist "\(escaped)"
          on error
            return "no-art"
          end try
        end tell
        try
          set f to open for access POSIX file "\(escPath)" with write permission
          set eof f to 0
          write d to f
          close access f
          return "ok"
        on error
          try
            close access POSIX file "\(escPath)"
          end try
          return "write-fail"
        end try
        """
        let r = try? Shell.run(osascriptPath, ["-e", script])
        return (r?.stdoutString.contains("ok") ?? false)
    }

    public func playlists(limit: Int = 2000, tracksPerPlaylist: Int = 1000) throws -> [AppleMusicCollection] {
        let r = try Shell.run(osascriptPath, ["-l", "JavaScript", "-e",
            Self.script(playlistLimit: limit, tracksPerPlaylist: tracksPerPlaylist)])
        guard r.status == 0 else { throw AMError.failed(r.stderrString) }
        return AppleMusicParser.parse(r.stdout)
    }

    /// Whether Music.app is available/running (cheap check; also surfaces permission issues).
    public func isMusicRunning() -> Bool {
        let r = try? Shell.run(osascriptPath, ["-l", "JavaScript", "-e",
            "function run(){ return Application('Music').running() ? 'yes':'no'; }"])
        return r?.stdoutString.contains("yes") ?? false
    }
}
