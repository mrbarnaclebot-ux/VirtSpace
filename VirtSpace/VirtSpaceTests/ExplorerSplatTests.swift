//
//  ExplorerSplatTests.swift
//  VirtSpaceTests
//
//  Which splat tier the explorer loads: 500k by default, full_res only when
//  opted in on 8 GB+ devices, and
//  the tier tag that keeps the two tiers apart in SplatCache.
//

import Testing
@testable import VirtSpace

@Suite("Explorer splat tier")
struct ExplorerSplatTests {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let both = WorldAssets(spz500kURL: "https://r2/500k", spzFullURL: "https://r2/full")

    @Test("12 GB device without opt-in loads 500k")
    func k500ByDefault() {
        let choice = WorldAssets.explorerSplat(assets: both, maximumDetail: false, physicalMemory: 12 * gib)
        #expect(choice?.url == "https://r2/500k")
        #expect(choice?.tier == "500k")
    }

    @Test("12 GB device with opt-in loads full_res")
    func fullWhenOptedIn() {
        let choice = WorldAssets.explorerSplat(assets: both, maximumDetail: true, physicalMemory: 12 * gib)
        #expect(choice?.url == "https://r2/full")
        #expect(choice?.tier == "full")
    }

    @Test("4 GB device stays on 500k even when opted in")
    func k500OnSmallDevice() {
        let choice = WorldAssets.explorerSplat(assets: both, maximumDetail: true, physicalMemory: 4 * gib)
        #expect(choice?.url == "https://r2/500k")
        #expect(choice?.tier == "500k")
    }

    @Test("500k when opted in but the world has no full_res")
    func k500WhenFullMissing() {
        let assets = WorldAssets(spz500kURL: "https://r2/500k", spzFullURL: nil)
        let choice = WorldAssets.explorerSplat(assets: assets, maximumDetail: true, physicalMemory: 12 * gib)
        #expect(choice?.url == "https://r2/500k")
        #expect(choice?.tier == "500k")
    }
}
