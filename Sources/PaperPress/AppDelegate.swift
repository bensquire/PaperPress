import AppKit

/// Receives PDFs/folders from Finder — "Open With", Dock drops, and the
/// "Analyse with PaperPress" Services menu entry — and routes them into
/// the same analyse flow as drag & drop. Files can arrive before SwiftUI
/// has built the model, so early deliveries are buffered and flushed
/// when the model attaches.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { flushPending() }
    }
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    @objc(analyseWithPaperPress:userData:error:)
    func analyseWithPaperPress(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        deliver(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let model {
            model.analyse(urls: urls, append: model.phase == .review)
        } else {
            pending += urls
        }
    }

    private func flushPending() {
        guard let model, !pending.isEmpty else { return }
        model.analyse(urls: pending, append: model.phase == .review)
        pending = []
    }
}
