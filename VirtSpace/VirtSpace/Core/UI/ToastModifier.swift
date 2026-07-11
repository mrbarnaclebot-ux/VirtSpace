//
//  ToastModifier.swift
//  VirtSpace
//
//  One reusable error/notice surface for every network action (Stage A
//  requirement: failures are always visible, never silently swallowed).
//  Usage: `.toast($toast)` + `toast = Toast(error)` or `Toast(message:)`.
//

import SwiftUI

struct Toast: Equatable, Identifiable {
    enum Style {
        case error
        case success
        case info
    }

    let id = UUID()
    var message: String
    var style: Style = .error

    init(message: String, style: Style = .info) {
        self.message = message
        self.style = style
    }

    init(_ error: Error) {
        self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.style = .error
    }

    var systemImage: String {
        switch style {
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch style {
        case .error: return .red
        case .success: return .green
        case .info: return .blue
        }
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack(spacing: 10) {
                        Image(systemName: toast.systemImage)
                            .foregroundStyle(toast.tint)
                        Text(toast.message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(toast.tint.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { self.toast = nil }
                    .task(id: toast.id) {
                        // Auto-dismiss after 4 seconds.
                        try? await Task.sleep(for: .seconds(4))
                        if self.toast?.id == toast.id {
                            self.toast = nil
                        }
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: toast)
    }
}

extension View {
    /// Presents a small auto-dismissing toast anchored to the bottom.
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
