import Foundation

public enum PressError: LocalizedError {
    case scanFailed(String)
    case wouldOverwrite(String)

    public var errorDescription: String? {
        switch self {
        case let .scanFailed(s): "Processing failed: \(s)"
        case let .wouldOverwrite(name):
            "Writing \(name) here would overwrite the original"
        }
    }
}

/// Compatibility name so the pipeline files copied from PaperDrop's ScanKit
/// (Pipeline, G4, OCR, ImageHelpers; PDFWriter has since diverged with the
/// gray4Flate case) diff cleanly against their originals. New code uses
/// PressError.
public typealias ScanError = PressError
