import Foundation

public enum PressError: LocalizedError {
    case scanFailed(String)
    case wouldOverwrite(String)
    /// The output path holds a file PaperPress didn't write.
    case destinationExists(String)
    /// The file no longer matches the analysis its conversion plan
    /// came from.
    case changedSinceAnalysis(String)
    case unreadablePage(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .scanFailed(s): "Processing failed: \(s)"
        case let .wouldOverwrite(name):
            "Writing \(name) here would overwrite the original"
        case let .destinationExists(name):
            "\(name) already exists in the output folder and wasn't written by PaperPress"
        case let .changedSinceAnalysis(name):
            "\(name) has changed since it was analysed — analyse it again"
        case let .unreadablePage(page, name):
            "Page \(page) of \(name) can't be read"
        }
    }
}

/// Compatibility name so the pipeline files copied from PaperDrop's ScanKit
/// (Pipeline, G4, OCR, ImageHelpers; PDFWriter has since diverged with the
/// gray4Flate case) diff cleanly against their originals. New code uses
/// PressError.
public typealias ScanError = PressError
