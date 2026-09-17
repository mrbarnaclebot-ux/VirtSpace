//
//  ViewerSchemeHandlerTests.swift
//  VirtSpaceTests
//
//  Spark loads a world by issuing Range requests against
//  `virtspace-viewer://assets/world.spz`. A range parsed wrong serves the wrong
//  bytes and the world renders as garbage (or not at all), so the parser is
//  pinned here (spec §10 R13).
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Viewer range parsing")
struct ViewerSchemeHandlerTests {
    @Test("A closed range is half-open and inclusive of `end`")
    func closedRange() {
        #expect(ViewerSchemeHandler.parseRange("bytes=0-99", total: 1000) == 0..<100)
        #expect(ViewerSchemeHandler.parseRange("bytes=10-10", total: 1000) == 10..<11)
        #expect(ViewerSchemeHandler.parseRange("bytes=500-999", total: 1000) == 500..<1000)
    }

    @Test("An open-ended range runs to the end of the file")
    func openEnded() {
        #expect(ViewerSchemeHandler.parseRange("bytes=100-", total: 1000) == 100..<1000)
        #expect(ViewerSchemeHandler.parseRange("bytes=0-", total: 1) == 0..<1)
    }

    @Test("An end past the file is clamped")
    func clamped() {
        #expect(ViewerSchemeHandler.parseRange("bytes=900-5000", total: 1000) == 900..<1000)
    }

    @Test("Malformed, empty and unsupported ranges are rejected")
    func rejected() {
        #expect(ViewerSchemeHandler.parseRange("bytes=0-99", total: 0) == nil)
        #expect(ViewerSchemeHandler.parseRange("items=0-99", total: 1000) == nil)
        #expect(ViewerSchemeHandler.parseRange("bytes=0-10,20-30", total: 1000) == nil)   // multi-range
        #expect(ViewerSchemeHandler.parseRange("bytes=1000-1001", total: 1000) == nil)    // starts past EOF
        #expect(ViewerSchemeHandler.parseRange("bytes=", total: 1000) == nil)
        #expect(ViewerSchemeHandler.parseRange("bytes=abc", total: 1000) == nil)
    }
}
