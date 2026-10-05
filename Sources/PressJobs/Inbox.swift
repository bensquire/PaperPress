import Foundation

/// A folder an assistant can save a PDF into when it isn't on this Mac yet —
/// attached to a chat, say — so converting it leaves no stray copy behind.
/// PaperPress deletes a file here once a batch has written it out, and
/// anything still here after a day: the only place it deletes a source.
public enum Inbox {
    public static var folder: URL {
        JobChannel.home.appendingPathComponent("Library/Caches/PaperPress/Inbox", isDirectory: true)
    }

    /// How long a file waits here when no batch wrote it out: analysed only,
    /// or its batch failed or was cancelled.
    static let keptFor: TimeInterval = 24 * 60 * 60

    /// Creates the folder, so a client can save straight into it.
    public static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// `url` is `folder` itself or anything in it: no place for output, which
    /// would be swept away.
    public static func covers(_ url: URL, in folder: URL = folder) -> Bool {
        (url.standardizedFileURL.path + "/").hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// The item at `url` lives in `folder`: its path is inside, and so is its
    /// parent with symlinks resolved, so a linked folder can't lead a deletion
    /// out. (Deleting a link deletes only the link.)
    public static func contains(_ url: URL, in folder: URL = folder) -> Bool {
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
            return false
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent + "/").hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    /// Deletes the files among `urls` that are in `folder`, then any folders
    /// that leaves empty.
    public static func remove(_ urls: [URL], from folder: URL = folder) {
        let fm = FileManager.default
        for url in urls where contains(url, in: folder) {
            // Files only: removeItem would take a folder and everything in it.
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false else {
                continue
            }
            try? fm.removeItem(at: url)
            // rmdir removes only an empty folder.
            var parent = url.deletingLastPathComponent()
            while contains(parent, in: folder), rmdir(parent.path) == 0 {
                parent.deleteLastPathComponent()
            }
        }
    }

    /// Deletes what has waited in `folder` longer than `keptFor`, timed from
    /// when it arrived there: a copy can keep its original's dates.
    public static func sweep(_ folder: URL = folder, now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        else { return }
        let stale = items.compactMap { item -> URL? in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: keys),
                let arrived = values.addedToDirectoryDate ?? values.creationDate,
                now.timeIntervalSince(arrived) > keptFor
            else { return nil }
            return url
        }
        remove(stale, from: folder)
    }
}
