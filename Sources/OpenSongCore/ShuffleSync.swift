import Foundation

/// Generates the spoken-name audio the iPod Shuffle plays for VoiceOver. Abstracted so tests
/// can stub it (no macOS `say` invocation).
public protocol ShuffleVoiceOver: Sendable {
    func speak(_ text: String, to dest: URL) -> Bool
}

/// macOS `say` in exactly the PCM WAV format the Shuffle firmware expects.
public struct SayVoiceOver: ShuffleVoiceOver {
    public var sayPath: String
    public init(sayPath: String = "/usr/bin/say") { self.sayPath = sayPath }
    public func speak(_ text: String, to dest: URL) -> Bool {
        let r = try? Shell.run(sayPath, ["-o", dest.path, "--data-format=LEI16",
                                         "--file-format=WAVE", "--", text])
        return (r?.status ?? 1) == 0 && FileManager.default.fileExists(atPath: dest.path)
    }
}

/// Locations of the Shuffle's control files under a mounted volume.
public struct ShuffleLayout: Sendable {
    public let mountPoint: URL
    public init(mountPoint: URL) { self.mountPoint = mountPoint }
    public var control: URL { mountPoint.appendingPathComponent("iPod_Control") }
    public var musicDir: URL { control.appendingPathComponent("Music") }
    public var iTunesDir: URL { control.appendingPathComponent("iTunes") }
    public var iTunesSD: URL { iTunesDir.appendingPathComponent("iTunesSD") }
    public var speakableTracks: URL { control.appendingPathComponent("Speakable/Tracks") }
    public var speakablePlaylists: URL { control.appendingPathComponent("Speakable/Playlists") }
}

/// Syncs the library to an iPod Shuffle (3rd/4th gen): copies/transcodes the desired assets into
/// `iPod_Control/Music/`, then rebuilds the binary `iTunesSD` database and VoiceOver clips.
/// Mirrors `SyncEngine`'s desired-set logic; file adds/removes are incremental (by asset id +
/// content hash) but the database is always rebuilt wholesale (it's tiny and Apple does the same).
public struct ShuffleSyncEngine: Sendable {
    public var store: LibraryStore
    public var transcoder: Transcoder
    public var layout: ShuffleLayout
    public var settings: TranscodeSettings
    public var deviceUUID: String
    public var voiceover: ShuffleVoiceOver?

    public init(store: LibraryStore, transcoder: Transcoder, layout: ShuffleLayout,
                settings: TranscodeSettings, deviceUUID: String, voiceover: ShuffleVoiceOver? = SayVoiceOver()) {
        self.store = store; self.transcoder = transcoder; self.layout = layout
        self.settings = settings; self.deviceUUID = deviceUUID; self.voiceover = voiceover
    }

    /// Union of pinned assets and device-playlist members, ordered by id (same rule as the Walkman).
    public func desiredAssets() throws -> [AudioAsset] { try SyncEngine.desiredAssets(store) }

    private func filetype(forExtension ext: String) -> Int {
        switch ext.lowercased() {
        case "mp3", "mp2", "mp1": return 1
        case "m4a", "aac", "mp4", "m4b", "m4p": return 2
        case "wav", "aif", "aiff": return 4
        default: return 1
        }
    }
    private func ext(for asset: AudioAsset, willTranscode: Bool) -> String {
        willTranscode ? settings.format : asset.format.lowercased()
    }
    private func deviceRelPath(assetID: Int64, ext: String) -> String { "iPod_Control/Music/\(assetID).\(ext)" }

    /// Preview counts for the UI, reusing the Walkman's `SyncPlan` shape. Live: a managed file
    /// only counts as present if it is really on the mounted volume.
    public func plan() throws -> SyncPlan {
        let (total, free) = capacity()
        let fm = FileManager.default
        let mount = layout.mountPoint
        return Self.makePlan(desired: try desiredAssets(), identities: try store.allIdentitiesByID(),
                             managed: try store.deviceTracks(deviceUUID),
                             isPresent: { fm.fileExists(atPath: mount.appendingPathComponent($0.relativePath).path) },
                             totalBytes: total, freeBytes: free, settings: settings)
    }

    /// Offline plan: the iPod isn't mounted, so every managed row is assumed still present and
    /// the capacity is the one remembered from its last connection.
    public static func offlinePlan(store: LibraryStore, settings: TranscodeSettings, deviceUUID: String,
                                   totalBytes: Int64, freeBytes: Int64) throws -> SyncPlan {
        makePlan(desired: try SyncEngine.desiredAssets(store), identities: try store.allIdentitiesByID(),
                 managed: try store.deviceTracks(deviceUUID), isPresent: { _ in true },
                 totalBytes: totalBytes, freeBytes: freeBytes, settings: settings)
    }

    /// The diff with no I/O. The Shuffle keys its files by asset id (not by tag-derived path), so
    /// presence is asked per managed row rather than given as a path set.
    public static func makePlan(desired: [AudioAsset], identities: [Int64: TrackIdentity],
                                managed: [DeviceTrackRow], isPresent: (DeviceTrackRow) -> Bool,
                                totalBytes total: Int64, freeBytes free: Int64,
                                settings: TranscodeSettings) -> SyncPlan {
        let managedByAsset = Dictionary(managed.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var toAdd: [AudioAsset] = []; var upToDate: [AudioAsset] = []; var addBytes: Int64 = 0
        for asset in desired {
            if let row = managedByAsset[asset.id ?? -1], row.contentHash == asset.contentHash,
               row.recipe == settings.deviceRecipe, isPresent(row) {
                upToDate.append(asset)
            } else {
                toAdd.append(asset)
                if let ident = identities[asset.identityID] {
                    addBytes += Int64(Double(settings.bitrateKbps) * 1000 / 8 * ident.durationSec)
                }
            }
        }
        let desiredIDs = Set(desired.compactMap { $0.id })
        var removals: [DeviceTrackRow] = []; var removeBytes: Int64 = 0
        for row in managed where !desiredIDs.contains(row.assetID) {
            removals.append(row); removeBytes += row.sizeBytes
        }
        return SyncPlan(toAdd: toAdd, toRemove: removals.map { $0.relativePath }, upToDate: upToDate,
                        projectedUsedBytes: max(0, (total - free) + addBytes - removeBytes),
                        totalBytes: total, freeBytes: free, removals: removals)
    }

    public func capacity() -> (totalBytes: Int64, freeBytes: Int64) {
        let vals = try? layout.mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return (Int64(vals?.volumeTotalCapacity ?? 0), Int64(vals?.volumeAvailableCapacity ?? 0))
    }

    /// Full sync: reconcile files, then rebuild iTunesSD + VoiceOver from the desired set.
    /// `progress` fires before each step and after each completed one; see `SyncProgress`.
    public func apply(progress: (SyncProgress) -> Void = { _ in }) throws {
        let fm = FileManager.default
        for dir in [layout.musicDir, layout.iTunesDir, layout.speakableTracks, layout.speakablePlaylists] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opensong-shuffle-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let desired = try desiredAssets()
        let managed = try store.deviceTracks(deviceUUID)
        let managedByAsset = Dictionary(managed.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let desiredIDs = Set(desired.compactMap { $0.id })

        // An asset needs no transfer when its on-device file is present and content-identical.
        func reusableRow(_ asset: AudioAsset) -> DeviceTrackRow? {
            guard let assetID = asset.id, let row = managedByAsset[assetID],
                  row.contentHash == asset.contentHash, row.recipe == settings.deviceRecipe,
                  fm.fileExists(atPath: layout.mountPoint.appendingPathComponent(row.relativePath).path)
            else { return nil }
            return row
        }

        // Prepass: total the work ahead so the progress bar has a denominator. Reused files cost
        // nothing; transfers are charged their duration (transcoding dominates the wall clock).
        var weightOf: [Int64: Double] = [:]
        var transferSteps = 0
        for asset in desired {
            guard let assetID = asset.id, let ident = try store.identity(asset.identityID) else { continue }
            if reusableRow(asset) != nil { weightOf[assetID] = 0; continue }
            weightOf[assetID] = max(SyncProgress.minTrackWeight, ident.durationSec)
            transferSteps += 1
        }
        let removeCount = managed.filter { !desiredIDs.contains($0.assetID) }.count
        let totalSteps = transferSteps + removeCount
        let totalWeight = weightOf.values.reduce(0, +)
            + Double(removeCount) * SyncProgress.removeWeight + SyncProgress.finalizeWeight
        var doneWeight = 0.0
        var doneSteps = 0
        func report(_ label: String) {
            progress(SyncProgress(done: doneSteps, total: totalSteps,
                                  fraction: totalWeight > 0 ? min(1, doneWeight / totalWeight) : 0,
                                  label: label))
        }

        // Resolve each desired asset to an on-device file (reusing an up-to-date copy when possible).
        var resolved: [(asset: AudioAsset, ident: TrackIdentity, relPath: String, ftype: Int)] = []
        for asset in desired {
            guard let assetID = asset.id, let ident = try store.identity(asset.identityID) else { continue }
            if let row = reusableRow(asset) {
                let e = (row.relativePath as NSString).pathExtension
                resolved.append((asset, ident, row.relativePath, filetype(forExtension: e)))
                continue
            }
            // (Re)encode or copy.
            let master = URL(fileURLWithPath: asset.masterPath)
            let probe = try transcoder.probe.probe(master)
            let willTranscode = transcoder.needsTranscode(probe, settings)
            let e = ext(for: asset, willTranscode: willTranscode)
            let relPath = deviceRelPath(assetID: assetID, ext: e)
            let dest = layout.mountPoint.appendingPathComponent(relPath)
            let pushURL: URL; let bitrate: Int
            if willTranscode {
                report("Transcoding \(ident.title) → \(settings.format.uppercased()) \(settings.bitrateKbps)k")
                let tmp = scratch.appendingPathComponent("\(assetID).\(e)")
                try transcoder.transcode(from: master, to: tmp, tags: ident, settings: settings)
                pushURL = tmp; bitrate = settings.bitrateKbps
            } else {
                report("Copying \(ident.title)")
                pushURL = master; bitrate = probe.bitrateKbps
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: pushURL, to: dest)
            let size = Int64((try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0 ?? 0)
            try store.setDeviceTrack(DeviceTrackRow(deviceUUID: deviceUUID, relativePath: relPath,
                assetID: assetID, transcodedBitrate: bitrate, contentHash: asset.contentHash,
                sizeBytes: size, recipe: settings.deviceRecipe))
            resolved.append((asset, ident, relPath, filetype(forExtension: e)))
            doneWeight += weightOf[assetID] ?? 0; doneSteps += 1
            report("Copied \(ident.title)")
        }

        // Remove managed files no longer desired (never touches foreign files).
        for row in managed where !desiredIDs.contains(row.assetID) {
            report("Removing \(row.relativePath)")
            let url = layout.mountPoint.appendingPathComponent(row.relativePath)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            try store.deleteDeviceTrack(deviceUUID, relativePath: row.relativePath)
            doneWeight += SyncProgress.removeWeight; doneSteps += 1
        }

        // Build the database from the resolved order (index = position in `resolved`).
        let indexOfAsset = Dictionary(uniqueKeysWithValues: resolved.enumerated().map { ($0.element.asset.id!, $0.offset) })
        let useVoiceover = voiceover != nil
        let shuffleTracks = resolved.map { r in
            ShuffleTrack(devicePath: "/" + r.relPath, filetype: r.ftype, voiceover: voiceoverText(r.ident))
        }
        var shufflePlaylists: [ShufflePlaylist] = []
        for pl in try store.devicePlaylists() {
            guard let pid = pl.id else { continue }
            let idxs = try store.playlistItems(pid).compactMap { $0.id.flatMap { indexOfAsset[$0] } }
            if !idxs.isEmpty { shufflePlaylists.append(ShufflePlaylist(name: pl.name, trackIndices: idxs)) }
        }
        report("Writing iTunesSD…")
        let db = ShuffleDB.build(tracks: shuffleTracks, playlists: shufflePlaylists, voiceover: useVoiceover)
        try db.write(to: layout.iTunesSD)

        // VoiceOver clips (generate only when missing — filenames are content-derived, so unchanged
        // names are skipped automatically). Failures are non-fatal.
        if let vo = voiceover {
            report("Recording VoiceOver clips…")
            for r in resolved {
                let name = ShuffleDB.voiceoverFilename(ShuffleDB.dbid(voiceoverText(r.ident)))
                let dest = layout.speakableTracks.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { _ = vo.speak(voiceoverText(r.ident), to: dest) }
            }
            for pl in shufflePlaylists {
                let name = ShuffleDB.voiceoverFilename(ShuffleDB.dbid(pl.name))
                let dest = layout.speakablePlaylists.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { _ = vo.speak(pl.name, to: dest) }
            }
        }
        doneWeight += SyncProgress.finalizeWeight
        report("Done.")
    }

    private func voiceoverText(_ ident: TrackIdentity) -> String {
        ident.artist.isEmpty ? ident.title : "\(ident.title), \(ident.artist)"
    }
}
