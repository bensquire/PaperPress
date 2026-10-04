import CoreGraphics
import Foundation

/// A PDF value as PDFWriter serialises it. Names and strings keep their
/// exact bytes; references name a copied object by its source identity,
/// so PDFWriter can number it when it splices the page into a file.
public indirect enum PDFObject: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name([UInt8])
    case string([UInt8])
    case array([PDFObject])
    case ref(CopiedPage.Key)
}

/// A born-digital page lifted out of its source PDF object for object, so
/// its vector text, fonts and images reach the output unrasterised — a
/// mixed file's real pages stay as good as they were.
///
/// Every dictionary and stream becomes an indirect object keyed by its
/// identity in the source. That handles shared objects (a font used by
/// several pages is written once) and cycles alike. CGPDF hands back
/// streams decoded, so each is re-encoded: Flate for raw data, and JPEG
/// and JPEG 2000 data kept as it came.
public struct CopiedPage: Sendable {
    /// Identity of an object in its source document.
    public struct Key: Hashable, Sendable {
        let document: ObjectIdentifier
        let address: Int
    }

    public typealias Entry = (key: [UInt8], value: PDFObject)

    public enum Body: Sendable {
        case dictionary([Entry])
        case stream([Entry], Data)
    }

    /// The page dictionary's key; its body has no /Parent, which
    /// PDFWriter supplies.
    public let page: Key
    /// The page and every object it reaches, page first.
    public let objects: [(key: Key, body: Body)]
    /// Displayed size in points (the crop box, rotation applied).
    public let sizePt: (w: Double, h: Double)

    /// One page on its own. Several pages of one document go through a shared
    /// `PageCopier`, so the objects they share are copied once.
    public init(_ page: CGPDFPage) throws {
        self = try PageCopier().copy(page)
    }

    init(page: Key, objects: [(key: Key, body: Body)], sizePt: (w: Double, h: Double)) {
        self.page = page
        self.objects = objects
        self.sizePt = sizePt
    }
}

/// Copies born-digital pages out of one source document. An object pages
/// share — a font set on every page — is decoded and recompressed once, and
/// each later page refers to it; PDFWriter then writes it once.
public final class PageCopier {
    /// Every object copied so far, and the objects each refers to.
    private var copied: [CopiedPage.Key: (body: CopiedPage.Body, refs: [CopiedPage.Key])] = [:]

    /// Page entries worth carrying: what draws the page. The boxes and
    /// rotation are written from their resolved (possibly inherited)
    /// values. Annotations, structure and thread entries are left
    /// behind: they point back into the source's page tree.
    static let pageKeys = ["Contents", "Group", "UserUnit"]

    public init() {}

    /// Copies one page. A page that fails leaves nothing behind, so the
    /// caller can rasterise it instead and go on copying the rest.
    public func copy(_ page: CGPDFPage) throws -> CopiedPage {
        guard let dict = page.dictionary, let document = page.document else {
            throw PressError.scanFailed("Page \(page.pageNumber) has no dictionary")
        }
        var copier = Copier(document: ObjectIdentifier(document), earlier: copied)
        let key = copier.key(dict.rawValue)
        copier.reserve(key)

        let media = page.getBoxRect(.mediaBox)
        var entries: [CopiedPage.Entry] = [
            (Array("Type".utf8), .name(Array("Page".utf8))),
            (Array("MediaBox".utf8), Copier.rect(media)),
        ]
        let crop = page.getBoxRect(.cropBox)
        if crop != media {
            entries.append((Array("CropBox".utf8), Copier.rect(crop)))
        }
        if page.rotationAngle % 360 != 0 {
            entries.append((Array("Rotate".utf8), .int(Int(page.rotationAngle))))
        }
        if let resources = Copier.inherited("Resources", from: dict) {
            entries.append((Array("Resources".utf8), try copier.value(resources, depth: 0)))
        }
        for name in Self.pageKeys {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dict, name, &object), let object {
                entries.append((Array(name.utf8), try copier.value(object, depth: 0)))
            }
        }
        copier.bodies[key] = .dictionary(entries)

        // This page's own objects, then everything it reached that an earlier
        // page already copied, with whatever those reach in turn.
        var objects: [(key: CopiedPage.Key, body: CopiedPage.Body)] = try copier.order.map { key in
            guard let body = copier.bodies[key] else {
                throw PressError.scanFailed("Unfinished object while copying a page")
            }
            return (key, body)
        }
        for (key, body) in objects {
            copied[key] = (body, body.refs)
        }
        var seen = Set(copier.order)
        var stack = copier.reused
        while let reused = stack.popLast() {
            guard seen.insert(reused).inserted, let entry = copied[reused] else { continue }
            objects.append((reused, entry.body))
            stack += entry.refs
        }
        let size = page.visibleSize
        return CopiedPage(page: key, objects: objects, sizePt: (Double(size.width), Double(size.height)))
    }
}

extension CopiedPage.Body {
    /// The objects this one refers to.
    var refs: [CopiedPage.Key] {
        var keys: [CopiedPage.Key] = []
        func collect(_ value: PDFObject) {
            switch value {
            case .ref(let key): keys.append(key)
            case .array(let items): items.forEach(collect)
            default: break
            }
        }
        switch self {
        case .dictionary(let entries), .stream(let entries, _):
            entries.forEach { collect($0.value) }
        }
        return keys
    }
}

private struct Copier {
    let document: ObjectIdentifier
    /// Objects an earlier page of the same document already copied.
    let earlier: [CopiedPage.Key: (body: CopiedPage.Body, refs: [CopiedPage.Key])]
    var bodies: [CopiedPage.Key: CopiedPage.Body] = [:]
    var order: [CopiedPage.Key] = []
    var reserved: Set<CopiedPage.Key> = []
    /// Known objects this page refers to.
    var reused: [CopiedPage.Key] = []

    /// Nesting beyond this is a malformed (or hostile) file; the caller
    /// falls back to rasterising the page.
    static let maxDepth = 64

    /// Stream dictionary entries describing the source encoding, replaced
    /// by the re-encoded stream's own.
    static let codingKeys: Set<[UInt8]> = Set(
        ["Length", "Filter", "DecodeParms", "DL", "F", "FFilter", "FDecodeParms"].map {
            Array($0.utf8)
        })

    func key(_ pointer: OpaquePointer) -> CopiedPage.Key {
        CopiedPage.Key(document: document, address: Int(bitPattern: pointer))
    }

    /// Claims a key before its body is built, so a reference back to it
    /// from inside (a cycle) becomes a reference, not a recursion.
    mutating func reserve(_ key: CopiedPage.Key) {
        order.append(key)
        reserved.insert(key)
    }

    /// Whether `key` is already copied — by this page or an earlier one — so
    /// a reference to it is all that's needed.
    mutating func known(_ key: CopiedPage.Key) -> Bool {
        if reserved.contains(key) { return true }
        guard earlier[key] != nil else { return false }
        reused.append(key)
        return true
    }

    static func rect(_ r: CGRect) -> PDFObject {
        .array([r.minX, r.minY, r.maxX, r.maxY].map { .real(Double($0)) })
    }

    /// A page attribute PDF lets pages inherit from their ancestors.
    static func inherited(_ name: String, from dict: CGPDFDictionaryRef) -> CGPDFObjectRef? {
        var node: CGPDFDictionaryRef? = dict
        var hops = 0
        while let current = node, hops < maxDepth {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(current, name, &object), let object {
                return object
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            hops += 1
        }
        return nil
    }

    mutating func value(_ object: CGPDFObjectRef, depth: Int) throws -> PDFObject {
        guard depth < Self.maxDepth else {
            throw PressError.scanFailed("Page objects nest too deeply to copy")
        }
        switch CGPDFObjectGetType(object) {
        case .null:
            return .null
        case .boolean:
            var v: CGPDFBoolean = 0
            _ = CGPDFObjectGetValue(object, .boolean, &v)
            return .bool(v != 0)
        case .integer:
            var v: CGPDFInteger = 0
            _ = CGPDFObjectGetValue(object, .integer, &v)
            return .int(v)
        case .real:
            var v: CGPDFReal = 0
            _ = CGPDFObjectGetValue(object, .real, &v)
            return .real(Double(v))
        case .name:
            var v: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &v), let v else { return .null }
            return .name(Self.bytes(v))
        case .string:
            var v: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &v), let v else { return .null }
            let count = CGPDFStringGetLength(v)
            guard let base = CGPDFStringGetBytePtr(v), count > 0 else { return .string([]) }
            return .string(Array(UnsafeBufferPointer(start: base, count: count)))
        case .array:
            var v: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &v), let v else { return .null }
            var items: [PDFObject] = []
            for i in 0..<CGPDFArrayGetCount(v) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(v, i, &item), let item {
                    items.append(try value(item, depth: depth + 1))
                } else {
                    items.append(.null)
                }
            }
            return .array(items)
        case .dictionary:
            var v: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &v), let v else { return .null }
            return try dictionary(v, depth: depth)
        case .stream:
            var v: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &v), let v else { return .null }
            return try stream(v, depth: depth)
        @unknown default:
            return .null
        }
    }

    private mutating func dictionary(_ d: CGPDFDictionaryRef, depth: Int) throws -> PDFObject {
        let key = key(d.rawValue)
        if known(key) { return .ref(key) }
        // Another page (a link target, an annotation's back-pointer)
        // would drag the source's whole page tree in after it.
        var type: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(d, "Type", &type), let type {
            let name = String(cString: type)
            if name == "Page" || name == "Pages" { return .null }
        }
        reserve(key)
        bodies[key] = .dictionary(try entries(of: d, skipping: [], depth: depth))
        return .ref(key)
    }

    private mutating func stream(_ s: CGPDFStreamRef, depth: Int) throws -> PDFObject {
        let key = key(s.rawValue)
        if known(key) { return .ref(key) }
        reserve(key)
        guard let dict = CGPDFStreamGetDictionary(s) else {
            throw PressError.scanFailed("Stream without a dictionary")
        }
        var format = CGPDFDataFormat.raw
        guard let decoded = CGPDFStreamCopyData(s, &format) as Data? else {
            throw PressError.scanFailed("Stream can't be decoded")
        }
        var entries = try entries(of: dict, skipping: Self.codingKeys, depth: depth)
        let data: Data
        let filter: String
        switch format {
        case .raw:
            data = try Deflate.zlibData(decoded)
            filter = "FlateDecode"
        case .jpegEncoded:
            data = decoded
            filter = "DCTDecode"
        case .JPEG2000:
            data = decoded
            filter = "JPXDecode"
        @unknown default:
            throw PressError.scanFailed("Stream in an unknown format")
        }
        entries.append((Array("Filter".utf8), .name(Array(filter.utf8))))
        bodies[key] = .stream(entries, data)
        return .ref(key)
    }

    private mutating func entries(
        of d: CGPDFDictionaryRef, skipping: Set<[UInt8]>, depth: Int
    ) throws -> [CopiedPage.Entry] {
        var raw: [([UInt8], CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(
            d,
            { name, object, _ in
                raw.append((Self.bytes(name), object))
                return true
            }, nil)
        var out: [CopiedPage.Entry] = []
        for (name, object) in raw where !skipping.contains(name) {
            out.append((name, try value(object, depth: depth + 1)))
        }
        return out
    }

    static func bytes(_ c: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: c, count: strlen(c))).map { UInt8(bitPattern: $0) }
    }
}
