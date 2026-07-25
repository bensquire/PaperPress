import QuickLook
import SwiftUI

/// Gentle hover feedback — macOS button styles give little or none.
/// Inert while the control is disabled.
struct HoverHighlight: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let active = hovering && isEnabled
        content
            .brightness(active ? 0.07 : 0)
            .scaleEffect(active ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(scale: CGFloat = 1.02) -> some View {
        modifier(HoverHighlight(scale: scale))
    }
}

/// Finder-style Quick Look on a table: space toggles the panel for the
/// selected row, arrow keys (in the table or inside the panel) move
/// through the rows, and table selection stays in step with the panel.
/// The preview item is view-local state, discarded with the table.
struct QuickLookNavigation: ViewModifier {
    let ids: [FileRow.ID]
    let urls: [URL]
    @Binding var selection: FileRow.ID?
    @State private var previewItem: URL?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($previewItem, in: urls)
            .onChange(of: selection) { newSelection in
                if previewItem != nil, let id = newSelection,
                    let i = ids.firstIndex(of: id)
                {
                    previewItem = urls[i]
                }
            }
            .onChange(of: previewItem) { newItem in
                guard let newItem, let i = urls.firstIndex(of: newItem)
                else { return }
                selection = ids[i]
            }
            .background(
                Button("") { toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .hidden()
            )
    }

    private func toggle() {
        if previewItem != nil {
            previewItem = nil
            return
        }
        guard
            let i = selection.flatMap(ids.firstIndex(of:))
                ?? (ids.isEmpty ? nil : 0)
        else { return }
        selection = ids[i]
        previewItem = urls[i]
    }
}

extension View {
    func quickLookNavigation(
        ids: [FileRow.ID], urls: [URL], selection: Binding<FileRow.ID?>
    ) -> some View {
        modifier(QuickLookNavigation(ids: ids, urls: urls, selection: selection))
    }
}
