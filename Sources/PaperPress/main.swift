// Temporary smoke-test CLI — replaced by the SwiftUI app in the next step.
import Foundation
import PressKit

let args = CommandLine.arguments.dropFirst()
guard let inPath = args.first else {
    print("usage: PaperPress <input.pdf> [output.pdf]")
    exit(1)
}
let src = URL(fileURLWithPath: inPath)
let dst = URL(fileURLWithPath: args.dropFirst().first ?? inPath + ".press.pdf")

let report = try PDFInspector.inspect(src)
print("\(src.lastPathComponent): \(report.fileBytes) bytes, \(report.pages.count) pages")
for (i, p) in report.pages.enumerated() {
    print("  page \(i + 1): \(p.kind) \(Int(p.widthPt))x\(Int(p.heightPt))pt")
}
print("verdict: \(report.verdict), est \(report.estimatedBytes) bytes")

let t0 = Date()
let result = try Converter.convert(report: report, to: dst) { page, of in
    print("  converting page \(page)/\(of)")
}
let dt = String(format: "%.1f", Date().timeIntervalSince(t0))
print(
    "\(result.converted ? "converted" : "copied") in \(dt)s: "
        + "\(result.inputBytes) -> \(result.outputBytes) bytes "
        + "(\(result.pageKinds.map { "\($0)" }.joined(separator: ", ")))"
)
