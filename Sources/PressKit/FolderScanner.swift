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
