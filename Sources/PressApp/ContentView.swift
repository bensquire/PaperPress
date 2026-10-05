import PressJobs
import PressKit
import SwiftUI

/// The window: whichever batch is selected — the one being put together, or a
/// queued one with its progress and results — with the queue in a trailing
/// column beside it.
public struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// Remembered between launches, like a window's inspector.
    @AppStorage("showsQueue") private var showsQueue = true

    public init() {}

    public var body: some View {
        Group {
            switch model.selection {
            case .draft:
                DraftView()
            case .job(let id):
                if let job = model.job(id) {
                    JobView(job: job)
                        // A fresh view per job, so one job's table selection
                        // and preview don't carry over to the next.
                        .id(id)
                } else {
                    DraftView()
                }
            }
        }
        // /documentation/swiftui/view/inspector(ispresented:content:)
        .inspector(isPresented: $showsQueue) {
            QueueList()
                .inspectorColumnWidth(min: 200, ideal: 240, max: 340)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsQueue.toggle()
                } label: {
                    Label(showsQueue ? "Hide Queue" : "Show Queue", systemImage: "sidebar.trailing")
                }
                .help(showsQueue ? "Hide the queue" : "Show the queue")
            }
        }
        .frame(minWidth: 820, minHeight: 460)
        // The window is the app's only scene, and closing it quits
        // (/documentation/swiftui/window) — so it can't close with batches
        // unfinished. Quitting outright asks first (AppDelegate).
        .windowDismissBehavior(model.hasUnfinishedJobs ? .disabled : .automatic)
    }
}

/// The batch being put together, then every job this session.
struct QueueList: View {
    @EnvironmentObject var model: AppModel
    /// Not focused when the window opens: a focused list draws its selection
    /// in the accent colour, and the selected batch row read as a button. A
    /// click focuses it as usual.
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $model.selection) {
            Section("Current Batch") {
                DraftRow()
                    .tag(AppModel.Selection.draft)
            }
            if !model.jobs.isEmpty {
                Section("Queue") {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                            .tag(AppModel.Selection.job(job.id))
                            .contextMenu { menu(for: job) }
                    }
                }
            }
        }
        .focused($focused)
        // After the window has made the list its first responder.
        .onAppear { DispatchQueue.main.async { focused = false } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearFinishedJobs() }
                    .controlSize(.small)
                    .disabled(!model.jobs.contains { $0.state.isTerminal })
                    .help("Remove finished batches from the list")
                // A printer queue's pair: pause holds what is waiting, so
                // several batches can be lined up before any starts.
                if model.queueIsPaused {
                    Button("Resume") { model.queueIsPaused = false }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Pause") { model.queueIsPaused = true }
                        .controlSize(.small)
                        .help("Hold batches that haven't started")
                }
            }
            // Ends where the window's rounded corner does (see StatusBar).
            .containerCornerOffset(.horizontal, sizeToFit: true)
            .padding(10)
        }
    }

    private var summary: String {
        let waiting = model.jobs.filter { !$0.state.isTerminal }.count
        switch (model.queueIsPaused, waiting) {
        case (false, 0): return "Nothing waiting"
        case (false, _): return "\(waiting) unfinished"
        case (true, 0): return "Paused"
        case (true, _): return "Paused, \(waiting) unfinished"
        }
    }

    @ViewBuilder
    private func menu(for job: Job) -> some View {
        ForEach(JobAction.available(for: job), id: \.self) { action in
            Button(action.title, role: JobView.role(action)) { model.perform(action, on: job.id) }
                .disabled(!action.isEnabled(for: job))
        }
    }
}

/// A job in the queue: its name, where it came from and how it is going.
/// The window's own batch, before it joins the queue.
struct DraftRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(model.draftTitle).lineLimit(1)
            } icon: {
                Image(systemName: "tray.and.arrow.down")
            }
            Text(model.draftDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(job.request.name).lineLimit(1)
            } icon: {
                Image(systemName: JobView.symbol(job.state))
                    .foregroundStyle(JobView.tint(job.state))
            }
            Text(
                "\(job.source == .assistant ? "From an assistant" : "From this window") · \(JobView.stateWords(job))"
            )
            .font(.caption)
            .foregroundStyle(job.state == .failed ? .red : .secondary)
            .lineLimit(1)
            if job.state == .converting {
                ProgressView(value: job.fraction)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Shared cells

/// One capsule style for verdict and outcome badges.
func capsuleBadge(_ label: String, help: String, error: Bool, tint: Color?) -> some View {
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

func fileCell(_ row: FileRow) -> some View {
    Text(row.item.relativePath)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(row.item.relativePath)
}

func byteCell(_ bytes: Int?) -> some View {
    Text(bytes.map(byteLabel) ?? "–")
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
}

func verdictBadge(_ row: FileRow) -> some View {
    capsuleBadge(
        row.verdictLabel, help: row.verdictHelp,
        error: row.error != nil,
        tint: row.isConvert ? Color.accentColor : nil
    )
}

/// The strip along the bottom of the detail: what's going on, or what went wrong.
struct StatusBar: View {
    let text: String
    var error: String?
    var busy = false
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        // Clear of the window's rounded corners, so at a corner the text
        // starts and ends where the curve does (the offset is only what's left
        // of the corner inside the padding;
        // /documentation/swiftui/view/containercorneroffset(_:sizetofit:)).
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }
}
