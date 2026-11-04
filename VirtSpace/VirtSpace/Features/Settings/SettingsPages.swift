//
//  SettingsPages.swift
//  VirtSpace
//
//  The small pages Settings pushes: Privacy, Acknowledgements, and the
//  placeholder for onboarding pages that WP3 provides.
//

import SwiftUI

/// Short privacy summary (ui-spec 8: no location claim; nothing reads it).
struct PrivacyPage: View {
    private let points = [
        "Your photos are uploaded to VirtSpace and to World Labs, which builds your 3D space.",
        "Your spaces are private to you.",
        "The original photos are deleted after processing.",
        "You can delete any space, or your data, at any time.",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(points, id: \.self) { point in
                    Label(point, systemImage: "checkmark.shield")
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .navigationTitle("Privacy")
    }
}

struct AcknowledgementsPage: View {
    var body: some View {
        Form {
            Section {
                Text("3D spaces are generated using World Labs.")
            }
            Section("Open source") {
                LabeledContent("Spark", value: "MIT License")
                LabeledContent("three.js", value: "MIT License")
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

/// Stands in for an onboarding page until WP3's view is wired in
/// (SettingsOnboardingLinks).
struct SettingsPlaceholderPage: View {
    let title: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "doc.text")
            .navigationTitle(title)
    }
}
