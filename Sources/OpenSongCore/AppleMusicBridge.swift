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
            const tracks = [];
            let ts; try { ts = pl.tracks(); } catch (e) { ts = []; }
            const m = Math.min(ts.length, \(tracksPerPlaylist));
            for (let j = 0; j < m; j++) {
              const t = ts[j];
              let loc = null, cloud = false;
              try { const l = t.location(); if (l) loc = Path(l).toString(); } catch (e) {}
              try { cloud = String(t.cloudStatus()) === 'subscription' || String(t.cloudStatus()) === 'matched'; } catch (e) {}
              let name2='', artist='', album='', dur=0;
              try { name2 = t.name(); } catch (e) {}
              try { artist = t.artist(); } catch (e) {}
              try { album = t.album(); } catch (e) {}
              try { dur = t.duration(); } catch (e) {}
              tracks.push({name: name2, artist: artist, album: album, duration: dur, location: loc, cloud: cloud});
            }
            out.push({name: name, kind: 'playlist', tracks: tracks});
          }
          return JSON.stringify({collections: out});
        }
        """
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
