//
//  DebugLogView.swift
//  VirtSpace
//
//  In-app log viewer (Stage B3 deliverable 3b). Reads THIS app's own recent
//  entries back out of the unified log via OSLogStore(scope:
//  .currentProcessIdentifier) — so the owner can inspect logs on-device even
//  after unplugging from Xcode / on TestFlight. Filterable by level, newest
//  first, with a ShareLink that exports the visible entries as a text file.
//
//  Only reads entries from our own subsystem (AppLog.subsystem); never other
//  apps' or the system's logs.
//

import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct DebugLogView: View {
    @Environment(\.dismiss) private var dismiss

    /// Level filter. os_log has no "warning" level, so we map it to "notice and
    /// above" (state transitions + errors); "errors" is error+fault only.
    enum LevelFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case warnings = "Warnings+"
        case errors = "Errors"
        var id: String { rawValue }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let level: OSLogEntryLog.Level
        let message: String
    }

    @State private var entries: [Entry] = []
    @State private var filter: LevelFilter = .all
    @State private var isLoading = false
    @State private var loadError: String?

    private var filtered: [Entry] {
        entries.filter { passesFilter($0.level) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView("Reading logs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView("Couldn't read logs", systemImage: "doc.questionmark", description: Text(loadError))
                } else if filtered.isEmpty {
                    ContentUnavailableView("No log entries", systemImage: "text.magnifyingglass", description: Text("Nothing at this level yet. Run a capture or upload, then refresh."))
                } else {
                    logList
                }
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportURL(), preview: SharePreview("VirtSpace logs")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(filtered.isEmpty)
                }
                ToolbarItem(placement: .principal) {
                    Picker("Level", selection: $filter) {
                        ForEach(LevelFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
    }

    private var logList: some View {
        List(filtered) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: entry.level))
                        .frame(width: 8, height: 8)
                    Text(entry.category.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    // MARK: - Filtering

    private func passesFilter(_ level: OSLogEntryLog.Level) -> Bool {
        switch filter {
        case .all:
            return true
        case .warnings:
            return level == .notice || level == .error || level == .fault
        case .errors:
            return level == .error || level == .fault
        }
    }

    private func color(for level: OSLogEntryLog.Level) -> Color {
        switch level {
        case .fault, .error: return .red
        case .notice: return .orange
        default: return .secondary
        }
    }

    private func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "—"
        @unknown default: return "—"
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let subsystem = AppLog.subsystem
        // Reading the store is blocking work — do it off the main actor.
        let result: Result<[Entry], Error> = await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                // Look back a generous window; this process hasn't been up long.
                let since = store.position(date: Date().addingTimeInterval(-3600))
                let predicate = NSPredicate(format: "subsystem == %@", subsystem)
                let raw = try store.getEntries(at: since, matching: predicate)
                var collected: [Entry] = []
                for case let log as OSLogEntryLog in raw {
                    collected.append(Entry(
                        date: log.date,
                        category: log.category,
                        level: log.level,
                        message: log.composedMessage
                    ))
                }
                return .success(collected)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let collected):
            // Newest first.
            entries = collected.sorted { $0.date > $1.date }
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    // MARK: - Export

    /// Write the currently-visible entries to a temp .txt file for ShareLink.
    private func exportURL() -> URL {
        let lines = filtered.map { entry in
            let ts = entry.date.formatted(.iso8601)
            return "\(ts)  [\(levelName(entry.level))]  \(entry.category): \(entry.message)"
        }
        let text = "VirtSpace logs — \(Date().formatted())\nFilter: \(filter.rawValue)\n\n"
            + lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("virtspace-logs.txt")
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}

#Preview {
    DebugLogView()
}
