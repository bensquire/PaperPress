import PressKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                dropState
            case let .analysing(done, of):
                progressState(
                    title: "Analysing PDFs…",
                    detail: of > 0 ? "\(done) of \(of)" : "Looking for PDFs",
                    done: done, of: of
                )
            case .review:
                reviewTable
                Divider()
                convertBar
            case let .converting(done, of):
                progressState(
                    title: "Converting…", detail: "\(done) of \(of)", done: done, of: of
                )
            case .done:
                doneState
            }
            statusBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: model.phase) { _ in
            // A phase change invalidates what the selection points at.
            // (Preview state lives inside QuickLookNavigation and is
            // discarded with each table.)
            selectedRow = nil
        }
    }

    // MARK: Centred states

    /// Shared skeleton for the drop / progress / done states: centred
    /// header + title + detail, sitting slightly above centre.
    private func centeredState<Header: View, Detail: View>(
        title: String,
        @ViewBuilder header: () -> Header,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(spacing: 18) {
            Spacer()
            header()
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            detail()
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drop handling

    @State private var dropHovering = false

    /// Gather every dropped URL, then hand them to the model in one call.
    /// FolderScanner owns the "what counts as a source" filtering.
    private func handleDrop(_ providers: [NSItemProvider], append: Bool) -> Bool {
        let candidates = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in candidates {
                let url = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                model.analyse(urls: urls, append: append)
            }
        }
        return true
    }

    // MARK: Idle / drop state

    private var dropState: some View {
        centeredState(title: "Drop scanned PDFs, or folders of them") {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tertiary)
        } detail: {
            Text("Every PDF inside is analysed — nothing is changed until you convert")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button {
                model.chooseSource()
            } label: {
                Label("Choose PDFs or Folder", systemImage: "folder")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .hoverHighlight()
            .keyboardShortcut(.defaultAction)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8]),
                    antialiased: true
                )
                .foregroundStyle(dropHovering ? Color.accentColor : Color(.separatorColor))
                .padding(16)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropHovering) { providers in
            handleDrop(providers, append: false)
        }
    }

    // MARK: Progress state

    private func progressState(
        title: String, detail: String, done: Int, of: Int
    ) -> some View {
        centeredState(title: title) {
            if of > 0 {
                ProgressView(value: Double(done), total: Double(of))
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
            }
        } detail: {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Button("Cancel", role: .cancel) { model.cancel() }
                .hoverHighlight()
        }
    }

    // MARK: Review table

    @State private var selectedRow: FileRow.ID?

    private var reviewTable: some View {
        Table(model.rows, selection: $selectedRow) {
            TableColumn("") { row in
                Toggle(
                    "",
                    isOn: Binding(
                        get: { row.included },
                        set: { value in
                            if let i = model.rows.firstIndex(where: { $0.id == row.id }) {
                                model.rows[i].included = value
                            }
                        }
                    )
                )
                .labelsHidden()
                .disabled(row.error != nil)
            }
            .width(24)
            TableColumn("File") { row in
                fileCell(row)
            }
            TableColumn("Pages") { row in
                Text(row.report.map { "\($0.pages.count)" } ?? "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(44)
            TableColumn("Size") { row in
                byteCell(row.report?.fileBytes)
            }
            .width(70)
            TableColumn("Verdict") { row in
                verdictBadge(row)
            }
            .width(110)
            TableColumn("Estimated") { row in
                Text(
                    row.isConvert
                        ? "~" + byteLabel(row.report?.estimatedBytes ?? 0)
                        : "unchanged"
                )
                .monospacedDigit()
                .foregroundStyle(row.isConvert ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers, append: true)
        }
        // Space previews the selected SOURCE file — inspect before ticking.
        .quickLookNavigation(
            ids: model.rows.map(\.id), urls: model.rows.map(\.item.url),
            selection: $selectedRow
        )
    }

    /// One capsule style for verdict and outcome badges.
    private func capsuleBadge(
        _ label: String, help: String, error: Bool, tint: Color?
    ) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    error
                        ? Color.red.opacity(0.15)
                        : tint.map { $0.opacity(0.18) }
                            ?? Color(.quaternaryLabelColor).opacity(0.5)
                )
            )
            .foregroundStyle(error ? Color.red : tint ?? Color.secondary)
            .help(help)
    }

    private func fileCell(_ row: FileRow) -> some View {
        Text(row.item.relativePath)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(row.item.relativePath)
    }

    private func byteCell(_ bytes: Int?) -> some View {
        Text(bytes.map(byteLabel) ?? "–")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func verdictBadge(_ row: FileRow) -> some View {
        capsuleBadge(
            row.verdictLabel, help: row.verdictHelp,
            error: row.error != nil,
            tint: row.isConvert ? Color.accentColor : nil
        )
    }

    // MARK: Convert bar

    private var convertBar: some View {
        HStack(spacing: 12) {
            let convertCount = model.includedRows.count
            Button("All") { model.setAllIncluded(true) }
                .controlSize(.small)
                .hoverHighlight()
            Button("None") { model.setAllIncluded(false) }
                .controlSize(.small)
                .hoverHighlight()
            Spacer()
            if convertCount > 0 {
                Text(
                    "\(convertCount) file\(convertCount == 1 ? "" : "s") · "
                        + "\(byteLabel(model.totalInputBytes)) → est. "
                        + byteLabel(model.totalEstimatedBytes)
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Button {
                model.chooseOutputAndConvert()
            } label: {
                Label("Convert…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            .hoverHighlight()
            .disabled(!model.canConvert)
            .keyboardShortcut(.defaultAction)
            Button("Discard", role: .destructive) { model.reset() }
                .hoverHighlight()
        }
        .padding(12)
    }

    // MARK: Done state

    private var doneState: some View {
        VStack(spacing: 0) {
            doneHeader
            Divider()
            resultsTable
        }
    }

    private var doneHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            let saved = model.totalInputBytes - model.totalOutputBytes
            Text(
                "\(model.convertedCount) converted · "
                    + "\(byteLabel(model.totalInputBytes)) → \(byteLabel(model.totalOutputBytes))"
                    + (saved > 0 ? " · saved \(byteLabel(saved))" : "")
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
            Spacer()
            Button {
                model.revealOutput()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .hoverHighlight()
            Button("Convert Another Folder") { model.reset() }
                .hoverHighlight()
        }
        .padding(12)
    }

    private var resultsTable: some View {
        // Rows and their preview URLs computed once per evaluation and
        // shared by the table and the Quick Look navigation.
        let rows = model.rows.filter(\.participated)
        let previewURLs = rows.map(model.previewURL(for:))
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
        // Space previews the selected row's OUTPUT — inspect what the
        // conversion did.
        .quickLookNavigation(
            ids: rows.map(\.id), urls: previewURLs, selection: $selectedRow
        )
    }

    private func resultBadge(_ row: FileRow) -> some View {
        capsuleBadge(
            row.resultText.label, help: row.resultText.help,
            error: row.failed,
            tint: row.result?.converted == true ? Color.green : nil
        )
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
            }
            if let err = model.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(err)
            } else {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !model.rows.isEmpty {
                Text("\(model.rows.count) PDF\(model.rows.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        switch model.phase {
        case .idle:
            return "Originals are never modified"
        case .analysing, .review:
            return model.sourceLabel
        case .converting:
            return "Writing to \(model.outputURL?.path ?? "")"
        case .done:
            return model.outputURL?.path ?? ""
        }
    }
}
