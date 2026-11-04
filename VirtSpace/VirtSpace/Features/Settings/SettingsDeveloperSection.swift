//
//  SettingsDeveloperSection.swift
//  VirtSpace
//
//  DEBUG-only Settings section (ui-spec 8 "Developer"): the dev user id,
//  a synthetic 360° photo, the log viewer, and onboarding resets. Developer
//  wording is fine here.
//

#if DEBUG
import SwiftUI

struct SettingsDeveloperSection: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var fixture: Fixture?
    @State private var showLogs = false

    struct Fixture: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        Section {
            LabeledContent("User id") {
                Text(Secrets.devUserId)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Button("Preview fixture 360° photo", systemImage: "photo") { openFixture() }
                .fullScreenCover(item: $fixture) { PanoPreviewView(source: .file($0.url)) }
            Button("Debug logs", systemImage: "ladybug") { showLogs = true }
                .sheet(isPresented: $showLogs) { DebugLogView() }
            Button("Replay onboarding", systemImage: "arrow.counterclockwise") {
                SettingsOnboardingLinks.replayOnboarding()
                toasts.show("Onboarding shows again on next launch.", style: .success)
            }
            Button("Reset first-scan coaching", systemImage: "arrow.counterclockwise") {
                SettingsOnboardingLinks.resetFirstScanCoaching()
                toasts.show("Coaching reset.", style: .success)
            }
        } header: {
            Text("Developer")
        }
    }

    private func openFixture() {
        guard let url = Self.makeFixturePano() else {
            toasts.show("Couldn't render the fixture pano.", style: .error)
            return
        }
        fixture = Fixture(url: url)
    }

    /// A synthetic 2:1 equirectangular test image (color bands + a lat/long grid
    /// so orientation is obvious), written to a temp file. Zero bundle bloat.
    static func makeFixturePano() -> URL? {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Vertical sky→ground gradient.
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor, UIColor.brown.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Longitude/latitude grid every 30°.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            cg.setLineWidth(2)
            for lon in stride(from: 0.0, through: 360.0, by: 30.0) {
                let x = size.width * lon / 360
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height))
            }
            for lat in stride(from: 0.0, through: 180.0, by: 30.0) {
                let y = size.height * lat / 180
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
            }
            cg.strokePath()
            // A bright marker at yaw 0 so look-direction is unmistakable.
            UIColor.systemYellow.setFill()
            cg.fillEllipse(in: CGRect(x: size.width / 2 - 40, y: size.height / 2 - 40, width: 80, height: 80))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-pano.jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }
}
#endif
