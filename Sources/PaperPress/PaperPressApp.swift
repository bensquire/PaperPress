import PressApp
import SwiftUI

@main
struct PaperPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Dev/testing convenience: `PAPERPRESS_FOLDER=/path PaperPress` skips
    // straight to analysing that folder. (An ordinary CLI argument won't
    // do — AppKit treats it as a document to open and then never creates
    // the window.) Read here at the composition root so AppModel itself
    // stays environment-free.
    @StateObject private var model = AppModel(
        initialFolder: ProcessInfo.processInfo.environment["PAPERPRESS_FOLDER"]
            .flatMap { path in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path, isDirectory: &isDir)
                return exists && isDir.boolValue ? URL(fileURLWithPath: path) : nil
            }
    )

    var body: some Scene {
        // Single-instance Window, not WindowGroup: the app has one shared
        // model, and WindowGroup spawns duplicate clone windows when
        // Finder sends open-document events.
        Window("PaperPress", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.busy)
                Button("Convert…") { model.chooseOutputAndConvert() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canConvert)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
