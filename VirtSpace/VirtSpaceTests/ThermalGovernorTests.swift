//
//  ThermalGovernorTests.swift
//  VirtSpaceTests
//
//  The thermal governor's pure state→policy mapping (spec §10 R13, R14). The
//  simulator can never raise a real `ProcessInfo.thermalState`, so this mapping
//  being side-effect free is the only way the cool-down policy is checkable at
//  all. Moved here from CaptureMathTests when the governor was extracted out of
//  CaptureEngine.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Thermal governor mapping")
struct ThermalMappingTests {
    @Test("Preview frame rate drops under thermal pressure")
    func frameRate() {
        #expect(ThermalGovernor.previewFrameRate(for: .nominal) == 30)
        #expect(ThermalGovernor.previewFrameRate(for: .fair) == 30)
        #expect(ThermalGovernor.previewFrameRate(for: .serious) == 24)
        #expect(ThermalGovernor.previewFrameRate(for: .critical) == 24)
    }

    @Test("Only `serious` shows the warming banner; `critical` pauses")
    func banners() {
        #expect(!ThermalGovernor.showsWarmingBanner(for: .nominal))
        #expect(!ThermalGovernor.showsWarmingBanner(for: .fair))
        #expect(ThermalGovernor.showsWarmingBanner(for: .serious))
        #expect(!ThermalGovernor.showsWarmingBanner(for: .critical))
        #expect(!ThermalGovernor.pausesSession(for: .serious))
        #expect(ThermalGovernor.pausesSession(for: .critical))
    }

    @Test("Every state has a log name")
    func names() {
        #expect(ThermalGovernor.name(.nominal) == "nominal")
        #expect(ThermalGovernor.name(.fair) == "fair")
        #expect(ThermalGovernor.name(.serious) == "serious")
        #expect(ThermalGovernor.name(.critical) == "critical")
    }
}
