// RinNotch — Bộ nhớ tạm: lịch sử, ghim (giữ qua lần mở app), tìm kiếm, app nguồn, nhận dạng
// link / màu / code, sửa nhanh chữ, sao lưu và nhập.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LinkPresentation
import ImageIO

// MARK: - Dữ liệu

enum ClipKind {
    case text(String)
    case files([URL])
    case image(ClipImage)
}

/// Ảnh trong Bộ nhớ tạm. RAM chỉ giữ ảnh nhỏ (tối đa 480 px) để hiện thẻ; ảnh gốc ghi ra file tạm dạng PNG
/// (mục riêng tư thì giữ dữ liệu nén trong RAM, không ghi ra ổ). Ảnh chụp màn hình 5K giải nén ~60 MB,
/// giữ nguyên như trước thì 50 mục có thể ngốn vài GB.
final class ClipImage: @unchecked Sendable {
    let thumb: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    private let lock = NSLock()
    private var file: URL?
    private var data: Data?
    /// File tạm là của mục này: không còn ai giữ mục thì xoá file.
    private let ownsFile: Bool

    static let cacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.phuocrin.rinnotch/clips", isDirectory: true)

    /// Lịch sử không giữ qua lần mở app: dọn file tạm cũ lúc khởi động.
    static func clearCache() { try? FileManager.default.removeItem(at: cacheDir) }

    private init(thumb: NSImage, w: Int, h: Int, file: URL?, data: Data?, ownsFile: Bool) {
        self.thumb = thumb
        pixelWidth = w
        pixelHeight = h
        self.file = file
        self.data = data
        self.ownsFile = ownsFile
    }

    deinit {
        if ownsFile, let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Từ dữ liệu ảnh (bộ nhớ tạm, bản giải mã). `persist`: ghi PNG ra file tạm ở luồng nền rồi nhả dữ liệu khỏi RAM.
    static func make(data: Data, persist: Bool) -> ClipImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let t = thumbnail(src) else { return nil }
        let ci = ClipImage(thumb: t.0, w: t.1, h: t.2, file: nil, data: data, ownsFile: persist)
        if persist { ci.persistInBackground() }
        return ci
    }

    /// Ảnh của mục ghim (file nằm sẵn trong thư mục ghim, không phải file tạm).
    static func make(file: URL) -> ClipImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let t = thumbnail(src) else { return nil }
        return ClipImage(thumb: t.0, w: t.1, h: t.2, file: file, data: nil, ownsFile: false)
    }

    private static func thumbnail(_ src: CGImageSource) -> (NSImage, Int, Int)? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
        return (NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)), w, h)
    }

    private func persistInBackground() {
        let name = UUID().uuidString + ".png"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let d = self.data; self.lock.unlock()
            guard let d, let png = Self.png(from: d) else { return }
            try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
            let url = Self.cacheDir.appendingPathComponent(name)
            guard (try? png.write(to: url)) != nil else { return }
            self.lock.lock(); self.file = url; self.data = nil; self.lock.unlock()
        }
    }

    /// Đổi dữ liệu ảnh bất kỳ (TIFF, JPEG…) thành PNG; sẵn PNG thì giữ nguyên.
    private static func png(from d: Data) -> Data? {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return d }
        guard let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Ảnh gốc dạng PNG (đọc từ file tạm, chỉ khi cần: chép lại, ghim, cất Riêng tư).
    func pngData() -> Data? {
        lock.lock(); let f = file, d = data; lock.unlock()
        if let f, let fd = try? Data(contentsOf: f) { return fd }
        if let d { return Self.png(from: d) }
        return nil
    }

    /// Ghi ảnh gốc ra một file (ghim): có sẵn file thì chép file, khỏi mã hoá lại.
    func write(to url: URL) -> Bool {
        lock.lock(); let f = file; lock.unlock()
        if let f, (try? FileManager.default.copyItem(at: f, to: url)) != nil { return true }
        guard let d = pngData() else { return false }
        return (try? d.write(to: url)) != nil
    }

    /// Đặt ảnh gốc lên bộ nhớ tạm: PNG kèm TIFF (vài app cũ chỉ đọc TIFF).
    func put(on pb: NSPasteboard) {
        guard let png = pngData() else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation(using: .lzw, factor: 0) {
            item.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([item])
    }
}

enum ClipCategory: String, CaseIterable {
    case text, link, color, code, file, image

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .color: return "paintpalette"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .file: return "doc"
        case .image: return "photo"
        }
    }

    /// Từ khoá lọc khi tìm: @link, @image… (có thêm tên tiếng Việt không dấu).
    var tokens: [String] {
        switch self {
        case .text: return ["text", "chu"]
        case .link: return ["link", "url", "lienket"]
        case .color: return ["color", "mau"]
        case .code: return ["code", "ma"]
        case .file: return ["file", "tep"]
        case .image: return ["image", "img", "anh", "hinh"]
        }
    }
}

struct ClipItem: Identifiable {
    var id = UUID()
    var kind: ClipKind
    var date = Date()
    var sourceID: String?
    var sourceName: String?
    var linkTitle: String?
    /// Tên người dùng tự đặt (chuột phải → Đặt tên), tìm được bằng tên này.
    var name: String?
    let category: ClipCategory

    init(kind: ClipKind, date: Date = Date(), sourceID: String? = nil, sourceName: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.date = date
        self.sourceID = sourceID
        self.sourceName = sourceName
        switch kind {
        case .files: category = .file
        case .image: category = .image
        case .text(let s):
            if ClipParse.color(s) != nil { category = .color }
            else if ClipParse.link(s) != nil { category = .link }
            else if ClipParse.isCode(s) { category = .code }
            else { category = .text }
        }
    }

    var text: String? {
        if case .text(let s) = kind { return s }
        return nil
    }

    var preview: String {
        switch kind {
        case .text(let s):
            return s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file: \(urls[0].lastPathComponent)…"
        case .image(let img):
            let w = img.pixelWidth, h = img.pixelHeight
            return w > 0 ? "Hình ảnh \(w) × \(h)" : "Hình ảnh"
        }
    }

    var symbol: String { category.symbol }

    /// Cùng nội dung (để không lưu trùng).
    func sameContent(_ o: ClipItem) -> Bool {
        switch (kind, o.kind) {
        case (.text(let a), .text(let b)): return a == b
        case (.files(let a), .files(let b)): return a == b
        default: return false
        }
    }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0 == " " }).map { ClipParse.fold(String($0)) }
        guard !words.isEmpty else { return true }
        let hay = ClipParse.fold([name ?? "", preview, text ?? "", linkTitle ?? "", sourceName ?? ""].joined(separator: " "))
        let app = ClipParse.fold(sourceName ?? "")
        for w in words {
            if w.hasPrefix("@") {
                let tag = String(w.dropFirst())
                guard !tag.isEmpty else { continue }
                if let c = ClipCategory.allCases.first(where: { $0.tokens.contains(tag) }) {
                    if category != c { return false }
                } else if !app.contains(tag) {
                    return false
                }
            } else if !hay.contains(w) {
                return false
            }
        }
        return true
    }
}

enum ClipFilter: String { case recent, pinned, vault }

// MARK: - Nhận dạng

enum ClipParse {
    /// Chữ thường, bỏ dấu (tìm "viet" ra "Việt").
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func link(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count < 2000, !t.contains(where: { $0.isWhitespace }) else { return nil }
        if t.lowercased().hasPrefix("www.") { return URL(string: "https://" + t) }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return nil }
        return u
    }

    /// Mã màu: #RGB, #RRGGBB, #RRGGBBAA, rgb(…), rgba(…), hsl(…).
    static func color(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count <= 40 else { return nil }
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            let full = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard let v = UInt64(full, radix: 16) else { return nil }
            if full.count == 8 {
                return NSColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                               blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
            }
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        func numbers(_ prefix: String) -> [Double]? {
            guard t.hasPrefix(prefix), t.hasSuffix(")"), let open = t.firstIndex(of: "(") else { return nil }
            let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "% ")) }
            let vals = parts.compactMap { Double($0) }
            return vals.count == parts.count ? vals : nil
        }
        if let v = numbers("rgb"), v.count >= 3, v.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) {
            return NSColor(srgbRed: v[0] / 255, green: v[1] / 255, blue: v[2] / 255, alpha: v.count > 3 ? min(max(v[3], 0), 1) : 1)
        }
        if let v = numbers("hsl"), v.count >= 3 {
            let h = v[0] / 360, s = v[1] / 100, l = v[2] / 100
            let b = l + s * min(l, 1 - l)
            let sv = b == 0 ? 0 : 2 * (1 - l / b)
            return NSColor(hue: CGFloat(h), saturation: CGFloat(sv), brightness: CGFloat(b), alpha: v.count > 3 ? min(max(v[3], 0), 1) : 1)
        }
        return nil
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }

    static func rgb(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return "rgb(\(Int(round(s.redComponent * 255))), \(Int(round(s.greenComponent * 255))), \(Int(round(s.blueComponent * 255))))"
    }

    static func hsl(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        let r = Double(s.redComponent), g = Double(s.greenComponent), b = Double(s.blueComponent)
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        var h = 0.0, sat = 0.0
        if mx != mn {
            let d = mx - mn
            sat = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
        }
        return "hsl(\(Int(round(h * 360))), \(Int(round(sat * 100)))%, \(Int(round(l * 100)))%)"
    }

    static let keywords: Set<String> = [
        "func", "let", "var", "const", "if", "else", "for", "while", "return", "import", "class", "struct", "enum",
        "def", "function", "async", "await", "try", "catch", "new", "true", "false", "nil", "null", "self", "this",
        "public", "private", "static", "switch", "case", "guard", "in", "of", "from", "export", "default", "extends",
        "interface", "type", "void", "int", "string", "bool", "echo", "fi", "then", "do", "done", "print",
    ]

    static func isCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8, t.count < 20000 else { return false }
        var score = 0
        let lines = t.split(separator: "\n")
        if lines.count >= 2 && t.contains("{") && t.contains("}") { score += 2 }
        if t.contains("=>") || t.contains("->") || t.contains("::") || t.contains("!=") || t.contains("==") { score += 1 }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix(";") }) { score += 1 }
        if t.contains("</") || t.hasPrefix("<!") || t.hasPrefix("<?") { score += 2 }
        if t.hasPrefix("$ ") || t.hasPrefix("sudo ") || t.hasPrefix("git ") || t.hasPrefix("npm ") || t.hasPrefix("cd ") { score += 2 }
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "_" }).prefix(80)
        let kw = words.filter { keywords.contains(String($0)) }.count
        if kw >= 2 { score += 1 }
        if t.contains("(") && t.contains(")") && (t.contains("=") || t.contains(".")) { score += 1 }
        // Câu văn thường có nhiều dấu câu tự nhiên, ít ký hiệu code.
        let symbols = t.filter { "{}[]();=<>_$#|&".contains($0) }.count
        if Double(symbols) / Double(t.count) > 0.04 { score += 1 }
        return score >= 3
    }

    /// Tô màu code đơn giản (từ khoá, chuỗi, số, chú thích) cho dòng xem trước.
    static func highlight(_ s: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(s)
        var i = 0
        func push(_ str: String, _ color: Color) {
            var a = AttributedString(str)
            a.foregroundColor = color
            out.append(a)
        }
        let kwColor = Color(red: 1, green: 0.48, blue: 0.7)
        let strColor = Color(red: 1, green: 0.62, blue: 0.4)
        let numColor = Color(red: 0.85, green: 0.78, blue: 0.45)
        let comColor = Color.white.opacity(0.4)
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" || c == "#" && (i == 0 || chars[i - 1] == " ") {
                push(String(chars[i...]), comColor)
                break
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != c { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                push(String(chars[i..<j]), strColor)
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let w = String(chars[i..<j])
                push(w, keywords.contains(w) ? kwColor : Color.white.opacity(0.92))
                i = j
                continue
            }
            if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                push(String(chars[i..<j]), numColor)
                i = j
                continue
            }
            push(String(c), Color.white.opacity(0.7))
            i += 1
        }
        return out
    }
}

// MARK: - Sửa nhanh chữ

enum TextTransform: String, CaseIterable, Identifiable {
    case upper, lower, capitalize, sentence, noDiacritics, squeeze, removeBlank, joinLines, sortLines, dedupeLines
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "VIẾT HOA HẾT"
        case .lower: return "viết thường hết"
        case .capitalize: return "Viết Hoa Đầu Mỗi Từ"
        case .sentence: return "Viết hoa đầu câu"
        case .noDiacritics: return "Bỏ dấu tiếng Việt"
        case .squeeze: return "Bỏ khoảng trắng thừa"
        case .removeBlank: return "Bỏ dòng trống"
        case .joinLines: return "Nối thành một dòng"
        case .sortLines: return "Sắp xếp dòng A → Z"
        case .dedupeLines: return "Xoá dòng trùng"
        }
    }

    func apply(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines)
        switch self {
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .capitalize: return s.capitalized
        case .sentence:
            var out = ""
            var cap = true
            for ch in s.lowercased() {
                if cap, ch.isLetter { out += ch.uppercased(); cap = false } else { out.append(ch) }
                if ".!?\n".contains(ch) { cap = true }
            }
            return out
        case .noDiacritics:
            return s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi"))
        case .squeeze:
            return lines.map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeBlank:
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .joinLines:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .sortLines:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
    }
}

// MARK: - Lưu ghim và sao lưu

struct StoredClip: Codable {
    var id: UUID
    var date: Date
    var sourceID: String?
    var sourceName: String?
    var linkTitle: String?
    var name: String?
    var type: String
    var text: String?
    var paths: [String]?
    var imageFile: String?
    var imageData: Data?
}

struct ClipBackup: Codable {
    var app = "RinNotch"
    var format = 1
    var pins: [StoredClip]
    var history: [StoredClip]
}

@MainActor
enum ClipStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RinNotch/Clipboard", isDirectory: true)
    }
    private static var imagesDir: URL { dir.appendingPathComponent("images", isDirectory: true) }
    private static var pinsFile: URL { dir.appendingPathComponent("pins.json") }

    static func encode(_ c: ClipItem, inlineImage: Bool) -> StoredClip? {
        var s = StoredClip(id: c.id, date: c.date, sourceID: c.sourceID, sourceName: c.sourceName, linkTitle: c.linkTitle, name: c.name, type: "text")
        switch c.kind {
        case .text(let t): s.text = t
        case .files(let urls): s.type = "files"; s.paths = urls.map(\.path)
        case .image(let img):
            s.type = "image"
            if inlineImage {
                guard let d = img.pngData() else { return nil }
                s.imageData = d
            } else {
                let name = c.id.uuidString + ".png"
                let url = imagesDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                    guard img.write(to: url) else { return nil }
                }
                s.imageFile = name
            }
        }
        return s
    }

    /// `persistImages`: ảnh nằm sẵn trong dữ liệu thì ghi ra file tạm (sao lưu); mục riêng tư thì không ghi ra ổ.
    static func decode(_ s: StoredClip, persistImages: Bool = true) -> ClipItem? {
        let kind: ClipKind
        switch s.type {
        case "text":
            guard let t = s.text else { return nil }
            kind = .text(t)
        case "files":
            guard let p = s.paths, !p.isEmpty else { return nil }
            kind = .files(p.map { URL(fileURLWithPath: $0) })
        case "image":
            if let d = s.imageData, let img = ClipImage.make(data: d, persist: persistImages) { kind = .image(img) }
            else if let f = s.imageFile, let img = ClipImage.make(file: imagesDir.appendingPathComponent(f)) { kind = .image(img) }
            else { return nil }
        default: return nil
        }
        var item = ClipItem(kind: kind, date: s.date, sourceID: s.sourceID, sourceName: s.sourceName, id: s.id)
        item.linkTitle = s.linkTitle
        item.name = s.name
        return item
    }

    /// File ghim đọc không được lúc mở app: không dọn ảnh, tránh xoá mất ảnh của mục ghim cũ.
    private static var loadFailed = false

    static func savePins(_ pins: [ClipItem]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = pins.compactMap { encode($0, inlineImage: false) }
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: pinsFile, options: .atomic) }
        guard !loadFailed else { return }
        // Dọn ảnh của mục đã bỏ ghim.
        let keep = Set(stored.compactMap(\.imageFile))
        if let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) {
            for f in files where !keep.contains(f) { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f)) }
        }
    }

    static func loadPins() -> [ClipItem] {
        guard let data = try? Data(contentsOf: pinsFile) else { return [] }
        guard let list = try? JSONDecoder().decode([StoredClip].self, from: data) else {
            // Giữ lại file hỏng để còn cứu, không ghi đè.
            loadFailed = true
            let bad = dir.appendingPathComponent("pins.bad-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: pinsFile, to: bad)
            Diag.log("File ghim đọc không được, đã đổi tên thành \(bad.lastPathComponent)")
            return []
        }
        return list.compactMap { decode($0) }
    }

    /// Xuất ghim + lịch sử ra một file .rinnotchclip (ảnh nằm luôn trong file).
    static func exportBackup(_ m: NotchModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RinNotch bo nho tam.rinnotchclip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let b = ClipBackup(pins: m.pins.compactMap { encode($0, inlineImage: true) },
                           history: m.clips.compactMap { encode($0, inlineImage: true) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(b) { try? data.write(to: url, options: .atomic) }
    }

    /// Nhập file sao lưu: gộp vào, bỏ mục trùng. Trả về số mục đã thêm.
    @discardableResult
    static func importBackup(_ m: NotchModel) -> Int? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(ClipBackup.self, from: data) else { return nil }
        var added = 0
        for s in b.pins {
            guard let c = ClipStore.decode(s), !m.pins.contains(where: { $0.id == c.id || $0.sameContent(c) }) else { continue }
            m.pins.append(c)
            added += 1
        }
        for s in b.history {
            guard let c = ClipStore.decode(s), !m.clips.contains(where: { $0.id == c.id || $0.sameContent(c) }) else { continue }
            m.clips.append(c)
            added += 1
        }
        m.clips.sort { $0.date > $1.date }
        if m.clips.count > Prefs.clipLimit { m.clips.removeLast(m.clips.count - Prefs.clipLimit) }
        savePins(m.pins)
        return added
    }
}

// MARK: - Theo dõi bộ nhớ tạm

@MainActor
final class ClipboardWatcher {
    static var shared: ClipboardWatcher?
    private let m: NotchModel
    private var last = NSPasteboard.general.changeCount
    private var ignored = -1
    private var pausedUntil: Date?
    private var timer: Timer?

    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    init(model: NotchModel) {
        m = model
        ClipImage.clearCache()
        m.pins = ClipStore.loadPins()
        // Bộ nhớ tạm không có thông báo khi đổi, phải hỏi số đếm (rất nhẹ). Cho phép lệch để macOS gom việc.
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.2
    }

    func ignore(_ count: Int) {
        ignored = count
        last = count
    }

    /// Tạm không ghi (lúc Dịch nhanh mượn bộ nhớ tạm để lấy chữ đang bôi đen).
    func pause(seconds: Double) {
        pausedUntil = Date().addingTimeInterval(seconds)
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        if pb.changeCount == ignored { return }
        if let p = pausedUntil, Date() < p { return }
        let types = (pb.types ?? []).map(\.rawValue)
        if types.contains(where: { Self.skipTypes.contains($0) }) { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, Prefs.clipExcluded.contains(id) { return }

        var kind: ClipKind?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            kind = .files(urls)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .text(String(s.prefix(20000)))
        } else {
            // Đọc thẳng dữ liệu ảnh (ưu tiên PNG) rồi làm ảnh nhỏ, không giải nén cả ảnh gốc vào RAM.
            let imgTypes = (pb.types ?? []).filter { UTType($0.rawValue)?.conforms(to: .image) == true }
            if let t = imgTypes.first(where: { $0 == .png }) ?? imgTypes.first(where: { $0 == .tiff }) ?? imgTypes.first,
               let d = pb.data(forType: t), let img = ClipImage.make(data: d, persist: true) {
                kind = .image(img)
            }
        }
        guard let kind else { return }
        let item = ClipItem(kind: kind, sourceID: front?.bundleIdentifier, sourceName: front?.localizedName)
        add(item)
        PasteStack.shared.collect(item)
        CopyToast.shared.show(item, model: m)
    }

    /// Hỏi bộ nhớ tạm ngay, không chờ nhịp 0,6 giây (Copy liên tục cần mục vừa chép trước khi ⌘V).
    func checkNow() { poll() }

    /// Đặt một mục vào bộ nhớ tạm mà không ghi thêm vào lịch sử, không đổi thứ tự (Copy liên tục dán lần lượt).
    func writeQuietly(_ item: ClipItem, concealed: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .files(let urls): pb.writeObjects(urls as [NSURL])
        case .image(let img): img.put(on: pb)
        }
        // Cờ quy ước của các trình quản lý bộ nhớ tạm: "đừng ghi lại mục này".
        if concealed { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        ignore(pb.changeCount)
    }

    /// Đưa một mục (vừa lấy ra khỏi Riêng tư) về đầu lịch sử.
    func reinsert(_ item: ClipItem) { add(item) }

    private func add(_ item: ClipItem) {
        m.clips.removeAll { $0.sameContent(item) }
        m.clips.insert(item, at: 0)
        let limit = Prefs.clipLimit
        if m.clips.count > limit { m.clips.removeLast(m.clips.count - limit) }
        if item.category == .link { fetchTitle(item) }
    }

    /// RinNotch tự chép chữ (mã màu, chữ đã sửa, bản dịch): đưa vào bộ nhớ tạm và lịch sử luôn.
    func copyText(_ s: String, source: String = "RinNotch") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        ignore(pb.changeCount)
        add(ClipItem(kind: .text(s), sourceID: Bundle.main.bundleIdentifier, sourceName: source))
        flash(m.clips.first?.id)
    }

    private func flash(_ id: UUID?) {
        m.clipFlash = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.m.clipFlash == id { self.m.clipFlash = nil }
            }
        }
    }

    func restore(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .files(let urls): pb.writeObjects(urls as [NSURL])
        case .image(let img): img.put(on: pb)
        }
        ignore(pb.changeCount)
        if let i = m.clips.firstIndex(where: { $0.id == item.id }) {
            let it = m.clips.remove(at: i)
            m.clips.insert(it, at: 0)
        }
        flash(item.id)
    }

    func isPinned(_ item: ClipItem) -> Bool { m.pins.contains { $0.id == item.id || $0.sameContent(item) } }

    func togglePin(_ item: ClipItem) {
        if let i = m.pins.firstIndex(where: { $0.id == item.id || $0.sameContent(item) }) {
            m.pins.remove(at: i)
        } else {
            m.pins.insert(item, at: 0)
        }
        ClipStore.savePins(m.pins)
    }

    func remove(_ item: ClipItem) {
        m.clips.removeAll { $0.id == item.id }
        if m.pins.contains(where: { $0.id == item.id }) {
            m.pins.removeAll { $0.id == item.id }
            ClipStore.savePins(m.pins)
        }
    }

    func clearHistory() { m.clips.removeAll() }

    /// Bỏ mọi bản cùng nội dung khỏi lịch sử và Ghim (dùng khi cất vào Riêng tư).
    func purge(_ item: ClipItem) {
        m.clips.removeAll { $0.id == item.id || $0.sameContent(item) }
        if m.pins.contains(where: { $0.id == item.id || $0.sameContent(item) }) {
            m.pins.removeAll { $0.id == item.id || $0.sameContent(item) }
            ClipStore.savePins(m.pins)
        }
    }

    /// Đặt tên cho một mục (nil = bỏ tên). Mục đã ghim thì lưu luôn.
    func setName(_ item: ClipItem, _ name: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (n?.isEmpty ?? true) ? nil : n
        for i in m.clips.indices where m.clips[i].id == item.id || m.clips[i].sameContent(item) { m.clips[i].name = value }
        var pinChanged = false
        for i in m.pins.indices where m.pins[i].id == item.id || m.pins[i].sameContent(item) {
            m.pins[i].name = value
            pinChanged = true
        }
        if pinChanged { ClipStore.savePins(m.pins) }
    }

    /// Link có mã riêng (đăng nhập một lần, đặt lại mật khẩu, huỷ đăng ký…) mà mở thử là có thể mất hiệu lực
    /// hoặc làm luôn việc đó: không mở.
    static func safeToPreview(_ url: URL) -> Bool {
        guard url.query == nil, url.fragment == nil else { return false }
        let path = url.path.lowercased()
        let risky = ["login", "signin", "sign-in", "logout", "verify", "confirm", "activate", "reset", "password",
                     "token", "auth", "magic", "unsubscribe", "invite", "approve", "otp", "callback", "redirect"]
        if risky.contains(where: { path.contains($0) }) { return false }
        // Đoạn đường dẫn dài như mã ngẫu nhiên.
        return !url.pathComponents.contains { $0.count >= 24 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    private func fetchTitle(_ item: ClipItem) {
        guard Prefs.linkPreview, let text = item.text, let url = ClipParse.link(text), Self.safeToPreview(url) else { return }
        let id = item.id
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.startFetchingMetadata(for: url) { meta, _ in
            let title = meta?.title
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let title, !title.isEmpty, let m = ClipboardWatcher.shared?.m else { return }
                    if let i = m.clips.firstIndex(where: { $0.id == id }) { m.clips[i].linkTitle = title }
                }
            }
        }
    }
}

extension NotchModel {
    var visibleClips: [ClipItem] {
        if clipFilter == .vault { return privateUnlocked ? privateClips.filter { $0.matches(clipSearch) } : [] }
        let base = clipFilter == .pinned ? pins : clips
        return base.filter {
            (clipCategory == nil || $0.category == clipCategory) && (clipApp == nil || $0.sourceID == clipApp) && $0.matches(clipSearch)
        }
    }
}

// MARK: - Giao diện

enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(_ bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let i = cache[id] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = i
        return i
    }
}

extension ClipCategory {
    var title: String {
        switch self {
        case .text: return "Chữ"
        case .link: return "Link"
        case .color: return "Màu"
        case .code: return "Code"
        case .file: return "File"
        case .image: return "Ảnh"
        }
    }
}

/// Bộ nhớ tạm dạng thẻ ngang: liếc là thấy ảnh, màu, code, link vừa chép.
struct ClipboardView: View {
    @ObservedObject var m: NotchModel
    // Giữ khung chọn mà không theo dõi nó: kéo khung chỉ vẽ lại phần khung, không vẽ lại cả hàng thẻ.
    @State private var marquee = ClipMarqueeState()

    var body: some View {
        let items = m.visibleClips
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if !m.clipMulti.isEmpty {
                    // Đang chọn nhiều thẻ: cả hàng nhường chỗ cho các nút làm cả nhóm.
                    ClipSelectionBar(m: m)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    TextField("", text: $m.clipSearch, prompt: Text("Tìm, @link @code @tên-app").foregroundColor(.white.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !m.clipSearch.isEmpty {
                        Button { m.clipSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(HoverPlain())
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(width: 190)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ClipChips(m: m)
                    }
                    // Chừa chỗ cho nút phóng to khi rê chuột, không bị cuộn cắt trên dưới.
                    .padding(.vertical, 4)
                    .padding(.horizontal, 3)
                }
                if m.clipFilter == .vault && m.privateUnlocked { VaultLockButton() }
                StackToggleButton(m: m)
                if m.clipFilter == .recent && !m.clips.isEmpty {
                    Button {
                        ClipboardWatcher.shared?.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(HoverPlain())
                    .help("Xoá lịch sử (mục đã ghim vẫn giữ)")
                }
                }
                Button {
                    AppDelegate.shared?.showLibrary(.clipboard)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(HoverPlain())
                .help("Mở bảng lớn (\(HotkeyCenter.combo(.library)?.display ?? "⌃⇧0"))")
            }
            if m.clipFilter == .vault && !m.privateUnlocked {
                VaultLockedView(m: m)
                    .frame(height: ClipCard.height + 16)
            } else if items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: m.clipFilter == .pinned ? "pin" : (m.clipFilter == .vault ? "lock.open" : "doc.on.clipboard")).font(.system(size: 20))
                    Text(emptyTitle).font(.system(size: 12, weight: .semibold))
                    Text(emptyDetail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(items) { item in
                                ClipCard(item: item, m: m, selected: m.clipSelection == item.id, space: "clipArea").id(item.id)
                            }
                        }
                        // Chừa chỗ để thẻ phóng lên khi rê chuột mà không bị cắt trên dưới.
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        // Phủ kín bề ngang để kéo khung ở chỗ trống sau thẻ cuối cũng được.
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .leading)
                        .modifier(ClipMarquee(m: m, space: "clipArea", state: marquee, root: false))
                    }
                    .onChange(of: m.clipSelection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                }
                .frame(height: ClipCard.height + 16)
                .help("Bấm thẻ để chép · kéo khung ở chỗ trống hoặc ⌘ bấm để chọn nhiều · chuột phải: ghim, đặt tên, sửa chữ, dịch")
            }
        }
        // Kéo khung từ chỗ trống phía trên (khe giữa hàng nút và hàng thẻ) cũng chọn được.
        .modifier(ClipMarquee(m: m, space: "clipArea", state: marquee))
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: items.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: m.clipMulti.isEmpty)
    }

    private var emptyTitle: String {
        if !m.clipSearch.isEmpty || m.clipCategory != nil || m.clipApp != nil { return "Không có mục nào khớp" }
        if m.clipFilter == .vault { return "Riêng tư đang trống" }
        return m.clipFilter == .pinned ? "Chưa ghim mục nào" : "Copy gì đó, nó sẽ hiện ở đây"
    }

    private var emptyDetail: String {
        if !m.clipSearch.isEmpty { return "Thử bỏ dấu hoặc bớt từ khoá" }
        if m.clipFilter == .vault { return "Kéo thẻ thả vào nút Riêng tư, hoặc chuột phải thẻ → Chuyển vào Riêng tư" }
        return m.clipFilter == .pinned ? "Bấm ghim trên thẻ, hoặc chuột phải → Ghim. Mục đã ghim vẫn còn khi tắt app."
                                       : "Mật khẩu copy từ trình quản lý mật khẩu sẽ không được lưu"
    }

}

/// Hàng nút lọc: Tất cả, Ghim, từng loại, rồi từng app đã copy (icon + số mục).
struct ClipChips: View {
    @ObservedObject var m: NotchModel
    var large = false

    var body: some View {
        chip("Tất cả", count: m.clips.count, on: m.clipFilter == .recent && m.clipCategory == nil && m.clipApp == nil, symbol: "square.grid.2x2") {
            m.clipFilter = .recent; m.clipCategory = nil; m.clipApp = nil
        }
        chip("Ghim", count: m.pins.count, on: m.clipFilter == .pinned, symbol: "pin.fill") {
            m.clipFilter = .pinned; m.clipCategory = nil; m.clipApp = nil
        }
        VaultChip(m: m)
        ForEach(ClipCategory.allCases, id: \.self) { c in
            let n = m.clips.filter { $0.category == c }.count
            if n > 0 {
                chip(c.title, count: n, on: m.clipCategory == c, symbol: c.symbol) {
                    m.clipFilter = .recent
                    m.clipCategory = m.clipCategory == c ? nil : c
                }
            }
        }
        let apps = appCounts
        if !apps.isEmpty {
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 2)
            ForEach(apps, id: \.id) { a in
                Button {
                    m.clipSelection = nil
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        m.clipFilter = .recent
                        m.clipApp = m.clipApp == a.id ? nil : a.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = AppIcons.icon(a.id) {
                            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                        } else {
                            Image(systemName: "app").font(.system(size: 11))
                        }
                        if large { Text(a.name).font(.system(size: 11, weight: .semibold)).lineLimit(1) }
                        Text("\(a.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white.opacity(m.clipApp == a.id ? 0.8 : 0.45))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(m.clipApp == a.id ? Color.white.opacity(0.24) : Color.white.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(HoverPlain())
                .help("Chỉ hiện thứ chép từ \(a.name)")
            }
        }
    }

    private var appCounts: [(id: String, name: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for c in m.clips {
            guard let id = c.sourceID else { continue }
            counts[id, default: (c.sourceName ?? id, 0)].1 += 1
        }
        return counts.map { (id: $0.key, name: $0.value.0, count: $0.value.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(large ? 20 : 8).map { $0 }
    }

    private func chip(_ title: String, count: Int, on: Bool, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            m.clipSelection = nil
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(on ? 0.75 : 0.45))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.white.opacity(0.24) : Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverPlain())
    }
}

struct ClipCard: View {
    static let width: CGFloat = 138
    static let height: CGFloat = 120

    let item: ClipItem
    @ObservedObject var m: NotchModel
    var selected = false
    /// Cỡ thẻ: nhỏ trên tai thỏ, lớn hơn trong bảng lớn.
    var w: CGFloat = ClipCard.width
    var h: CGFloat = ClipCard.height
    /// Vùng toạ độ của khung chọn (báo vị trí thẻ để kéo khung chọn nhiều).
    var space: String? = nil
    @State private var hover = false

    /// Thẻ đang nằm trong mục Riêng tư (đã mở khoá).
    private var isPrivate: Bool { m.clipFilter == .vault }

    var body: some View {
        card.background {
            if let space {
                GeometryReader { g in
                    Color.clear.preference(key: ClipFrameKey.self, value: [item.id: g.frame(in: .named(space))])
                }
            }
        }
    }

    /// Bấm thẻ: thường thì chép; giữ ⌘ thì thêm/bớt khỏi vùng chọn, ⇧ thì chọn dải; đang chọn nhiều thì bấm là thêm/bớt.
    private func tap() {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) || mods.contains(.command) || !m.clipMulti.isEmpty {
            ClipSelect.click(item, m: m, range: mods.contains(.shift))
            return
        }
        if isPrivate { PrivateVault.shared.copy(item) } else { ClipboardWatcher.shared?.restore(item) }
    }

    @ViewBuilder private var card: some View {
        let pinned = ClipboardWatcher.shared?.isPinned(item) ?? false
        let flash = m.clipFlash == item.id
        let picked = m.clipMulti.contains(item.id)
        let picking = !m.clipMulti.isEmpty
        Button {
            tap()
        } label: {
            ZStack(alignment: .bottom) {
                content
                    .frame(width: w, height: h, alignment: .topLeading)
                footer(pinned: pinned)
                if flash {
                    ZStack {
                        Color.black.opacity(0.55)
                        Label("Đã chép", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected || picked ? Color.accentColor : Color.white.opacity(hover ? 0.28 : 0.1),
                                  lineWidth: selected || picked ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                // Đang chọn nhiều: thẻ nào cũng có vòng tròn, thẻ đã chọn có dấu tick.
                if picking {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(picked ? Color.white : Color.white.opacity(0.7), picked ? Color.accentColor : Color.clear)
                        .background(Circle().fill(Color.black.opacity(picked ? 0 : 0.35)).padding(1))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(HoverAnim.bounce, value: picked)
            .animation(HoverAnim.bounce, value: picking)
            .scaleEffect(hover ? 1.03 : 1)
            .shadow(color: .black.opacity(hover ? 0.4 : 0), radius: hover ? 8 : 0, y: hover ? 3 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hover = h } }
        .animation(.easeOut(duration: 0.15), value: flash)
        .contextMenu {
            if picked && m.clipMulti.count > 1 { ClipSelectionMenu(m: m) }
            else if isPrivate { privateMenu } else { menu(pinned: pinned) }
        }
        .modifier(ClipDragModifier(item: item, enabled: !isPrivate && !picking))
        .help(picking ? "Bấm để chọn / bỏ chọn thẻ này"
              : isPrivate ? "Mục riêng tư · bấm để chép (không ghi vào lịch sử) · ⌘ bấm để chọn nhiều"
                          : (item.sourceName.map { "Chép từ \($0) · ⌘ bấm hoặc kéo khung ở chỗ trống để chọn nhiều" } ?? "Bấm để chép lại"))
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image(let img):
            Image(nsImage: img.thumb).resizable().aspectRatio(contentMode: .fill)
                .frame(width: w, height: h).clipped()
        case .files(let urls):
            VStack(spacing: 6) {
                FileThumb(url: urls[0]).frame(width: 60, height: 46)
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file")
                    .font(.system(size: 10.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, 12).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07))
        case .text(let s):
            switch item.category {
            case .color:
                let c = ClipParse.color(s) ?? .gray
                ZStack(alignment: .topLeading) {
                    Color(nsColor: c)
                    Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(ClipCard.readable(on: c))
                        .padding(9)
                }
            case .code:
                Text(ClipParse.highlight(String(s.prefix(400))))
                    .font(.system(size: 9.5, design: .monospaced))
                    .lineLimit(6)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(red: 0.1, green: 0.1, blue: 0.13))
            case .link:
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "link").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    Text(item.linkTitle ?? (ClipParse.link(s)?.host ?? s))
                        .font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                    Text(s).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(2).truncationMode(.middle)
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            default:
                Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11))
                    .lineLimit(5)
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.white.opacity(0.08))
            }
        }
    }

    private func footer(pinned: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = AppIcons.icon(item.sourceID) {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            }
            if let name = item.name {
                Image(systemName: "tag.fill").font(.system(size: 8)).foregroundStyle(Color.orange)
                Text(name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
            } else {
                // Chữ tĩnh "5 phút trước" (vẽ lại khi tai thỏ cập nhật), thay cho đồng hồ tự nhảy từng giây trên mọi thẻ.
                Text(Self.ago(item.date)).font(.system(size: 9)).lineLimit(1)
            }
            Spacer(minLength: 2)
            if isPrivate {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.orange)
            } else {
                Button {
                    ClipboardWatcher.shared?.togglePin(item)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(pinned ? Color.orange : Color.white.opacity(hover ? 0.8 : 0.35))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverPlain())
                .help(pinned ? "Bỏ ghim" : "Ghim (giữ lại lâu dài)")
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(white: 0.1).opacity(0.82))
        .environment(\.colorScheme, .dark)
    }

    private static let agoFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    static func ago(_ d: Date) -> String {
        let t = Date().timeIntervalSince(d)
        if t < 60 { return L("Vừa xong", "Just now") }
        return agoFormatter.localizedString(for: d, relativeTo: Date())
    }

    static func readable(on c: NSColor) -> Color {
        let s = c.usingColorSpace(.sRGB) ?? c
        let lum = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        return lum > 0.6 ? Color.black.opacity(0.8) : Color.white
    }

    @ViewBuilder private var privateMenu: some View {
        Button("🔒 Khoá Riêng tư ngay") { PrivateVault.shared.lock() }
        Divider()
        Button("Sao chép") { PrivateVault.shared.copy(item) }
        Button("Bỏ khỏi Riêng tư (về Bộ nhớ tạm)") { PrivateVault.shared.moveOut(item) }
        Divider()
        Button("Xoá hẳn mục này") { PrivateVault.shared.delete(item) }
    }

    @ViewBuilder private func menu(pinned: Bool) -> some View {
        Button("Sao chép") { ClipboardWatcher.shared?.restore(item) }
        Button(pinned ? "Bỏ ghim" : "Ghim") { ClipboardWatcher.shared?.togglePin(item) }
        Button("Chuyển vào Riêng tư 🔒") { PrivateVault.shared.add(item) }
        Button(item.name == nil ? "Đặt tên…" : "Đổi tên…") {
            if let n = Prompt.text(title: item.name == nil ? "Đặt tên cho mục này" : "Đổi tên",
                                   message: "Tên hiện dưới thẻ và tìm được bằng ô tìm.",
                                   value: item.name ?? "", ok: "Lưu") {
                ClipboardWatcher.shared?.setName(item, n)
            }
        }
        if item.name != nil {
            Button("Bỏ tên") { ClipboardWatcher.shared?.setName(item, nil) }
        }
        if item.category == .link, let t = item.text, let u = ClipParse.link(t) {
            Button("Mở liên kết") { NSWorkspace.shared.open(u) }
        }
        if item.category == .color, let t = item.text, let c = ClipParse.color(t) {
            Menu("Chép mã màu dạng") {
                Button(ClipParse.hex(c)) { ClipboardWatcher.shared?.copyText(ClipParse.hex(c)) }
                Button(ClipParse.rgb(c)) { ClipboardWatcher.shared?.copyText(ClipParse.rgb(c)) }
                Button(ClipParse.hsl(c)) { ClipboardWatcher.shared?.copyText(ClipParse.hsl(c)) }
            }
        }
        if let t = item.text {
            Menu("Sửa nhanh chữ rồi chép") {
                ForEach(TextTransform.allCases) { tr in
                    Button(tr.title) { ClipboardWatcher.shared?.copyText(tr.apply(t)) }
                }
            }
            Button("Dịch đoạn này") { TranslateModel.shared.start(text: t) }
        }
        if case .files(let urls) = item.kind {
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("Thả lên Kệ file") { m.addToShelf(urls) }
        }
        Divider()
        Button("Xoá mục này") { ClipboardWatcher.shared?.remove(item) }
    }
}


/// Nút Copy liên tục: rê chuột thì nảy và hiện màu cam (đang bật thì cam sẵn) để nhìn ra ngay.
struct StackToggleButton: View {
    @ObservedObject var m: NotchModel
    @State private var hovered = false

    var body: some View {
        let on = m.stack != nil
        Button { PasteStack.shared.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.system(size: 11, weight: .bold))
                if hovered || on {
                    Text(on ? "Đang copy liên tục" : "Copy liên tục")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(on || hovered ? Color.orange : Color.white)
            .padding(.horizontal, hovered || on ? 9 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .background(Capsule().fill(on || hovered ? Color.orange.opacity(hovered ? 0.3 : 0.22) : Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(hovered ? 0.6 : 0), lineWidth: 1))
            .scaleEffect(hovered ? 1.1 : 1)
            .shadow(color: Color.orange.opacity(hovered ? 0.45 : 0), radius: hovered ? 8 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Tắt Copy liên tục (hoặc nhấn ⌃ hai lần)" : "Copy nhiều thứ rồi ⌘V dán lần lượt (hoặc nhấn ⌃ hai lần)")
        .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }
}


/// Chỉ cho kéo thẻ thường (thẻ Riêng tư không kéo ra ngoài được).
struct ClipDragModifier: ViewModifier {
    let item: ClipItem
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.clipDrag(item) } else { content }
    }
}

/// Chip "Riêng tư" trong hàng lọc: bấm để xem, thả thẻ vào để cất. Có ổ khoá, đang khoá thì ổ khoá đóng.
struct VaultChip: View {
    @ObservedObject var m: NotchModel
    @State private var targeted = false
    @State private var hovered = false

    var body: some View {
        let on = m.clipFilter == .vault
        Button {
            m.clipSelection = nil
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                m.clipFilter = .vault; m.clipCategory = nil; m.clipApp = nil
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: m.privateUnlocked ? "lock.open.fill" : "lock.fill").font(.system(size: 9.5, weight: .semibold))
                Text("Riêng tư").font(.system(size: 11, weight: .semibold))
                Text("\(m.privateCount)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(on ? 0.75 : 0.45))
            }
            .foregroundStyle(targeted || m.privateFlash ? Color.orange : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(targeted || m.privateFlash ? Color.orange.opacity(0.3)
                                       : (on ? Color.white.opacity(0.24) : Color.white.opacity(hovered ? 0.14 : 0.07))))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(targeted ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .scaleEffect(targeted ? 1.15 : (hovered || m.privateFlash ? 1.1 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Bộ nhớ tạm riêng tư, khoá bằng vân tay · kéo thẻ thả vào đây để cất · chuột phải để khoá ngay")
        .contextMenu {
            if m.privateUnlocked {
                Button("🔒 Khoá Riêng tư ngay") { PrivateVault.shared.lock() }
            } else {
                Button("Mở khoá bằng vân tay") {
                    m.clipFilter = .vault; m.clipCategory = nil; m.clipApp = nil
                    PrivateVault.shared.unlock()
                }
            }
        }
        .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
        .animation(HoverAnim.bounce, value: targeted)
        .animation(HoverAnim.bounce, value: m.privateFlash)
        .onDrop(of: [UTType.rinClip], isTargeted: $targeted) { providers in
            for p in providers {
                p.loadDataRepresentation(forTypeIdentifier: UTType.rinClip.identifier) { data, _ in
                    guard let data, let s = String(data: data, encoding: .utf8), let id = UUID(uuidString: s) else { return }
                    Task { @MainActor in PrivateVault.shared.add(id: id) }
                }
            }
            return true
        }
    }
}
