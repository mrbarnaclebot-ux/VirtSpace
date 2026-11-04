//
//  ExplorerSplatTests.swift
//  VirtSpaceTests
//
//  Which splat tier the explorer loads: full_res only on 8 GB+ devices, and
//  the tier tag that keeps the two tiers apart in SplatCache.
//

import Testing
@testable import VirtSpace

@Suite("Explorer splat tier")
struct ExplorerSplatTests {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let both = WorldAssets(spz500kURL: "https://r2/500k", spzFullURL: "https://r2/full")

    @Test("12 GB device loads full_res")
    func fullOnPro() {
        let choice = WorldAssets.explorerSplat(assets: both, physicalMemory: 12 * gib)
        #expect(choice?.url == "https://r2/full")
        #expect(choice?.tier == "full")
    }

    @Test("4 GB device stays on 500k")
    func k500OnSmallDevice() {
        let choice = WorldAssets.explorerSplat(assets: both, physicalMemory: 4 * gib)
        #expect(choice?.url == "https://r2/500k")
        #expect(choice?.tier == "500k")
    }

    @Test("500k when the world has no full_res")
    func k500WhenFullMissing() {
        let assets = WorldAssets(spz500kURL: "https://r2/500k", spzFullURL: nil)
        let choice = WorldAssets.explorerSplat(assets: assets, physicalMemory: 12 * gib)
        #expect(choice?.url == "https://r2/500k")
        #expect(choice?.tier == "500k")
    }
}
