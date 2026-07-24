import Foundation

/// Name-compatible with ScanKit's ScanError so the pipeline files copied
/// from PaperDrop (Pipeline, G4, OCR, ImageHelpers, PDFWriter) diff cleanly
/// against their originals.
public enum ScanError: LocalizedError {
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .scanFailed(s): "Processing failed: \(s)"
        }
    }
}
