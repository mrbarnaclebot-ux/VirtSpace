//
//  ExposureMeter.swift
//  VirtSpace
//
//  Pure exposure metering for the capture lock (spec §10 R34/R38).
//
//  AE used to be frozen at whatever target 0 happened to see, AFTER shot 0 was
//  saved: shot 0 was always stamped unlocked, and a window in shot 0 left the
//  whole room underexposed. Instead we sample ARKit's own continuous AE while
//  tracking initialises (the user is already looking around), and lock to the
//  median exposure of that window before target 0's dwell can complete.
//

import Foundation

/// One reading of the camera's auto-exposure, plus the active format's limits.
nonisolated struct ExposureSample: Sendable, Equatable {
    var iso: Float
    /// Seconds.
    var duration: Double
    var minISO: Float
    var maxISO: Float
    var minDuration: Double
    var maxDuration: Double
}

nonisolated struct ExposureMeter {
    /// ponytail: ~2 s of 60 Hz frames; a rolling window, so turning the lights
    /// on during the low-light warning clears it within a couple of seconds.
    static let windowSize = 120
    private(set) var samples: [ExposureSample] = []

    mutating func add(_ sample: ExposureSample) {
        samples.append(sample)
        if samples.count > Self.windowSize {
            samples.removeFirst(samples.count - Self.windowSize)
        }
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// The custom exposure to lock: the window's median exposure (ISO x
    /// shutter), reached at the CURRENT shutter so ARKit's frame timing is
    /// untouched; only ISO moves. Clamped to the format, so a scene beyond the
    /// ISO ceiling simply comes out darker than metered.
    var lockTarget: (iso: Float, duration: Double)? {
        guard let latest = samples.last, latest.duration > 0 else { return nil }
        let product = Self.median(samples.map { Double($0.iso) * $0.duration })
        let duration = min(max(latest.duration, latest.minDuration), latest.maxDuration)
        let iso = Float(product / duration)
        return (min(max(iso, latest.minISO), latest.maxISO), duration)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
