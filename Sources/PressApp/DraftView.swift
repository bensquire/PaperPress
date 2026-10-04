import PressJobs
import PressKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The batch being put together: drop PDFs or folders, watch them analysed,
/// review the verdicts, then Convert hands the batch to the queue.
struct DraftView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedRow: FileRow.ID?
    @State private var dropHovering = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                dropState
            case let .analysing(done, of):
                analysingState(done: done, of: of)
            case .review:
                reviewTable
                Divider()
                convertBar
            }
            StatusBar(
                text: model.phase == .idle ? "Originals are never modified" : model.sourceLabel,
                error: model.errorText, busy: model.busy,
                trailing: model.rows.isEmpty
                    ? nil : "\(model.rows.count) PDF\(model.rows.count == 1 ? "" : "s")"
            )
        }
        .onChange(of: model.phase) {
            // A phase change invalidates what the selection points at.
            // (Preview state lives inside QuickLookNavigation and is
            // discarded with each table.)
            selectedRow = nil
        }
    }

    // MARK: Centred states

    /// Shared skeleton for the drop / progress states: centred header +
    /// title + detail, sitting slightly above centre.
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

    // MARK: Analysing state

    private func analysingState(done: Int, of: Int) -> some View {
        centeredState(title: "Analysing PDFs…") {
            if of > 0 {
                ProgressView(value: Double(done), total: Double(of))
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
            }
        } detail: {
            Text(of > 0 ? "\(done) of \(of)" : "Looking for PDFs")
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

    private var reviewTable: some View {
        ReviewTable(
            rows: model.rows, selection: $selectedRow,
            setIncluded: { included, id in
                FileRow.update(&model.rows, id) { $0.included = included }
            }
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers, append: true)
        }
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
            .help("Choose an output folder; the batch joins the queue")
            Button("Discard", role: .destructive) { model.reset() }
                .hoverHighlight()
        }
        .padding(12)
    }
}

/// Verdicts with a tick per file: the window's review, and an assistant's
/// batch waiting for approval. Space previews the selected SOURCE file —
/// inspect before ticking.
struct ReviewTable: View {
    let rows: [FileRow]
    @Binding var selection: FileRow.ID?
    let setIncluded: (Bool, FileRow.ID) -> Void

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                Toggle(
                    "",
                    isOn: Binding(get: { row.included }, set: { setIncluded($0, row.id) })
                )
                .labelsHidden()
                .disabled(row.report == nil)
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
        .quickLookNavigation(
            ids: rows.map(\.id), urls: rows.map(\.item.url), selection: $selection
        )
    }
}
