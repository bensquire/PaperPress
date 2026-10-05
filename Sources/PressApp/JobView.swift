import PressJobs
import PressKit
import SwiftUI

/// One queued batch: where it is, what it wrote, and what can be done about
/// it. An assistant's batch waiting for approval shows the review table, to
/// untick files before letting it run.
struct JobView: View {
    @EnvironmentObject var model: AppModel
    let job: Job
    @State private var selectedRow: FileRow.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if job.state == .converting {
                ProgressView(value: job.fraction)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            if job.state == .awaitingApproval {
                ReviewTable(
                    rows: job.files, selection: $selectedRow,
                    setIncluded: { included, id in
                        model.setIncluded(included, file: id, in: job.id)
                    })
            } else {
                resultsTable
            }
            StatusBar(
                text: job.state == .converting
                    ? "Writing to \(job.request.output.path)" : job.request.output.path,
                error: job.failure ?? failedText,
                busy: job.state == .analysing || job.state == .converting,
                trailing: "\(job.writing.count) of \(job.files.count) PDFs to write"
            )
        }
    }

    private var failedText: String? {
        let failed = job.totals.failed
        return failed > 0 ? "\(failed) file\(failed == 1 ? "" : "s") failed" : nil
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(job.state))
                .font(.title2)
                .foregroundStyle(Self.tint(job.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(job.request.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(Self.stateWords(job))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            ForEach(JobAction.available(for: job), id: \.self) { action in
                actionButton(action)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func actionButton(_ action: JobAction) -> some View {
        let button = Button(role: Self.role(action)) {
            model.perform(action, on: job.id)
        } label: {
            switch action {
            case .approve: Label(action.title, systemImage: "checkmark")
            case .reveal: Label(action.title, systemImage: "folder")
            default: Text(action.title)
            }
        }
        .hoverHighlight()
        .disabled(!action.isEnabled(for: job))
        if action == .approve || action == .reveal {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    static func role(_ action: JobAction) -> ButtonRole? {
        switch action {
        case .reject: .destructive
        case .cancel: .cancel
        default: nil
        }
    }

    /// A job's state in a line: where it is, or what it came to.
    static func stateWords(_ job: Job) -> String {
        let total = job.writing.count
        switch job.state {
        case .analysing:
            return job.files.isEmpty ? "Analysing…" : "Analysing \(job.files.count) PDFs…"
        case .awaitingApproval:
            return "Waiting for approval · \(total) file\(total == 1 ? "" : "s") to write"
        case .queued:
            return "Waiting · \(total) file\(total == 1 ? "" : "s")"
        case .converting:
            return "Converting \(job.done) of \(total)"
        case .failed:
            return job.failure ?? "Failed"
        case .cancelled:
            return "Cancelled after \(job.done) of \(total)"
        case .finished:
            guard total > 0 else { return "Nothing worth re-compressing" }
            let totals = job.totals
            return "\(totals.converted) converted · "
                + "\(byteLabel(totals.inputBytes)) → \(byteLabel(totals.outputBytes))"
                + (totals.savedBytes > 0 ? " · saved \(byteLabel(totals.savedBytes))" : "")
        }
    }

    static func symbol(_ state: JobState) -> String {
        switch state {
        case .analysing: "magnifyingglass"
        case .awaitingApproval: "hand.raised"
        case .queued: "clock"
        case .converting: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    static func tint(_ state: JobState) -> Color {
        switch state {
        case .finished: .green
        case .failed: .red
        case .awaitingApproval: .orange
        case .converting: .accentColor
        case .analysing, .queued, .cancelled: .secondary
        }
    }

    // MARK: Results

    private var resultsTable: some View {
        // Rows and their preview URLs computed once per evaluation and
        // shared by the table and the Quick Look navigation.
        let rows = job.writing
        let previewURLs = rows.map { model.previewURL(for: $0, in: job) }
        return Table(rows, selection: $selectedRow) {
            TableColumn("File") { row in
                fileCell(row)
            }
            TableColumn("Before") { row in
                byteCell(row.report?.fileBytes)
            }
            .width(70)
            TableColumn("After") { row in
                byteCell(row.result?.outputBytes)
            }
            .width(70)
            TableColumn("Saved") { row in
                Text(row.savingFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(50)
            TableColumn("Outcome") { row in
                resultBadge(row)
            }
            .width(110)
        }
        // Space previews the selected row's OUTPUT once written — inspect
        // what the conversion did.
        .quickLookNavigation(
            ids: rows.map(\.id), urls: previewURLs, selection: $selectedRow
        )
    }

    private func resultBadge(_ row: FileRow) -> some View {
        let text: (label: String, help: String) =
            row.result == nil && !row.failed
            ? (job.state.isTerminal ? "Not written" : "Waiting", "")
            : row.resultText
        return capsuleBadge(
            text.label, help: text.help,
            error: row.failed,
            tint: row.result?.converted == true ? Color.green : nil
        )
    }
}
