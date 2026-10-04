import Foundation
import PressKit

/// A batch asked for: from the window, once its files were reviewed, or from an
/// assistant through the helper. Values, so a job can be queued in the app,
/// described over the socket and reported back as JSON without three spellings
/// of the same thing.

/// What a batch is to do.
public struct JobRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// What the job is called in the queue: the source folder, or the first file.
    public var name: String
    /// PDFs and folders of them, as absolute file URLs.
    public var sources: [URL]
    /// The folder the compressed copies go in, mirroring the sources' tree.
    public var output: URL
    /// Also copy the files analysis says to leave alone, so the output folder
    /// mirrors the sources whole; otherwise only the files worth re-compressing
    /// are written. (A batch from the window names its files instead.)
    public var copyUnchanged: Bool
    /// Changes to the app's settings for this batch alone.
    public var overrides: SettingsOverrides

    public init(
        id: UUID = UUID(), name: String? = nil, sources: [URL], output: URL,
        copyUnchanged: Bool = false, overrides: SettingsOverrides = SettingsOverrides()
    ) {
        self.id = id
        self.sources = sources
        self.output = output
        self.copyUnchanged = copyUnchanged
        self.overrides = overrides
        self.name = name ?? Self.name(for: sources)
    }

    /// The single source's name, else the first one's and how many more.
    public static func name(for sources: [URL]) -> String {
        guard let first = sources.first else { return "Batch" }
        let name = first.deletingPathExtension().lastPathComponent
        return sources.count == 1 ? name : "\(name) and \(sources.count - 1) more"
    }
}

/// Settings a request changes; anything nil keeps the app's own. Overrides
/// rather than a whole `Converter.Settings`, so an assistant asking for "no
/// OCR" doesn't silently reset the user's resolution caps to the defaults.
public struct SettingsOverrides: Codable, Sendable, Equatable {
    public var dpiCap: Int?
    public var photoDpiCap: Int?
    public var ocr: Bool?
    public var jpegQuality: Double?
    public var minSavingPercent: Int?
    public var demotedTextFormat: Converter.DemotedTextFormat?
    public var removeScanEdges: Bool?

    public init(
        dpiCap: Int? = nil, photoDpiCap: Int? = nil, ocr: Bool? = nil,
        jpegQuality: Double? = nil, minSavingPercent: Int? = nil,
        demotedTextFormat: Converter.DemotedTextFormat? = nil, removeScanEdges: Bool? = nil
    ) {
        self.dpiCap = dpiCap
        self.photoDpiCap = photoDpiCap
        self.ocr = ocr
        self.jpegQuality = jpegQuality
        self.minSavingPercent = minSavingPercent
        self.demotedTextFormat = demotedTextFormat
        self.removeScanEdges = removeScanEdges
    }

    public func applied(to base: Converter.Settings) -> Converter.Settings {
        var s = base
        if let dpiCap { s.dpiCap = dpiCap }
        if let photoDpiCap { s.photoDpiCap = photoDpiCap }
        if let ocr { s.ocr = ocr }
        if let jpegQuality { s.jpegQuality = jpegQuality }
        if let minSavingPercent { s.minSavingFraction = Double(minSavingPercent) / 100 }
        if let demotedTextFormat { s.demotedTextFormat = demotedTextFormat }
        if let removeScanEdges { s.removeScanEdges = removeScanEdges }
        return s
    }
}

/// Who asked.
public enum JobSource: String, Codable, Sendable {
    case window
    case assistant
}

public enum JobState: String, Codable, Sendable {
    /// An assistant's batch being scanned and analysed, as the window does
    /// before its review.
    case analysing
    /// From an assistant, held until someone in the window lets it run.
    case awaitingApproval
    case queued
    case converting
    case finished
    /// Never ran: nothing to read, or an output folder that would overwrite an
    /// original. A batch whose individual files fail still finishes.
    case failed
    case cancelled

    /// Whether the job is over, one way or another.
    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .analysing, .awaitingApproval, .queued, .converting: false
        }
    }
}

/// One file of a batch, as a client is told about it.
public struct FileStatus: Codable, Sendable, Equatable {
    /// The source file.
    public var path: String
    /// Where it goes, under the job's output folder.
    public var relativePath: String
    public var verdict: PDFInspector.Verdict?
    public var pages: Int?
    public var inputBytes: Int?
    public var estimatedBytes: Int?
    /// Whether the batch writes this file.
    public var included: Bool
    public var outcome: Converter.Outcome?
    public var outputBytes: Int?
    /// Why the file couldn't be read.
    public var error: String?
    /// Why its conversion failed — apart from `error`, so a client needn't
    /// guess which went wrong.
    public var conversionError: String?

    public init(
        path: String, relativePath: String, verdict: PDFInspector.Verdict? = nil,
        pages: Int? = nil, inputBytes: Int? = nil, estimatedBytes: Int? = nil,
        included: Bool, outcome: Converter.Outcome? = nil, outputBytes: Int? = nil,
        error: String? = nil, conversionError: String? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.verdict = verdict
        self.pages = pages
        self.inputBytes = inputBytes
        self.estimatedBytes = estimatedBytes
        self.included = included
        self.outcome = outcome
        self.outputBytes = outputBytes
        self.error = error
        self.conversionError = conversionError
    }
}

/// What a batch has written so far: counted once by the app, so a status
/// without its file list still carries them.
public struct JobTotals: Codable, Sendable, Equatable {
    public var converted = 0
    public var copied = 0
    public var failed = 0
    /// Input of the files written — a failed file saved nothing, so it counts
    /// on neither side of the saving.
    public var inputBytes = 0
    public var outputBytes = 0

    public init() {}

    /// Files finished, one way or the other.
    public var done: Int { converted + copied + failed }
    public var savedBytes: Int { max(0, inputBytes - outputBytes) }

    /// Counts one file's result.
    public mutating func add(_ result: Converter.FileResult?, failed didFail: Bool) {
        if didFail { failed += 1 }
        guard let result else { return }
        if result.converted { converted += 1 } else { copied += 1 }
        inputBytes += result.inputBytes
        outputBytes += result.outputBytes
    }
}

/// A job as it stands, for the window's list and for a client asking after it.
public struct JobStatus: Codable, Sendable, Equatable, Identifiable {
    /// The job as it was asked for, carried whole rather than copied field by
    /// field.
    public var request: JobRequest
    public var source: JobSource
    public var state: JobState
    /// Why the job failed, or was refused.
    public var failure: String?
    /// The files the batch writes.
    public var total: Int
    public var totals: JobTotals
    /// Every file of the batch. Empty in a progress update or a list of the
    /// queue: a list that long, sent each time, would cost the square of the
    /// batch.
    public var files: [FileStatus]

    public init(
        request: JobRequest, source: JobSource, state: JobState, failure: String? = nil,
        total: Int = 0, totals: JobTotals = JobTotals(), files: [FileStatus] = []
    ) {
        self.request = request
        self.source = source
        self.state = state
        self.failure = failure
        self.total = total
        self.totals = totals
        self.files = files
    }

    public var id: UUID { request.id }
    public var name: String { request.name }
    public var done: Int { totals.done }

    /// How far through, 0 to 1, while converting.
    public var fraction: Double? {
        total > 0 ? Double(done) / Double(total) : nil
    }
}

/// Why the app won't take a batch, in words for whoever asked.
public struct JobRefusal: LocalizedError, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

extension PDFInspector.Report {
    /// Whether a batch writes this file: when the verdict says to convert it,
    /// or always when unchanged files are copied too. The one rule the window,
    /// the queue and the helper tick files by.
    public func isWritten(copyingUnchanged: Bool) -> Bool {
        verdict == .convert || copyingUnchanged
    }
}

// MARK: Words shared by the window and the helper

/// A byte count as Finder writes it.
public func byteLabel(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

extension PDFInspector.PassReason {
    /// Why a file is left alone, as a short label ("Born digital").
    public var label: String {
        switch self {
        case .bornDigital: "Born digital"
        case .alreadyProcessed: "Already converted"
        case .alreadyCompact: "Already compact"
        case .alreadySmall: "Already small"
        }
    }
}

extension Array where Element == Converter.PageEncoding {
    /// How a file's pages were stored: "1-bit ×12 · grayscale ×1".
    public var summary: String {
        let names: [(Converter.PageEncoding, String)] = [
            (.g4, "1-bit"), (.gray4, "grayscale"), (.jpeg, "JPEG"), (.original, "kept as-is"),
        ]
        return names.compactMap { encoding, name in
            let count = self.count { $0 == encoding }
            return count > 0 ? "\(name) ×\(count)" : nil
        }
        .joined(separator: " · ")
    }
}

// MARK: Settings

/// Where the app keeps its conversion settings, so the helper's preview reads
/// the same ones the queue converts with.
public enum SettingsStore {
    public static let dpiCap = "dpiCap"
    public static let photoDpiCap = "photoDpiCap"
    public static let ocr = "ocrEnabled"
    public static let jpegQuality = "jpegQuality"
    public static let minSavingPercent = "minSavingPercent"
    public static let demotedTextFormat = "demotedTextFormat"
    public static let removeScanEdges = "removeScanEdges"

    /// The app's own defaults. Inside the bundle the helper's main bundle is
    /// the app's, so its standard defaults are the app's already (and a suite
    /// may not name it); a development build of the helper names the domain.
    public static var appDefaults: UserDefaults {
        Bundle.main.bundleIdentifier == JobChannel.bundleIdentifier
            ? .standard : UserDefaults(suiteName: JobChannel.bundleIdentifier) ?? .standard
    }

    /// The settings stored in `defaults`, the library's own for anything unset.
    public static func load(_ defaults: UserDefaults) -> Converter.Settings {
        var s = Converter.Settings()
        if let v = defaults.object(forKey: dpiCap) as? Int { s.dpiCap = v }
        if let v = defaults.object(forKey: photoDpiCap) as? Int { s.photoDpiCap = v }
        if let v = defaults.object(forKey: ocr) as? Bool { s.ocr = v }
        if let v = defaults.object(forKey: jpegQuality) as? Double { s.jpegQuality = v }
        if let v = defaults.object(forKey: minSavingPercent) as? Int {
            s.minSavingFraction = Double(v) / 100
        }
        if let v = defaults.string(forKey: demotedTextFormat),
            let format = Converter.DemotedTextFormat(rawValue: v)
        {
            s.demotedTextFormat = format
        }
        if let v = defaults.object(forKey: removeScanEdges) as? Bool { s.removeScanEdges = v }
        return s
    }
}
