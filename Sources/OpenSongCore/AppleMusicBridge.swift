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
        // Dates cross the JSON boundary as epoch seconds; a Date object would stringify to a
        // locale-dependent form that is far more annoying to parse back.
        function epoch(d) { try { return d ? d.getTime() / 1000 : 0; } catch (e) { return 0; } }
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
            let names = [], artists = [], albumArtists = [], albums = [], durs = [], locs = [], clouds = [], tracknums = [], discnums = [], addeds = [];
            try { names = pl.tracks.name(); } catch (e) {}
            try { artists = pl.tracks.artist(); } catch (e) {}
            try { albumArtists = pl.tracks.albumArtist(); } catch (e) {}
            try { albums = pl.tracks.album(); } catch (e) {}
            try { durs = pl.tracks.duration(); } catch (e) {}
            try { locs = pl.tracks.location(); } catch (e) {}
            try { clouds = pl.tracks.cloudStatus(); } catch (e) {}
            try { tracknums = pl.tracks.trackNumber(); } catch (e) {}
            try { discnums = pl.tracks.discNumber(); } catch (e) {}
            try { addeds = pl.tracks.dateAdded(); } catch (e) {}
            const tracks = [];
            const m = Math.min(names.length, \(tracksPerPlaylist));
            for (let j = 0; j < m; j++) {
              let loc = null;
              try { if (locs[j]) loc = Path(locs[j]).toString(); } catch (e) {}
              const cs = clouds[j] ? String(clouds[j]) : '';
              tracks.push({
                name: names[j] || '', artist: artists[j] || '', albumArtist: albumArtists[j] || '',
                album: albums[j] || '', duration: durs[j] || 0, location: loc,
                cloud: (cs === 'subscription' || cs === 'matched'),
                track: tracknums[j] || 0, disc: discnums[j] || 0, added: epoch(addeds[j])
              });
            }
            out.push({name: name, kind: 'playlist', smart: smart, cls: cls, tracks: tracks});
          }
          return JSON.stringify({collections: out});
        }
        """
    }

    /// JXA: emit up to `trackLimit` of the whole library's tracks (bulk property fetch, one Apple
    /// Event per property). Grouping into albums happens in Swift (testable). Kept as a single flat
    /// "collection" so it reuses the same parser; callers regroup via `AppleMusicAlbums.group`.
    static func libraryScript(trackLimit: Int) -> String {
        """
        // Dates cross the JSON boundary as epoch seconds; a Date object would stringify to a
        // locale-dependent form that is far more annoying to parse back.
        function epoch(d) { try { return d ? d.getTime() / 1000 : 0; } catch (e) { return 0; } }
        function run() {
          const Music = Application('Music');
          try { Music.launch(); } catch (e) {}
          const lib = Music.tracks;
          let names = [], artists = [], albumArtists = [], albums = [], durs = [], locs = [], clouds = [], tracknums = [], discnums = [], addeds = [];
          try { names = lib.name(); } catch (e) {}
          try { artists = lib.artist(); } catch (e) {}
          try { albumArtists = lib.albumArtist(); } catch (e) {}
          try { albums = lib.album(); } catch (e) {}
          try { durs = lib.duration(); } catch (e) {}
          try { locs = lib.location(); } catch (e) {}
          try { clouds = lib.cloudStatus(); } catch (e) {}
          try { tracknums = lib.trackNumber(); } catch (e) {}
          try { discnums = lib.discNumber(); } catch (e) {}
          try { addeds = lib.dateAdded(); } catch (e) {}
          const tracks = [];
          const m = Math.min(names.length, \(trackLimit));
          for (let j = 0; j < m; j++) {
            let loc = null;
            try { if (locs[j]) loc = Path(locs[j]).toString(); } catch (e) {}
            const cs = clouds[j] ? String(clouds[j]) : '';
            tracks.push({
              name: names[j] || '', artist: artists[j] || '', albumArtist: albumArtists[j] || '',
              album: albums[j] || '', duration: durs[j] || 0, location: loc,
              cloud: (cs === 'subscription' || cs === 'matched'),
              track: tracknums[j] || 0, disc: discnums[j] || 0, added: epoch(addeds[j])
            });
          }
          return JSON.stringify({collections: [{name: '__library__', kind: 'playlist', tracks: tracks}]});
        }
        """
    }

    /// Read the whole library and group it into album collections (sorted by album name).
    public func libraryAlbums(trackLimit: Int = 20000) throws -> [AppleMusicCollection] {
        let r = try Shell.run(osascriptPath, ["-l", "JavaScript", "-e", Self.libraryScript(trackLimit: trackLimit)])
        guard r.status == 0 else { throw AMError.failed(r.stderrString) }
        let flat = AppleMusicParser.parse(r.stdout).first?.tracks ?? []
        return AppleMusicAlbums.group(flat)
    }

    /// Fetch an album's cover artwork (from its first track), writing raw image bytes to `path`.
    /// Returns true on success. Mirrors `writePlaylistArtwork` but keys off album+artist.
    public func writeAlbumArtwork(album: String, artist: String, to path: String) -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let escPath = esc(path)
        let condition = artist.isEmpty
            ? "(first track whose album is \"\(esc(album))\")"
            : "(first track whose album is \"\(esc(album))\" and album artist is \"\(esc(artist))\")"
        let script = """
        tell application "Music"
          try
            set t to \(condition)
          on error
            try
              set t to (first track whose album is "\(esc(album))")
            on error
              return "no-track"
            end try
          end try
          try
            set d to raw data of artwork 1 of t
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
