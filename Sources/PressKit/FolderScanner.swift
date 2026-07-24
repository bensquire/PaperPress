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

    /// Expands a dropped/chosen mix of PDF files and folders into items.
    /// Folders scan recursively; with more than one source, each folder's
    /// items are prefixed with the folder name so two sources can't
    /// collide. Duplicate source files are dropped (first wins); duplicate
    /// output names get a numbered suffix.
    public static func items(for urls: [URL]) -> [Item] {
        var expanded: [Item] = []
        for url in urls {
            let isDir =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            if isDir {
                let prefix = urls.count > 1 ? url.lastPathComponent + "/" : ""
                expanded += pdfs(under: url).map {
                    Item(url: $0.url, relativePath: prefix + $0.relativePath)
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                expanded.append(Item(url: url, relativePath: url.lastPathComponent))
            }
        }

        var seenSources = Set<String>()
        var seenPaths = Set<String>()
        var items: [Item] = []
        for item in expanded {
            guard seenSources.insert(item.url.standardizedFileURL.path).inserted
            else { continue }
            var path = item.relativePath
            var n = 2
            while !seenPaths.insert(path).inserted {
                let base = (item.relativePath as NSString).deletingPathExtension
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
        return items.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}
