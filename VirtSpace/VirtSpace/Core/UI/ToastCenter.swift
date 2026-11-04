//
//  ToastCenter.swift
//  VirtSpace
//
//  The one toast (ui-spec 7.1). App-scoped and in the environment:
//
//    @Environment(ToastCenter.self) private var toasts
//    toasts.show("Space deleted.", style: .success)
//    toasts.show(error)                                  // APIError copy
//    toasts.show("Couldn't save to Photos.", style: .error,
//                action: Toast.Action("Open Settings") { openSettings() })
//
//  Rules: one at a time (a new toast replaces the current one); an identical
//  message within 2 s is dropped; info/success 3 s, error 5 s, with an action
//  6 s, never under 10 s while VoiceOver runs (and announced). Rendered in a
//  passthrough window (ToastWindow) so it shows over sheets and covers and
//  survives tab switches. Toasts are for transient outcomes only (7.2).
//

import SwiftUI
import UIKit

struct Toast: Identifiable {
    enum Style { case info, success, error }

    /// One trailing button. Tapping it runs `handler` and dismisses.
    struct Action {
        let title: String
        let handler: () -> Void

        init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    let id = UUID()
    let message: String
    let style: Style
    let action: Action?
}

@Observable
final class ToastCenter {
    /// The toast on screen, if any.
    private(set) var current: Toast?

    @ObservationIgnored private var lastShown: (message: String, at: Date)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isVoiceOverRunning: () -> Bool

    init(
        now: @escaping () -> Date = Date.init,
        isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning }
    ) {
        self.now = now
        self.isVoiceOverRunning = isVoiceOverRunning
    }

    func show(_ message: String, style: Toast.Style = .info, action: Toast.Action? = nil) {
        let date = now()
        if let last = lastShown, last.message == message, date.timeIntervalSince(last.at) < 2 { return }
        lastShown = (message, date)
        let toast = Toast(message: message, style: style, action: action)
        current = toast
        let voiceOver = isVoiceOverRunning()
        if voiceOver { AccessibilityNotification.Announcement(message).post() }
        scheduleDismiss(toast.id, after: Self.duration(style: style, hasAction: action != nil, voiceOver: voiceOver))
    }

    /// An error toast with the error's user copy (`APIError.errorDescription`).
    func show(_ error: Error, action: Toast.Action? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        show(message, style: .error, action: action)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    static func duration(style: Toast.Style, hasAction: Bool, voiceOver: Bool) -> Duration {
        let seconds = hasAction ? 6 : (style == .error ? 5 : 3)
        return .seconds(voiceOver ? max(seconds, 10) : seconds)
    }

    private func scheduleDismiss(_ id: UUID, after duration: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
        }
    }
}

// MARK: - Window

/// Installs the toast host in its own passthrough window above the app's, so
/// toasts stay visible over sheets and full-screen covers. Call once at launch.
enum ToastWindow {
    private static var window: PassthroughWindow?

    // ponytail: first connected scene only; per-scene windows if iPad multi-window ships.
    static func install(_ center: ToastCenter) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.toasts = center
        let host = UIHostingController(rootView: ToastHost(center: center) { [weak window] frame in
            window?.toastFrame = frame
        })
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.isHidden = false
        self.window = window
    }
}

/// Takes touches only on the visible toast; everything else falls through to
/// the app window below.
private final class PassthroughWindow: UIWindow {
    weak var toasts: ToastCenter?
    var toastFrame: CGRect = .null

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        toasts?.current != nil && toastFrame.contains(point)
    }
}

// MARK: - View

/// Top-anchored glass capsule under the Dynamic Island: symbol, at most 2
/// lines, optional action. Tap or swipe up dismisses.
private struct ToastHost: View {
    let center: ToastCenter
    let onFrameChange: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastView(toast: toast, dismiss: center.dismiss)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Theme.Space.m)
        .animation(center.current == nil ? Theme.Motion.exit : Theme.Motion.quick, value: center.current?.id)
        .sensoryFeedback(trigger: center.current?.id) { _, new in
            guard new != nil else { return nil }
            switch center.current?.style {
            case .success: return .success
            case .error: return .error
            default: return nil
            }
        }
    }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = toast.action {
                Button(action.title) {
                    action.handler()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
                .frame(minHeight: Theme.minTarget)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: Theme.minTarget)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: dismiss)
        .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < 0 { dismiss() } })
        .accessibilityAction(named: "Dismiss", dismiss)
    }

    private var symbol: String {
        switch toast.style {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tone: Tone {
        switch toast.style {
        case .error: .danger
        case .success: .success
        case .info: .progress
        }
    }
}
