import PressKit
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        Form {
            Picker("Document resolution cap", selection: $model.dpiCap) {
                ForEach([150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help("Pages are processed at their native scan resolution, never above this")
            Picker("Photo page resolution cap", selection: $model.photoDpiCap) {
                ForEach([100, 150, 200, 300], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .help("Photographic pages carry no extra detail beyond this; lower = smaller")
            Toggle("Add searchable text layer (OCR)", isOn: $model.ocrEnabled)
            Toggle("Remove black scan edges", isOn: $model.removeScanEdges)
                .help(
                    "Whitens the black bands a scanner lid or skewed feed "
                        + "leaves along page edges (document pages only)"
                )
            Picker("Photo page JPEG quality", selection: $model.jpegQuality) {
                Text("Low (smallest)").tag(0.4)
                Text("Medium").tag(0.6)
                Text("High").tag(0.8)
            }
            Picker("Low-res text pages", selection: $model.demotedTextFormat) {
                Text("4-bit grayscale (crisper, smaller)")
                    .tag(Converter.DemotedTextFormat.gray4)
                Text("Grayscale JPEG (smoother tones)")
                    .tag(Converter.DemotedTextFormat.jpeg)
            }
            .help(
                "Pages whose print is too small to survive black & white "
                    + "stay grayscale; this picks their encoding"
            )
            Picker("Minimum saving to convert", selection: $model.minSavingPercent) {
                ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
            }
            .help(
                "If a converted file isn't at least this much smaller, "
                    + "the original is copied through unchanged"
            )
        }
        .padding(20)
        .frame(width: 480)
    }
}
