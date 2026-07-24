import PressKit
import SwiftUI
import UniformTypeIdentifiers

/// Gentle hover feedback — macOS button styles give little or none.
/// Inert while the control is disabled.
struct HoverHighlight: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let active = hovering && isEnabled
        content
            .brightness(active ? 0.07 : 0)
            .scaleEffect(active ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(scale: CGFloat = 1.02) -> some View {
        modifier(HoverHighlight(scale: scale))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
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

    /// Gather every dropped URL (PDFs and folders), then hand them to the
    /// model in one call. Returns false if the drag carries no file URLs.
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
                guard let url else { continue }
                let isDir =
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                if isDir || url.pathExtension.lowercased() == "pdf" {
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

    private var reviewTable: some View {
        table
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers, append: true)
            }
    }

    private var table: some View {
        Table(model.rows) {
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
                Text(row.item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.item.relativePath)
            }
            TableColumn("Pages") { row in
                Text(row.report.map { "\($0.pages.count)" } ?? "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(44)
            TableColumn("Size") { row in
                Text(row.report.map { byteLabel($0.fileBytes) } ?? "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
    }

    private func verdictBadge(_ row: FileRow) -> some View {
        Text(row.verdictLabel)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    row.error != nil
                        ? Color.red.opacity(0.15)
                        : row.isConvert
                            ? Color.accentColor.opacity(0.18)
                            : Color(.quaternaryLabelColor).opacity(0.5)
                )
            )
            .foregroundStyle(
                row.error != nil
                    ? .red : row.isConvert ? Color.accentColor : Color.secondary
            )
            .help(row.verdictHelp)
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
        centeredState(title: "Done") {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.green)
        } detail: {
            let saved = model.totalInputBytes - model.totalOutputBytes
            Text(
                "\(model.convertedCount) converted · "
                    + "\(byteLabel(model.totalInputBytes)) → \(byteLabel(model.totalOutputBytes))"
                    + (saved > 0 ? " · saved \(byteLabel(saved))" : "")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            HStack(spacing: 12) {
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
        }
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
