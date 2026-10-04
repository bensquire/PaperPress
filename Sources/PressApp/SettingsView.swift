import PressKit
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        TabView {
            conversionPane
                .tabItem { Label("Conversion", systemImage: "doc.badge.gearshape") }
            AssistantsPane(automation: model.automation)
                .tabItem { Label("Assistants", systemImage: "sparkles") }
        }
    }

    private var conversionPane: some View {
        Form {
            Picker("Document resolution cap", selection: $model.dpiCap) {
                ForEach([150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help(
                "Text pages are rendered at this resolution: sharper scans are "
                    + "downsampled, lower-res ones upsampled for smoother 1-bit edges"
            )
            Picker("Photo page resolution cap", selection: $model.photoDpiCap) {
                ForEach([100, 150, 200, 300], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help("Photographic pages are stored at their own resolution up to this; lower = smaller")
            Toggle("Add searchable text layer (OCR)", isOn: $model.ocrEnabled)
            Toggle("Remove black scan edges", isOn: $model.removeScanEdges)
                .help(
                    "Whitens the black bands a scanner lid or skewed feed "
                        + "leaves along page edges (document pages only)"
                )
            Picker("Photo page JPEG quality", selection: $model.jpegQuality) {
                Text("Low (smallest)").tag(0.4)
                Text("Medium").tag(0.6)
                Text("High").tag(0.8)
            }
            Picker("Text kept grayscale", selection: $model.demotedTextFormat) {
                Text("4-bit grayscale (crisper, smaller)")
                    .tag(Converter.DemotedTextFormat.gray4)
                Text("Grayscale JPEG (smoother tones)")
                    .tag(Converter.DemotedTextFormat.jpeg)
            }
            .help(
                "Text pages too low-res, or with print too fine, for black & white "
                    + "stay grayscale; this picks their encoding"
            )
            Picker("Minimum saving to convert", selection: $model.minSavingPercent) {
                ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
            }
            .help(
                "If a converted file isn't at least this much smaller, "
                    + "the original is copied through unchanged"
            )
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Whether an AI assistant may hand batches to the queue, and how to tell it
/// where the helper is.
struct AssistantsPane: View {
    @ObservedObject var automation: Automation
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI assistants to convert with PaperPress", isOn: $automation.isEnabled)
                LabeledContent("Status") {
                    Text(stateDescription)
                        .foregroundStyle(automation.state == .listening ? .primary : .secondary)
                }
                Toggle("Ask before converting a batch from an assistant", isOn: $model.approvesAssistantJobs)
            } footer: {
                Text(
                    "An assistant's batches join the queue, where they can be cancelled — or approved first, with files unticked, when asking is on. Analysing and previewing work without this: they only read files."
                )
                .foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                copyable(automation.claudeCodeCommand)
            }
            Section("Claude Desktop") {
                copyable(automation.claudeDesktopConfiguration)
            }
            Section {
                copyable(automation.helperURL.path)
            } header: {
                Text("Other assistants")
            } footer: {
                Text(
                    "Cursor, VS Code, Zed, Codex, Gemini CLI and any other tool that runs a local MCP server: give it this command, with no arguments. Use full paths to PDFs, since the command doesn't start in your project folder."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The window's width, and the height the rows need: sized in both, the
        // long lines took their unwrapped width (as Prospect found).
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stateDescription: String {
        switch automation.state {
        case .stopped: "Off"
        case .listening: "Listening"
        case .failed(let message): "Could not start: \(message)"
        }
    }

    private func copyable(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
    }
}
