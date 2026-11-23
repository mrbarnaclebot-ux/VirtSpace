//
//  RoomScanHUDView.swift
//  VirtSpace
//
//  The room-scan HUD (spec §5.3): elapsed time and photo count, one coaching
//  line (tracking, "Slow down", limits), the suggested two-minute minimum and
//  Finish. No coverage map yet. Layout only: RoomScanEngine drives `hud`.
//

import SwiftUI

struct RoomScanHUDView: View {
    let hud: RoomScanHUD
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}

    /// Shorter scans are allowed but confirmed: they tend to leave gaps.
    static let suggestedMinimum: TimeInterval = 120

    @State private var showStopDialog = false
    @State private var showShortDialog = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = hud.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: Theme.Space.s) {
                topBar(elapsed: elapsed)
                if let hint = hud.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Theme.warning.opacity(0.85), in: Capsule())
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Spacer()
                bottom(elapsed: elapsed)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .animation(Theme.Motion.standard, value: hud.hint)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .confirmationDialog("Stop scanning?", isPresented: $showStopDialog, titleVisibility: .visible) {
            Button("Stop and delete", role: .destructive, action: onCancel)
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The \(hud.frameCount) photos taken so far will be deleted.")
        }
        .confirmationDialog("Finish this scan?", isPresented: $showShortDialog, titleVisibility: .visible) {
            Button("Finish", action: onFinish)
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("Short scans can leave gaps. Two minutes or more works best.")
        }
    }

    private func topBar(elapsed: TimeInterval) -> some View {
        HStack {
            Button {
                showStopDialog = true
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Theme.minTarget, height: Theme.minTarget)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop scan")
            Spacer()
            HStack(spacing: Theme.Space.xs) {
                Text(Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond)))
                Text("·").foregroundStyle(.white.opacity(0.6))
                Text("\(hud.frameCount) photos")
                    .contentTransition(.numericText())
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.minTarget)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .combine)
            Spacer()
            Color.clear.frame(width: Theme.minTarget, height: Theme.minTarget)
        }
    }

    private func bottom(elapsed: TimeInterval) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(elapsed < Self.suggestedMinimum
                 ? "Walk slowly. Point at every wall, the floor and the ceiling. Scan for at least 2 minutes."
                 : "Finish when you've covered the whole room.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(Theme.Space.s)
                .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            Button {
                if elapsed < Self.suggestedMinimum { showShortDialog = true } else { onFinish() }
            } label: {
                Text("Finish")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(hud.frameCount > 0 ? Theme.onAccent : Theme.textSecondary)
                    .background(hud.frameCount > 0 ? Theme.accent : Theme.surfaceInset, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(hud.frameCount == 0)
            .accessibilityHint("Stops the scan and uploads it.")
        }
    }
}
