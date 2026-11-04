//
//  ToastCenterTests.swift
//  VirtSpaceTests
//
//  ui-spec 7.1 toast queue rules: one at a time, 2 s dedupe, durations.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("ToastCenter")
struct ToastCenterTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    private func center(_ clock: Clock) -> ToastCenter {
        ToastCenter(now: { clock.now }, isVoiceOverRunning: { false })
    }

    @Test("A new toast replaces the current one")
    func replaces() {
        let toasts = center(Clock())
        toasts.show("One")
        toasts.show("Two", style: .error)
        #expect(toasts.current?.message == "Two")
        #expect(toasts.current?.style == .error)
    }

    @Test("An identical message within 2 s is dropped")
    func dedupe() {
        let clock = Clock()
        let toasts = center(clock)
        toasts.show("Space deleted.")
        let first = toasts.current?.id
        clock.now += 1.5
        toasts.show("Space deleted.")
        #expect(toasts.current?.id == first)
        clock.now += 1
        toasts.show("Space deleted.")
        #expect(toasts.current?.id != first)
    }

    @Test("A different message within 2 s still shows")
    func differentMessageShows() {
        let toasts = center(Clock())
        toasts.show("One")
        toasts.show("Two")
        #expect(toasts.current?.message == "Two")
    }

    @Test("Errors show their user copy")
    func errorCopy() {
        let toasts = center(Clock())
        toasts.show(APIError.rateLimited)
        #expect(toasts.current?.message == "Too many tries. Wait a moment and try again.")
        #expect(toasts.current?.style == .error)
    }

    @Test("Durations: 3 s, 5 s for errors, 6 s with an action, 10 s under VoiceOver")
    func durations() {
        #expect(ToastCenter.duration(style: .info, hasAction: false, voiceOver: false) == .seconds(3))
        #expect(ToastCenter.duration(style: .success, hasAction: false, voiceOver: false) == .seconds(3))
        #expect(ToastCenter.duration(style: .error, hasAction: false, voiceOver: false) == .seconds(5))
        #expect(ToastCenter.duration(style: .info, hasAction: true, voiceOver: false) == .seconds(6))
        #expect(ToastCenter.duration(style: .error, hasAction: true, voiceOver: true) == .seconds(10))
    }

    @Test("dismiss clears the toast")
    func dismiss() {
        let toasts = center(Clock())
        toasts.show("One", action: Toast.Action("Undo") {})
        toasts.dismiss()
        #expect(toasts.current == nil)
    }
}
