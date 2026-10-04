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

    public func applicationWillTerminate(_ notification: Notification) {
        model?.automation.shutdown()
    }

    /// Quitting with batches unfinished asks first. Files already written are
    /// complete (each is written atomically); the rest would silently go
    /// unconverted, and the queue doesn't outlive the app.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasUnfinishedJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with batches unfinished?"
        alert.informativeText =
            "Files already written are complete. Batches still converting, waiting or awaiting approval won't be converted."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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
        // don't — activating here covers every entry uniformly. A request,
        // not a command, under cooperative activation
        // (/documentation/appkit/nsapplication/activate()).
        NSApp.activate()
    }
}
