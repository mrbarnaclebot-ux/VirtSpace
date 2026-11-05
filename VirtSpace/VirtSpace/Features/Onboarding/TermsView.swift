//
//  TermsView.swift
//  VirtSpace
//
//  Onboarding page 5, Terms + consent (ui-spec 5; AGENTS.md 2: one short
//  terms page and one consent prompt, nothing more). Not skippable: the only
//  way out is "Agree and continue".
//
//  Settings (WP5) embeds it read-only, without the agree button:
//    NavigationLink("Terms of use") { TermsView() }
//  and can show the full text on its own:
//    NavigationLink("Privacy") { TermsOfUseView() }
//
//  The full text is DRAFT copy for the owner to review. Bump
//  `OnboardingStore.currentTermsVersion` when it changes in substance.
//

import SwiftUI

struct TermsView: View {
    /// nil shows the page read-only (Settings).
    var onAgree: (() -> Void)?

    @State private var showsFullTerms = false

    private let points: [(symbol: String, text: String)] = [
        ("icloud.and.arrow.up", "Your photos are uploaded to VirtSpace and to World Labs, which builds your 3D space."),
        ("lock", "Your spaces are private to you."),
        ("photo", "The original photos are deleted after processing."),
        ("trash", "You can delete any space, or your data, at any time."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Before you scan")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(points, id: \.text) { point in
                        TermsPoint(symbol: point.symbol, text: point.text)
                    }
                }
                Button("Read the terms of use") { showsFullTerms = true }
                    .font(.body)
                    .tint(Theme.accent)
                    .frame(minHeight: Theme.minTarget)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if let onAgree {
                OnboardingButton(title: "Agree and continue", action: onAgree)
                    .padding(Theme.Space.m)
                    .background(Theme.bg)
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $showsFullTerms) {
            NavigationStack {
                TermsOfUseView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsFullTerms = false }
                        }
                    }
            }
        }
    }
}

private struct TermsPoint: View {
    let symbol: String
    let text: String

    /// One fixed icon column so every line of text starts at the same edge.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Full terms (DRAFT for owner review)

/// The full terms of use and privacy summary, plain language.
struct TermsOfUseView: View {
    private let sections: [(title: String, body: String)] = [
        ("The short version",
         "VirtSpace is a hobby app shared with friends. It is offered as is: it may have bugs, change, or stop working, and there is no guarantee it keeps your spaces forever. By tapping Agree and continue you accept these terms."),
        ("What the app collects",
         "Only while you scan: photos of the room, depth data (how far surfaces are from the camera) and the position and direction of the phone for each photo. The app does not use your location, contacts or microphone."),
        ("Where it goes",
         "Your scan is uploaded to the VirtSpace server. The server sends the photos to World Labs, a company that builds the 3D space from them, under its own terms. Nobody else gets your scans."),
        ("Your spaces are private",
         "Only you can see your spaces. We never sell your data, show ads, or share your spaces with anyone."),
        ("Keeping and deleting",
         "The original photos are deleted from our server after processing. The finished 3D space and its 360° photo stay until you delete them. Delete any space from its page in the Library. To have all your data removed, ask the person who shared the app with you."),
        ("Be considerate",
         "Only scan places you are allowed to, and do not scan people without their permission."),
        ("Changes",
         "If these terms change, the app asks you to agree again before your next upload."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(section.body)
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
        .background(Theme.bg)
        .navigationTitle("Terms of use")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    TermsView(onAgree: {})
}
