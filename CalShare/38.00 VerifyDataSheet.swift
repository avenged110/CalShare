// MARK: - VerifyDataSheet.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The sheet behind Backups' "Verify Data…": reads every calendar and address book the way a
// device does and shows, per collection, whether what devices get matches what's stored.
// It starts checking as soon as it opens; nothing is changed.

import CalShareCore
import SwiftUI

struct VerifyDataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report: VerificationReport?
    @State private var failure: String?
    /// True from the first draw, since checking starts as the sheet opens: nothing claims a
    /// result before there is one.
    @State private var running = true

    var body: some View {
        SheetChrome("Verify Data", height: nil) {
            VStack(alignment: .leading, spacing: 12) {
                summary
                PageScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let report {
                            ForEach(report.results) { result in
                                ResultRow(result: result)
                                // Nothing below the last row to divide it from.
                                if result.id != report.results.last?.id { Divider() }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
                .overlay {
                    if !running, let failure {
                        Text(failure).foregroundStyle(.secondary)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            .padding(20)
        } gutter: {
            HStack {
                GutterButton("Verify Again") { run() }
                    .disabled(running)
                Spacer()
                GutterButton("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { run() }
    }

    /// The badge (or, while checking, a spinner) and a line or two of text. Its space is
    /// reserved at the tallest message's height, so the sheet keeps its size whatever it says.
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                ProgressView().controlSize(.small).opacity(running ? 1 : 0)
                summaryBadge.opacity(running ? 0 : 1)
            }
            .frame(width: 16, height: 16)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 16 * 0.3 }
            ZStack(alignment: .topLeading) {
                // Two lines' worth, whatever is shown.
                Text("\n").hidden()
                summaryText
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The table rows' inset, so badges and text line up with theirs.
        .padding(.horizontal, 8)
        .transaction(value: running) { transaction in
            transaction.disablesAnimations = false
            transaction.animation = .easeInOut(duration: 0.2)
        }
    }

    @ViewBuilder private var summaryBadge: some View {
        if let report, report.isClean {
            StatusBadge(glyph: "checkmark", color: .accentColor)
        } else if report != nil {
            StatusBadge(.warning)
        } else if failure != nil {
            StatusBadge(.error)
        }
    }

    @ViewBuilder private var summaryText: some View {
        if running {
            Text("Reading every calendar and address book the way a device does…")
        } else if let report {
            let items = "\(report.itemCount) item\(report.itemCount == 1 ? "" : "s") in \(report.results.count) collection\(report.results.count == 1 ? "" : "s")"
            if report.isClean {
                Text("Everything checks out: \(items), each listed, synced, and fetched exactly as stored.")
            } else {
                Text("Found \(report.problemCount) problem\(report.problemCount == 1 ? "" : "s") in \(items).")
            }
        } else {
            Text("Verify Data couldn't finish.")
        }
    }

    private func run() {
        running = true
        failure = nil
        // Cleared for the pass, so nothing stale shows while it runs.
        report = nil
        model.verifyData { result in
            running = false
            switch result {
            case .success(let fresh): report = fresh
            case .failure(let error): report = nil; failure = "\(error)"
            }
        }
    }
}

/// One collection: its name and counts, and any problems beneath.
private struct ResultRow: View {
    let result: VerificationReport.CollectionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if result.isClean {
                    StatusBadge(glyph: "checkmark", color: .accentColor)
                } else {
                    StatusBadge(.warning)
                }
                Text(result.name).lineLimit(1)
                Text(result.isRemindersList ? "Reminders list" : result.kind == .calendar ? "Calendar" : "Address book").foregroundStyle(.tertiary)
                Spacer()
                Text("\(result.stored) item\(result.stored == 1 ? "" : "s")").monospacedDigit().foregroundStyle(.secondary)
            }
            // The first few, by position: a systematic fault can produce thousands of lines,
            // and two can read alike.
            ForEach(Array(result.problems.prefix(Self.shownProblems).enumerated()), id: \.offset) { _, problem in
                problemText(problem)
            }
            if result.problems.count > Self.shownProblems {
                problemText("…and \(result.problems.count - Self.shownProblems) more.")
            }
        }
        .padding(.vertical, 6)
    }

    static let shownProblems = 50

    private func problemText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 24)
    }
}
