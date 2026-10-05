import Foundation

/// Minimal PDF writer. Pages are CCITT G4 streams (1-bit documents,
/// embedded losslessly), grayscale JPEGs (photo-ish pages, DCTDecode),
/// 4-bit grayscale Flate (demoted text pages), or born-digital pages
/// copied from their source unchanged.
/// An invisible OCR text layer (render mode 3) makes raster pages
/// searchable.
public enum PDFWriter {
    public enum Content: Sendable {
        case g4(G4.Stream)
        case jpegGray(Data, width: Int, height: Int)
        case gray4Flate(Gray4.Encoded)
        case original(CopiedPage)
    }

    public struct Page: Sendable {
        public let content: Content
        public let dpi: Int
        public let ocrWords: [OCR.Word]
        /// Page size override in points; nil = natural image size.
        public var pageSizePt: (w: Double, h: Double)?
        /// Where the content sat on the scanner bed (points, from top-left).
        /// When the page is padded, the image is placed back at this
        /// physical position so the original layout is reproduced.
        public var bedOriginPt: (x: Double, y: Double)
        public init(
            content: Content, dpi: Int, ocrWords: [OCR.Word] = [],
            pageSizePt: (w: Double, h: Double)? = nil,
            bedOriginPt: (x: Double, y: Double) = (0, 0)
        ) {
            self.content = content
            self.dpi = dpi
            self.ocrWords = ocrWords
            self.pageSizePt = pageSizePt
            self.bedOriginPt = bedOriginPt
        }

        /// A born-digital page carried over as it was.
        public init(original: CopiedPage) {
            self.init(content: .original(original), dpi: 72)
        }

        public var naturalSizePt: (w: Double, h: Double) {
            switch content {
            case let .original(copied):
                return copied.sizePt
            case let .g4(s):
                return points(s.width, s.height)
            case let .jpegGray(_, w, h):
                return points(w, h)
            case let .gray4Flate(e):
                return points(e.width, e.height)
            }
        }

        private func points(_ w: Int, _ h: Int) -> (w: Double, h: Double) {
            (Double(w) / Double(dpi) * 72, Double(h) / Double(dpi) * 72)
        }
    }

    /// The marker stamped into every output's Info Producer and checked
    /// by PDFInspector for idempotency — single source of truth for both
    /// sides of that contract. A version suffix ("PaperPress 1.2") may be
    /// appended later; the inspector matches by prefix.
    public static let producerMarker = "PaperPress"

    /// Indirect objects by number (1-based); bodies filled in any order.
    private struct ObjectTable {
        var bodies: [Data] = []

        mutating func reserve() -> Int {
            bodies.append(Data())
            return bodies.count
        }

        mutating func add(_ body: Data) -> Int {
            bodies.append(body)
            return bodies.count
        }

        mutating func set(_ id: Int, _ body: Data) {
            bodies[id - 1] = body
        }
    }

    public static func build(
        pages: [Page], producer: String = PDFWriter.producerMarker
    ) throws -> Data {
        var table = ObjectTable()
        let catalogID = table.reserve()
        let pagesID = table.reserve()
        let fontID = table.reserve()
        // Objects copied from source pages, numbered on first use so
        // pages sharing a font or image share the one object.
        var copiedIDs: [CopiedPage.Key: Int] = [:]
        var pageIDs: [Int] = []

        for page in pages {
            let image: Data
            switch page.content {
            case let .original(copied):
                pageIDs.append(place(copied, parent: pagesID, in: &table, numbered: &copiedIDs))
                continue
            case let .g4(stream):
                // Empirically (ImageIO G4 + Preview): a min-is-black TIFF
                // stream needs BlackIs1 true to render upright.
                image = imageXObject(
                    "/Width \(stream.width)/Height \(stream.height)/ColorSpace/DeviceGray"
                        + "/BitsPerComponent 1/Filter/CCITTFaxDecode/DecodeParms<</K -1"
                        + "/Columns \(stream.width)/Rows \(stream.height)"
                        + "/BlackIs1 \(stream.minIsBlack ? "true" : "false")>>",
                    stream.data)
            case let .jpegGray(jpeg, w, h):
                image = imageXObject(
                    "/Width \(w)/Height \(h)/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/DCTDecode",
                    jpeg)
            case let .gray4Flate(e):
                image = imageXObject(
                    "/Width \(e.width)/Height \(e.height)/ColorSpace/DeviceGray/BitsPerComponent 4"
                        + "/Filter/FlateDecode/DecodeParms<</Predictor 15/Colors 1/BitsPerComponent 4"
                        + "/Columns \(e.width)>>",
                    e.data)
            }
            let (ptW, ptH) = page.naturalSizePt
            let boxW = max(page.pageSizePt?.w ?? ptW, ptW)
            let boxH = max(page.pageSizePt?.h ?? ptH, ptH)
            // Place the image at its physical position on the scanner bed
            // (clamped into the page box) so padded pages keep the original
            // layout. PDF origin is bottom-left; bed origin is top-left.
            let ox = min(page.bedOriginPt.x, boxW - ptW)
            let oyTop = min(page.bedOriginPt.y, boxH - ptH)
            let oy = boxH - ptH - oyTop

            let imgID = table.add(image)

            var content = "q \(fmt(ptW)) 0 0 \(fmt(ptH)) \(fmt(ox)) \(fmt(oy)) cm /Im0 Do Q"
            if !page.ocrWords.isEmpty {
                content += "\nBT 3 Tr"
                // One entry a word: its numbers are most of the layer's
                // bytes, so each word moves from the last (Td) by tenths
                // of a point, and scales in whole percent.
                var last = (x: 0.0, y: 0.0)
                for word in page.ocrWords {
                    let (text, glyphs) = winAnsiLiteral(word.text)
                    guard glyphs > 0 else { continue }
                    let boxW = word.box.width * ptW
                    let size = tenth(max(4, word.box.height * ptH))
                    // PDFKit highlights Helvetica from 0.23 em below its
                    // baseline to 0.77 above, so on a baseline that far up
                    // the box the highlight fills the box Vision drew round
                    // the ink (on the box's floor, it hung a quarter below).
                    let x = tenth(ox + word.box.minX * ptW)
                    let y = tenth(oy + word.box.minY * ptH + size * 0.23)
                    // Horizontal scale so the string spans the detected box.
                    let nominal = Double(glyphs) * size * 0.5
                    let tz = nominal > 0 ? boxW / nominal * 100 : 100
                    content += "\n/F1 \(real(size)) Tf \(Int(min(500, max(20, tz)).rounded())) Tz"
                    // The space after the word, past its box, keeps a reader
                    // from running neighbours together.
                    content += " \(real(tenth(x - last.x))) \(real(tenth(y - last.y))) Td (\(text) ) Tj"
                    last = (x, y)
                }
                content += "\nET"
            }
            // The text layer is most of a page's operators, and compresses.
            let stream = try Deflate.zlibData(Data(content.utf8))
            var cobj = Data("<</Length \(stream.count)/Filter/FlateDecode>>\nstream\n".utf8)
            cobj.append(stream)
            cobj.append(Data("\nendstream".utf8))
            let contentID = table.add(cobj)

            let fontRes = page.ocrWords.isEmpty ? "" : "/Font<</F1 \(fontID) 0 R>>"
            pageIDs.append(
                table.add(
                    Data(
                        """
                        <</Type/Page/Parent \(pagesID) 0 R/MediaBox[0 0 \(fmt(boxW)) \(fmt(boxH))]\
                        /Resources<</XObject<</Im0 \(imgID) 0 R>>\(fontRes)>>/Contents \(contentID) 0 R>>
                        """.utf8
                    )
                )
            )
        }

        table.set(catalogID, Data("<</Type/Catalog/Pages \(pagesID) 0 R>>".utf8))
        let kids = pageIDs.map { "\($0) 0 R" }.joined(separator: " ")
        table.set(pagesID, Data("<</Type/Pages/Kids[\(kids)]/Count \(pageIDs.count)>>".utf8))
        // WinAnsiEncoding so the OCR layer carries Latin-1 text (accents,
        // curly quotes, dashes), not just ASCII.
        table.set(
            fontID,
            Data("<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>".utf8)
        )
        // Document Info: the Producer marks output as already converted,
        // so re-analysing it yields a pass-through verdict (idempotency).
        let infoID = table.add(Data("<</Producer (\(winAnsiLiteral(producer).literal))>>".utf8))

        var out = Data("%PDF-1.4\n%".utf8)
        out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (i, body) in table.bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefStart = out.count
        out.append(Data("xref\n0 \(table.bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for off in offsets {
            let digits = String(off)
            let padded = String(repeating: "0", count: max(0, 10 - digits.count)) + digits
            out.append(Data("\(padded) 00000 n \n".utf8))
        }
        out.append(
            Data(
                "trailer\n<</Size \(table.bodies.count + 1)/Root \(catalogID) 0 R/Info \(infoID) 0 R>>\n"
                    .utf8
            )
        )
        out.append(Data("startxref\n\(xrefStart)\n%%EOF".utf8))
        return out
    }

    private static func imageXObject(_ dictionary: String, _ body: Data) -> Data {
        var img = Data("<</Type/XObject/Subtype/Image\(dictionary)/Length \(body.count)>>\nstream\n".utf8)
        img.append(body)
        img.append(Data("\nendstream".utf8))
        return img
    }

    // MARK: Copied pages

    /// Writes a copied page's objects not already in the file and returns
    /// the page object's number.
    private static func place(
        _ copied: CopiedPage, parent: Int, in table: inout ObjectTable,
        numbered ids: inout [CopiedPage.Key: Int]
    ) -> Int {
        var fresh: [(id: Int, body: CopiedPage.Body)] = []
        for (key, body) in copied.objects where ids[key] == nil {
            let id = table.reserve()
            ids[key] = id
            fresh.append((id, body))
        }
        for (id, body) in fresh {
            var out = Data()
            switch body {
            case let .dictionary(entries):
                out.append(Data("<<".utf8))
                if id == ids[copied.page] {
                    out.append(Data("/Parent \(parent) 0 R".utf8))
                }
                serialise(entries, ids, into: &out)
                out.append(Data(">>".utf8))
            case let .stream(entries, data):
                out.append(Data("<<".utf8))
                serialise(entries, ids, into: &out)
                out.append(Data("/Length \(data.count)>>\nstream\n".utf8))
                out.append(data)
                out.append(Data("\nendstream".utf8))
            }
            table.set(id, out)
        }
        return ids[copied.page] ?? 0
    }

    private static func serialise(
        _ entries: [CopiedPage.Entry], _ ids: [CopiedPage.Key: Int], into out: inout Data
    ) {
        for (key, value) in entries {
            out.append(name(key))
            out.append(0x20)
            serialise(value, ids, into: &out)
        }
    }

    private static func serialise(
        _ value: PDFObject, _ ids: [CopiedPage.Key: Int], into out: inout Data
    ) {
        switch value {
        case .null:
            out.append(Data("null".utf8))
        case let .bool(b):
            out.append(Data((b ? "true" : "false").utf8))
        case let .int(i):
            out.append(Data(String(i).utf8))
        case let .real(r):
            out.append(Data(real(r).utf8))
        case let .name(bytes):
            out.append(name(bytes))
        case let .string(bytes):
            // Hex: binary-safe whatever the bytes are.
            out.append(0x3C)
            for b in bytes {
                out.append(Data(String(format: "%02X", b).utf8))
            }
            out.append(0x3E)
        case let .array(items):
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                serialise(item, ids, into: &out)
            }
            out.append(0x5D)
        case let .ref(key):
            // Every copied object is in the page's closure; null is the
            // spec's meaning for a reference to a missing object anyway.
            if let id = ids[key] {
                out.append(Data("\(id) 0 R".utf8))
            } else {
                out.append(Data("null".utf8))
            }
        }
    }

    /// A PDF name: regular characters as themselves, the rest #-escaped.
    private static func name(_ bytes: [UInt8]) -> Data {
        var out = Data([0x2F])
        let delimiters = Set("()<>[]{}/%#".utf8)
        for b in bytes {
            if b > 0x20, b < 0x7F, !delimiters.contains(b) {
                out.append(b)
            } else {
                out.append(Data(String(format: "#%02X", b).utf8))
            }
        }
        return out
    }

    /// PDF reals have no exponent form.
    private static func real(_ r: Double) -> String {
        guard r.isFinite else { return "0" }
        var s = String(format: "%.6f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private static func tenth(_ d: Double) -> Double {
        (d * 10).rounded() / 10
    }

    private static func fmt(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    // MARK: Text

    /// WinAnsiEncoding's codes 0x80–0x9F, which (unlike the rest of
    /// Latin-1) don't share their Unicode code points.
    private static let winAnsiExtras: [Unicode.Scalar: UInt8] = [
        "€": 0x80, "‚": 0x82, "ƒ": 0x83, "„": 0x84, "…": 0x85, "†": 0x86, "‡": 0x87,
        "ˆ": 0x88, "‰": 0x89, "Š": 0x8A, "‹": 0x8B, "Œ": 0x8C, "Ž": 0x8E, "‘": 0x91,
        "’": 0x92, "“": 0x93, "”": 0x94, "•": 0x95, "–": 0x96, "—": 0x97, "˜": 0x98,
        "™": 0x99, "š": 0x9A, "›": 0x9B, "œ": 0x9C, "ž": 0x9E, "Ÿ": 0x9F,
    ]

    /// A string literal body for the WinAnsi-encoded font: ASCII as
    /// itself, other WinAnsi characters as octal escapes (so the content
    /// stream stays ASCII), and anything outside WinAnsi as a space.
    /// `glyphs` counts characters before escaping, for the width maths.
    static func winAnsiLiteral(_ s: String) -> (literal: String, glyphs: Int) {
        var out = ""
        var glyphs = 0
        for ch in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            glyphs += 1
            switch ch {
            case "(": out += "\\("
            case ")": out += "\\)"
            case "\\": out += "\\\\"
            case let c where c.value >= 0x20 && c.value < 0x7F:
                out.unicodeScalars.append(c)
            case let c where c.value >= 0xA0 && c.value <= 0xFF:
                out += octal(UInt8(c.value))
            case let c:
                if let code = winAnsiExtras[c] {
                    out += octal(code)
                } else {
                    out += " "
                }
            }
        }
        return (out, glyphs)
    }

    private static func octal(_ b: UInt8) -> String {
        let digits = String(b, radix: 8)
        return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
    }
}
