import Foundation

/// The diff between the desired device set and what's currently on the device.
public struct SyncPlan: Sendable {
    public var toAdd: [AudioAsset]
    public var toRemove: [String]        // backslash relative paths
    public var upToDate: [AudioAsset]
    public var projectedUsedBytes: Int64
    public var totalBytes: Int64
    public var freeBytes: Int64
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
    public func desiredAssets() throws -> [AudioAsset] {
        var byID: [Int64: AudioAsset] = [:]
        for a in try store.pinnedAssets() { if let id = a.id { byID[id] = a } }
        for pl in try store.devicePlaylists() {
            guard let pid = pl.id else { continue }
            for a in try store.playlistItems(pid) { if let id = a.id { byID[id] = a } }
        }
        return byID.values.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    private func estimatedDeviceSize(_ asset: AudioAsset, _ ident: TrackIdentity) -> Int64 {
        // If it will be transcoded, estimate from target bitrate × duration; else the master size.
        let probeLike = ProbeResult(durationSec: ident.durationSec, bitrateKbps: asset.bitrateKbps,
                                    codec: asset.format, sampleRate: asset.sampleRate,
                                    channels: 2, tags: [:])
        if transcoder.needsTranscode(probeLike, settings) {
            return Int64(Double(settings.bitrateKbps) * 1000.0 / 8.0 * ident.durationSec)
        }
        return asset.sizeBytes
    }

    public func plan() throws -> SyncPlan {
        let desired = try desiredAssets()
        let managed = try store.deviceTracks(deviceUUID)
        let managedByPath = Dictionary(managed.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        let actualPaths = Set(try device.listManagedTracks())
        let (total, free) = try device.volume.capacity()
        let usedNow = total - free

        var toAdd: [AudioAsset] = []
        var upToDate: [AudioAsset] = []
        var desiredPaths = Set<String>()
        var addBytes: Int64 = 0

        for asset in desired {
            guard let ident = try store.identity(asset.identityID) else { continue }
            let relPath = DeviceRelativePath.backslashPath(for: ident)
            desiredPaths.insert(relPath)
            let present = actualPaths.contains(relPath)
            let tracked = managedByPath[relPath]
            if present, let tracked, tracked.assetID == asset.id, tracked.contentHash == asset.contentHash {
                upToDate.append(asset)
            } else {
                toAdd.append(asset)
                addBytes += estimatedDeviceSize(asset, ident)
            }
        }

        // Remove only managed tracks that are no longer desired (foreign files untouched).
        var toRemove: [String] = []
        var removeBytes: Int64 = 0
        for row in managed where !desiredPaths.contains(row.relativePath) {
            toRemove.append(row.relativePath)
            removeBytes += row.sizeBytes
        }

        let projectedUsed = max(0, usedNow + addBytes - removeBytes)
        return SyncPlan(toAdd: toAdd, toRemove: toRemove, upToDate: upToDate,
                        projectedUsedBytes: projectedUsed, totalBytes: total, freeBytes: free)
    }

    /// Execute the plan: transcode/copy additions, remove stale managed tracks, rewrite playlists.
    public func apply(_ plan: SyncPlan, progress: (String) -> Void = { _ in }) throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensong-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for asset in plan.toAdd {
            guard let ident = try store.identity(asset.identityID) else { continue }
            let relPath = DeviceRelativePath.backslashPath(for: ident)
            let master = URL(fileURLWithPath: asset.masterPath)
            let probe = try transcoder.probe.probe(master)
            let bitrate: Int
            let pushURL: URL
            if transcoder.needsTranscode(probe, settings) {
                progress("Transcoding \(ident.title) → MP3 \(settings.bitrateKbps)k")
                let tmp = scratch.appendingPathComponent("\(UUID().uuidString).mp3")
                try transcoder.transcode(from: master, to: tmp, tags: ident, settings: settings)
                pushURL = tmp
                bitrate = settings.bitrateKbps
            } else {
                progress("Copying \(ident.title)")
                pushURL = master
                bitrate = probe.bitrateKbps
            }
            try device.write(assetFile: pushURL, to: ident)
            let dest = DeviceRelativePath.fileURL(under: device.volume.musicDir, for: ident)
            var size: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let s = attrs[.size] as? Int { size = Int64(s) }
            try store.setDeviceTrack(DeviceTrackRow(deviceUUID: deviceUUID, relativePath: relPath,
                assetID: asset.id ?? 0, transcodedBitrate: bitrate,
                contentHash: asset.contentHash, sizeBytes: size))
        }

        for rel in plan.toRemove {
            progress("Removing \(rel)")
            try device.remove(relative: rel)
            try store.deleteDeviceTrack(deviceUUID, relativePath: rel)
        }

        // (Re)write device playlists in the exact device byte format.
        for pl in try store.devicePlaylists() {
            guard let pid = pl.id else { continue }
            let assets = try store.playlistItems(pid)
            var entries: [(identity: TrackIdentity, durationSec: Int)] = []
            for a in assets {
                if let ident = try store.identity(a.identityID) {
                    entries.append((ident, Int(ident.durationSec.rounded())))
                }
            }
            try device.writePlaylist(name: pl.name, data: M3U8Writer.data(entries: entries))
        }
    }
}
