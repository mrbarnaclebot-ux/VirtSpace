//
//  SettingsPages.swift
//  VirtSpace
//
//  The small page Settings pushes itself: Acknowledgements. Privacy and
//  Terms are WP3's TermsOfUseView and TermsView.
//

import SwiftUI

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
