import SwiftUI

@main
struct PaperPressApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PaperPress") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder…") { model.chooseSourceFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.busy)
                Button("Convert…") { model.chooseOutputAndConvert() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.phase != .review || model.includedRows.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Document resolution cap", selection: $model.dpiCap) {
                ForEach([150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help("Pages are processed at their native scan resolution, never above this")
            Picker("Photo page resolution cap", selection: $model.photoDpiCap) {
                ForEach([100, 150, 200, 300], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help("Photographic pages carry no extra detail beyond this; lower = smaller")
            Toggle("Add searchable text layer (OCR)", isOn: $model.ocrEnabled)
            Picker("Photo page JPEG quality", selection: $model.jpegQuality) {
                Text("Low (smallest)").tag(0.4)
                Text("Medium").tag(0.6)
                Text("High").tag(0.8)
            }
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
