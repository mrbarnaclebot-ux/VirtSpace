//
//  TestEnvironment.swift
//  VirtSpace
//
//  Am I running inside a test?
//
//  The unit tests are HOSTED by the app, so `xcodebuild test` launches the real
//  app process in the simulator. Every launch-time kick the app does — upload
//  resume, stranded-world recovery, the background upload session — creates
//  REAL state: it mints worlds, uploads frames and spends the owner's daily
//  scan quota. That is exactly how a "read-only" simulator verification run
//  once put 28 test frames into the production library. A test run must
//  therefore start the app inert; the tests drive those flows directly with
//  fakes and a temp-directory store instead.
//

import Foundation

enum TestEnvironment {
    /// True when the process was launched by XCTest (hosted test bundle).
    /// XCTest sets `XCTestConfigurationFilePath` in the host's environment.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
