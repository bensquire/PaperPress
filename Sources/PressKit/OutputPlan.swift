import Foundation

/// Where a batch's outputs go, and whether a chosen folder is safe for
/// them. The output tree mirrors the sources' relative paths, so a folder
/// inside a source tree can put one file's output on top of another
/// original; this is the check that refuses it before anything is
/// written. Converter's per-file destination check is the backstop.
public enum OutputPlan {
    public static func destination(for item: FolderScanner.Item, in folder: URL) -> URL {
        folder.appendingPathComponent(item.relativePath)
    }

    /// The first item among `converting` whose output path is one of the
    /// batch's sources (`sources` should be the whole batch, ticked or not:
    /// every one of them is an original). Only an output path that already
    /// exists can be an original, so the sources are looked up only when one
    /// does — a fresh output folder costs one failed lookup a file.
    public static func firstCollision(
        _ converting: [FolderScanner.Item], sources: [FolderScanner.Item], in folder: URL
    ) -> FolderScanner.Item? {
        let existing = converting.compactMap { item in
            identity(of: destination(for: item, in: folder)).map { (item, $0) }
        }
        guard !existing.isEmpty else { return nil }
        let originals = Set(sources.compactMap { identity(of: $0.url) })
        return existing.first { originals.contains($0.1) }?.0
    }

    /// True when both URLs name the same existing file — however the paths
    /// are spelled (case, Unicode normalisation, symlinks, `..`).
    public static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ia = identity(of: a), let ib = identity(of: b) else { return false }
        return ia == ib
    }

    /// The file system's identifier for an existing file, nil if absent.
    private static func identity(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
    }
}
