import AppKit

/// Receives PDFs/folders from Finder — "Open With", Dock drops, and the
/// "Analyse with PaperPress" Services menu entry — and routes them into
/// the same analyse flow as drag & drop. Files can arrive before SwiftUI
/// has built the model, so early deliveries are buffered and flushed
/// when the model attaches.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public var model: AppModel? {
        didSet {
            let queued = pending
            pending = []
            deliver(queued)
        }
    }
    private var pending: [URL] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    @objc(analyseWithPaperPress:userData:error:)
    func analyseWithPaperPress(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        deliver(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
    }

    private func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let model else {
            pending += urls
            return
        }
        model.open(urls: urls)
        // Open With/Dock activate the app themselves; Services invocations
        // don't — activating here covers every entry uniformly.
        NSApp.activate(ignoringOtherApps: true)
    }
}
