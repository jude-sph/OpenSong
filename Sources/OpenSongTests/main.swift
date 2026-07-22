// Test runner entry point. Registers every area's tests, then runs them all.
// Run: `swift run OpenSongTests`   (set OPENSONG_LIVE=1 to include live-network tests)
//
// Registration calls are added here as each task lands (keeps the build green
// incrementally). See docs/superpowers/plans/2026-07-22-opensong-phase1.md.

// Smoke test proving the harness works.
t.test("harness works") {
    try t.expectEqual(1 + 1, 2, "math")
}

registerPathSanitizerTests()
registerModelsTests()
registerDeviceRelativePathTests()
registerM3U8WriterTests()
registerM3U8ParserTests()
registerShellTests()
registerAudioProbeTests()
registerTranscoderTests()
registerLibraryStoreTests()
registerMetadataResolverTests()
registerArtworkResolverTests()

t.runAll()
