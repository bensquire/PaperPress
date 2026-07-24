import Foundation

/// Finds the PDFs under a folder, recursively, skipping hidden files
/// and file packages. Paths come back sorted and relative to the root
/// so the output tree can mirror the input.
public enum FolderScanner {
    public struct Item: Identifiable, Hashable {
        public let url: URL
        public let relativePath: String
        public var id: String { relativePath }
    }

    /// Expands a dropped/chosen mix of PDF files and folders into the items
    /// they add to a batch. Folders scan recursively; loose PDFs land flat
    /// under their file name; anything else is ignored — this is the single
    /// owner of "what counts as a source".
    ///
    /// The batch invariant — every distinct source file appears once, under
    /// a unique output path — holds across calls: pass the batch's current
    /// items as `existing` and only new, uniquely-named additions come
    /// back. Folder items are name-prefixed whenever the batch has more
    /// than one source (several URLs, or anything already present), so the
    /// same folder can't collide with other sources; duplicate names get a
    /// numbered suffix.
    public static func items(
        for urls: [URL], merging existing: [Item] = []
    ) -> [Item] {
        let multiSource = urls.count > 1 || !existing.isEmpty
        var expanded: [Item] = []
        for url in urls {
            let isDir =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            if isDir {
                let prefix = multiSource ? url.lastPathComponent + "/" : ""
                expanded += scanFolder(url).map {
                    Item(url: $0.url, relativePath: prefix + $0.relativePath)
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                expanded.append(Item(url: url, relativePath: url.lastPathComponent))
            }
        }

        var seenSources = Set(existing.map { $0.url.standardizedFileURL.path })
        var seenPaths = Set(existing.map(\.relativePath))
        var items: [Item] = []
        for item in expanded {
            guard seenSources.insert(item.url.standardizedFileURL.path).inserted
            else { continue }
            var path = item.relativePath
            let base = (item.relativePath as NSString).deletingPathExtension
            var n = 2
            while !seenPaths.insert(path).inserted {
                path = "\(base)-\(n).pdf"
                n += 1
            }
            items.append(Item(url: item.url, relativePath: path))
        }
        return items.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    public static func pdfs(under root: URL) -> [Item] {
        scanFolder(root).sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func scanFolder(_ root: URL) -> [Item] {
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var items: [Item] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "pdf",
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            let rel =
                full.hasPrefix(rootPath + "/")
                ? String(full.dropFirst(rootPath.count + 1))
                : url.lastPathComponent
            items.append(Item(url: url, relativePath: rel))
        }
        return items
    }
}
