import Foundation

public enum PressError: LocalizedError {
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .scanFailed(s): "Processing failed: \(s)"
        }
    }
}

/// Compatibility name so the pipeline files copied from PaperDrop's ScanKit
/// (Pipeline, G4, OCR, ImageHelpers, PDFWriter) diff cleanly against their
/// originals. New code uses PressError.
public typealias ScanError = PressError
