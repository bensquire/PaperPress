import CoreGraphics
import Foundation
import Vision

/// Native OCR via the Vision framework.
public enum OCR {
    public struct Word: Sendable {
        public let text: String
        /// Normalised bounding box, bottom-left origin (Vision/PDF convention).
        public let box: CGRect
    }

    /// Recognise text on any image, one entry per word, each with its own
    /// box: a whole line stretched over its box drifts from the ink.
    ///
    /// Vision's document reader rather than its line reader
    /// (VNRecognizeTextRequest): on a 150 dpi letter that read two lines as
    /// one garbled one ("«State» and other states have the primary
    /// responsibility…" came out "-state and the ste have the primary
    /// responsity…", the line above it lost) at 150, 200 and 300 dpi alike,
    /// where this reads both, in the same time, and boxes the words itself.
    public static func recognize(cgImage img: CGImage) async throws -> [Word] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.maximumCandidateCount = 1
        return try await request.perform(on: img).flatMap { words(in: $0.document.text) }
    }

    /// Each line's words, or the line whole where Vision doesn't split it into
    /// words: Chinese, Japanese, Korean and Thai
    /// (/documentation/vision/documentobservation/container/text-swift.struct/words),
    /// whose lines a page mixing them with English had otherwise lost.
    private static func words(in text: DocumentObservation.Container.Text) -> [Word] {
        let lines = text.lines
        var byLine = [[RecognizedTextObservation]](repeating: [], count: lines.count)
        for word in text.words ?? [] {
            let box = word.boundingBox.cgRect
            let middle = CGPoint(x: box.midX, y: box.midY)
            if let i = lines.firstIndex(where: { $0.boundingBox.cgRect.contains(middle) }) {
                byLine[i].append(word)
            }
        }
        return zip(lines, byLine).flatMap { line, words in
            (words.isEmpty ? [line] : words).compactMap { observation in
                observation.topCandidates(1).first.map {
                    Word(text: $0.string, box: observation.boundingBox.cgRect)
                }
            }
        }
    }
}
