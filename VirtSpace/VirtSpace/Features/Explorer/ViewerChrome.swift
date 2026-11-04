//
//  ViewerChrome.swift
//  VirtSpace
//
//  Controls shared by the two full-screen viewers (Explore in 3D, 360° photo):
//  44 pt glass icon buttons, a Reduce Motion aware spinner, and the error
//  state. Glass is right here: these float over the 3D view or the photo
//  (ui-spec 1, "custom glass in one place").
//

import SwiftUI

/// A 44 pt circular glass button with a VoiceOver label.
struct ViewerIconButton: View {
    let systemName: String
    let label: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ViewerSpinner()
                } else {
                    Image(systemName: systemName)
                        .font(.headline)
                }
            }
            .frame(width: Theme.minTarget, height: Theme.minTarget)
            .contentShape(.circle)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// The one indeterminate indicator. Under Reduce Motion it is a static
/// symbol (no repeating animation); the caller's text says what is happening.
struct ViewerSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: "hourglass")
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
        } else {
            ProgressView()
        }
    }
}

/// Title, optional cause and one recovery button, on black so nothing from
/// the page shows through.
struct ViewerErrorView: View {
    let title: String
    let message: String?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(buttonTitle, systemImage: "arrow.clockwise", action: action)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Theme.accent)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
