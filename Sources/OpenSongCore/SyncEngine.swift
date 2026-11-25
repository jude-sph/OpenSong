import Foundation

/// The diff between the desired device set and what's currently on the device.
public struct SyncPlan: Sendable {
    public var toAdd: [AudioAsset]
    public var toRemove: [String]        // backslash relative paths
    public var upToDate: [AudioAsset]
    public var projectedUsedBytes: Int64
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// The `device_track` rows behind `toRemove`, in the same order — so a removal can be traced
    /// back to its asset (and undone) without re-reading the store.
    public var removals: [DeviceTrackRow] = []
}

/// Reconciles the device toward the desired set (pinned assets ∪ device-playlist members):
/// transcode-or-copy additions, remove only OpenSong-managed tracks no longer desired
/// (never foreign files), and (re)write `.m3u8` playlists. Idempotent.
public struct SyncEngine: Sendable {
    public var store: LibraryStore
    public var transcoder: Transcoder
    public var device: DeviceManager
    public var settings: TranscodeSettings
    public var deviceUUID: String

    public init(store: LibraryStore, transcoder: Transcoder, device: DeviceManager,
                settings: TranscodeSettings, deviceUUID: String) {
        self.store = store; self.transcoder = transcoder; self.device = device
        self.settings = settings; self.deviceUUID = deviceUUID
    }

    /// Union of pinned assets and members of device-flagged playlists, de-duplicated.
    public func desiredAssets() throws -> [AudioAsset] { try Self.desiredAssets(store) }

    /// Union of pinned assets and members of device-flagged playlists, de-duplicated, ordered by id.
    /// Static so the offline plan (no device mounted) shares exactly the same definition.
    public static func desiredAssets(_ store: LibraryStore) throws -> [AudioAsset] {
        var byID: [Int64: AudioAsset] = [:]
        for a in try store.pinnedAssets() { if let id = a.id { byID[id] = a } }
        for pl in try store.devicePlaylists() {
            guard let pid = pl.id else { continue }
            for a in try store.playlistItems(pid) { if let id = a.id { byID[id] = a } }
        }
        return byID.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    private static func estimatedDeviceSize(_ asset: AudioAsset, _ ident: TrackIdentity,
                                            _ transcoder: Transcoder, _ settings: TranscodeSettings) -> Int64 {
        // If it will be transcoded, estimate from target bitrate × duration; else the master size.
        let probeLike = ProbeResult(durationSec: ident.durationSec, bitrateKbps: asset.bitrateKbps,
                                    codec: asset.format, sampleRate: asset.sampleRate,
                                    channels: 2, tags: [:])
        if transcoder.needsTranscode(probeLike, settings) {
            return Int64(Double(settings.bitrateKbps) * 1000.0 / 8.0 * ident.durationSec)
        }
        return asset.sizeBytes
    }

    /// Live plan: diff the desired set against the managed-track rows *and* a walk of the mounted
    /// device, with the volume's real capacity.
    public func plan() throws -> SyncPlan {
        let desired = try desiredAssets()
        let managed = try store.deviceTracks(deviceUUID)
        let actualPaths = Set(try device.listManagedTracks())
        let (total, free) = try device.volume.capacity()
        return Self.makePlan(desired: desired, identities: try store.allIdentitiesByID(),
                             managed: managed, actualPaths: actualPaths,
                             totalBytes: total, freeBytes: free,
                             settings: settings, transcoder: transcoder)
    }

    /// Offline plan: no device mounted, so assume nothing on it changed since the last sync — the
    /// managed-track rows stand in for the walk, and the capacity is the one remembered from when
    /// it was last connected. Reconnecting runs the live `plan()`, which catches any drift.
    public static func offlinePlan(store: LibraryStore, transcoder: Transcoder, settings: TranscodeSettings,
                                   deviceUUID: String, totalBytes: Int64, freeBytes: Int64) throws -> SyncPlan {
        let managed = try store.deviceTracks(deviceUUID)
        return makePlan(desired: try desiredAssets(store), identities: try store.allIdentitiesByID(),
                        managed: managed, actualPaths: Set(managed.map { $0.relativePath }),
                        totalBytes: totalBytes, freeBytes: freeBytes,
                        settings: settings, transcoder: transcoder)
    }

    /// The diff itself, with no I/O: desired assets vs. the managed rows and the set of paths
    /// actually present. `transcoder` is only consulted for its (pure) transcode decision when
    /// estimating sizes.
    public static func makePlan(desired: [AudioAsset], identities idents: [Int64: TrackIdentity],
                                managed: [DeviceTrackRow], actualPaths: Set<String>,
                                totalBytes total: Int64, freeBytes free: Int64,
                                settings: TranscodeSettings, transcoder: Transcoder) -> SyncPlan {
        let managedByPath = Dictionary(managed.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        let usedNow = total - free

        var toAdd: [AudioAsset] = []
        var upToDate: [AudioAsset] = []
        var desiredPaths = Set<String>()
        var addBytes: Int64 = 0

        for asset in desired {
            guard let ident = idents[asset.identityID] else { continue }
            let relPath = DeviceRelativePath.backslashPath(for: ident)
            desiredPaths.insert(relPath)
            let present = actualPaths.contains(relPath)
            let tracked = managedByPath[relPath]
            if present, let tracked, tracked.assetID == asset.id, tracked.contentHash == asset.contentHash,
               tracked.recipe == settings.deviceRecipe {
                upToDate.append(asset)
            } else {
                toAdd.append(asset)
                addBytes += estimatedDeviceSize(asset, ident, transcoder, settings)
            }
        }

        // Remove only managed tracks that are no longer desired (foreign files untouched).
        var removals: [DeviceTrackRow] = []
        var removeBytes: Int64 = 0
        for row in managed where !desiredPaths.contains(row.relativePath) {
            removals.append(row)
            removeBytes += row.sizeBytes
        }

        let projectedUsed = max(0, usedNow + addBytes - removeBytes)
        return SyncPlan(toAdd: toAdd, toRemove: removals.map { $0.relativePath }, upToDate: upToDate,
                        projectedUsedBytes: projectedUsed, totalBytes: total, freeBytes: free,
                        removals: removals)
    }

    /// Execute the plan: transcode/copy additions, remove stale managed tracks, rewrite playlists.
    /// `progress` fires before each step and after each completed one; see `SyncProgress`.
    public func apply(_ plan: SyncPlan, progress: (SyncProgress) -> Void = { _ in }) throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensong-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Prepass: resolve identities so the total amount of work is known before the first
        // transfer starts (otherwise the progress bar has no denominator).
        var jobs: [(asset: AudioAsset, ident: TrackIdentity, weight: Double)] = []
        let idents = try store.allIdentitiesByID()
        for asset in plan.toAdd {
            guard let ident = idents[asset.identityID] else { continue }
            jobs.append((asset, ident, max(SyncProgress.minTrackWeight, ident.durationSec)))
        }
        let totalSteps = jobs.count + plan.toRemove.count
        let totalWeight = jobs.reduce(0) { $0 + $1.weight }
            + Double(plan.toRemove.count) * SyncProgress.removeWeight + SyncProgress.finalizeWeight
        var doneWeight = 0.0
        var doneSteps = 0
        func report(_ label: String) {
            progress(SyncProgress(done: doneSteps, total: totalSteps,
                                  fraction: totalWeight > 0 ? min(1, doneWeight / totalWeight) : 0,
                                  label: label))
        }

        for (asset, ident, weight) in jobs {
            let relPath = DeviceRelativePath.backslashPath(for: ident)
            let master = URL(fileURLWithPath: asset.masterPath)
            let probe = try transcoder.probe.probe(master)
            let bitrate: Int
            let pushURL: URL
            if transcoder.needsTranscode(probe, settings) {
                report("Transcoding \(ident.title) → MP3 \(settings.bitrateKbps)k")
                let tmp = scratch.appendingPathComponent("\(UUID().uuidString).mp3")
                try transcoder.transcode(from: master, to: tmp, tags: ident, settings: settings)
                pushURL = tmp
                bitrate = settings.bitrateKbps
            } else {
                report("Copying \(ident.title)")
                bitrate = probe.bitrateKbps
                // Straight copies still get their cover art normalized — the player only renders
                // baseline 4:2:0 JPEG front covers, and a master's own art often isn't that.
                if settings.embedArtwork, transcoder.hasArtwork(master) {
                    let tmp = scratch.appendingPathComponent("\(UUID().uuidString).mp3")
                    try transcoder.copyNormalizingArtwork(from: master, to: tmp, tags: ident,
                                                          settings: settings)
                    pushURL = tmp
                } else {
                    pushURL = master
                }
            }
            try device.write(assetFile: pushURL, to: ident)
            let dest = DeviceRelativePath.fileURL(under: device.volume.musicDir, for: ident)
            var size: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let s = attrs[.size] as? Int { size = Int64(s) }
            try store.setDeviceTrack(DeviceTrackRow(deviceUUID: deviceUUID, relativePath: relPath,
                assetID: asset.id ?? 0, transcodedBitrate: bitrate,
                contentHash: asset.contentHash, sizeBytes: size, recipe: settings.deviceRecipe))
            doneWeight += weight; doneSteps += 1
            report("Copied \(ident.title)")
        }

        for rel in plan.toRemove {
            report("Removing \(rel)")
            try device.remove(relative: rel)
            try store.deleteDeviceTrack(deviceUUID, relativePath: rel)
            doneWeight += SyncProgress.removeWeight; doneSteps += 1
        }

        report("Writing playlists…")
        // (Re)write device playlists in the exact device byte format.
        var written: [String] = []
        for pl in try store.devicePlaylists() {
            guard let pid = pl.id else { continue }
            let assets = try store.playlistItems(pid)
            var entries: [(identity: TrackIdentity, durationSec: Int)] = []
            for a in assets {
                if let ident = idents[a.identityID] {
                    entries.append((ident, Int(ident.durationSec.rounded())))
                }
            }
            try device.writePlaylist(name: pl.name, data: M3U8Writer.data(entries: entries))
            written.append(pl.name)
        }
        // Drop `.m3u8` files this app wrote on an earlier sync and no longer wants — a playlist
        // that was renamed, deleted, or unticked for the device. Only ones OpenSong wrote are
        // eligible (see the manifest), so playlists made on the device are left alone.
        for stale in device.writtenPlaylistNames() where !written.contains(stale) {
            try? device.removePlaylist(name: stale)
        }
        device.setWrittenPlaylistNames(written)
        doneWeight += SyncProgress.finalizeWeight
        report("Done.")
    }
}
