//
//  ImproveQualitySheet.swift
//  VirtSpace
//
//  The cost confirmation before a quality upgrade (ui-spec 7.5): used for
//  Improve quality on a ready space and for Try again on a failed upgrade,
//  which can bill again. The request runs while the sheet shows a busy
//  button; the sheet closes once the server answered.
//

import SwiftUI

struct ImproveQualitySheet: View {
    /// Runs the POST and applies its answer. The sheet closes when it returns.
    let confirm: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Improve quality")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Builds a sharper, more detailed version of this space.")
                Text("Takes about 5 to 10 minutes. You can keep exploring meanwhile.")
                Text("Limited to one space a day for now.")
            }
            .font(.body)
            .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            buttons
        }
        .padding(Theme.Space.l)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { primary; cancel }
            VStack(spacing: Theme.Space.s) { primary; cancel }
        }
    }

    private var primary: some View {
        Button {
            Task {
                isWorking = true
                await confirm()
                isWorking = false
                dismiss()
            }
        } label: {
            BusyLabel(title: "Improve quality", busyTitle: "Improve quality", isBusy: isWorking)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
    }

    private var cancel: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isWorking)
    }
}
