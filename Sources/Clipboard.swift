// RinNotch — Bộ nhớ tạm: lịch sử, ghim (giữ qua lần mở app), tìm kiếm, app nguồn, nhận dạng
// link / màu / code, sửa nhanh chữ, sao lưu và nhập.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LinkPresentation

// MARK: - Dữ liệu

enum ClipKind {
    case text(String)
    case files([URL])
    case image(NSImage)
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
            let r = img.representations.first
            let w = r?.pixelsWide ?? Int(img.size.width), h = r?.pixelsHigh ?? Int(img.size.height)
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
        let hay = ClipParse.fold([preview, text ?? "", linkTitle ?? "", sourceName ?? ""].joined(separator: " "))
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

enum ClipFilter: String { case recent, pinned }

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

    static func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func encode(_ c: ClipItem, inlineImage: Bool) -> StoredClip? {
        var s = StoredClip(id: c.id, date: c.date, sourceID: c.sourceID, sourceName: c.sourceName, linkTitle: c.linkTitle, type: "text")
        switch c.kind {
        case .text(let t): s.text = t
        case .files(let urls): s.type = "files"; s.paths = urls.map(\.path)
        case .image(let img):
            s.type = "image"
            if inlineImage {
                guard let d = pngData(img) else { return nil }
                s.imageData = d
            } else {
                let name = c.id.uuidString + ".png"
                let url = imagesDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard let d = pngData(img) else { return nil }
                    try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                    guard (try? d.write(to: url)) != nil else { return nil }
                }
                s.imageFile = name
            }
        }
        return s
    }

    static func decode(_ s: StoredClip) -> ClipItem? {
        let kind: ClipKind
        switch s.type {
        case "text":
            guard let t = s.text else { return nil }
            kind = .text(t)
        case "files":
            guard let p = s.paths, !p.isEmpty else { return nil }
            kind = .files(p.map { URL(fileURLWithPath: $0) })
        case "image":
            if let d = s.imageData, let img = NSImage(data: d) { kind = .image(img) }
            else if let f = s.imageFile, let img = NSImage(contentsOf: imagesDir.appendingPathComponent(f)) { kind = .image(img) }
            else { return nil }
        default: return nil
        }
        var item = ClipItem(kind: kind, date: s.date, sourceID: s.sourceID, sourceName: s.sourceName, id: s.id)
        item.linkTitle = s.linkTitle
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
        return list.compactMap(decode)
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
        } else if let img = NSImage(pasteboard: pb) {
            kind = .image(img)
        }
        guard let kind else { return }
        add(ClipItem(kind: kind, sourceID: front?.bundleIdentifier, sourceName: front?.localizedName))
    }

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
        case .image(let img): pb.writeObjects([img])
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
        (clipFilter == .pinned ? pins : clips).filter { $0.matches(clipSearch) }
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

struct ClipboardView: View {
    @ObservedObject var m: NotchModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = m.visibleClips
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    TextField("", text: $m.clipSearch, prompt: Text("Tìm… gõ @link @image @color @code @file hoặc @tên-app").foregroundColor(.white.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                    if !m.clipSearch.isEmpty {
                        Button { m.clipSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.09)))
                filterButton(.recent, "Gần đây")
                filterButton(.pinned, "Đã ghim \(m.pins.count)")
            }
            if items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: m.clipFilter == .pinned ? "pin" : "doc.on.clipboard").font(.system(size: 20))
                    Text(emptyTitle).font(.system(size: 12, weight: .semibold))
                    Text(emptyDetail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 5) {
                            ForEach(items) { item in
                                ClipRow(item: item, m: m, selected: m.clipSelection == item.id).id(item.id)
                            }
                        }
                    }
                    .onChange(of: m.clipSelection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
            }
            HStack {
                Text("Bấm để chép · chuột phải: ghim, sửa chữ, mã màu · ↑↓ ↩ khi mở bằng phím")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 6)
                if m.clipFilter == .recent && !m.clips.isEmpty {
                    Button("Xoá lịch sử") { ClipboardWatcher.shared?.clearHistory() }.buttonStyle(PillButton())
                }
            }
        }
    }

    private var emptyTitle: String {
        if !m.clipSearch.isEmpty { return "Không có mục nào khớp" }
        return m.clipFilter == .pinned ? "Chưa ghim mục nào" : "Copy gì đó, nó sẽ hiện ở đây"
    }

    private var emptyDetail: String {
        if !m.clipSearch.isEmpty { return "Thử bỏ dấu hoặc bớt từ khoá" }
        return m.clipFilter == .pinned ? "Chuột phải một mục → Ghim. Mục đã ghim vẫn còn khi tắt máy."
                                       : "Mật khẩu copy từ trình quản lý mật khẩu sẽ không được lưu"
    }

    private func filterButton(_ f: ClipFilter, _ title: String) -> some View {
        Button {
            m.clipFilter = f
            m.clipSelection = nil
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(m.clipFilter == f ? 0.22 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var m: NotchModel
    var selected = false

    var body: some View {
        let pinned = ClipboardWatcher.shared?.isPinned(item) ?? false
        let flash = m.clipFlash == item.id
        Button {
            ClipboardWatcher.shared?.restore(item)
        } label: {
            HStack(spacing: 9) {
                leading.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    title.lineLimit(1).truncationMode(.tail)
                    if item.category == .link, item.linkTitle != nil, let t = item.text {
                        Text(t).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if flash {
                    Text("Đã chép ✓").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.green)
                } else {
                    Text(item.date, style: .relative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                if let icon = AppIcons.icon(item.sourceID) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14).help(item.sourceName ?? "")
                }
                Button {
                    ClipboardWatcher.shared?.togglePin(item)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(pinned ? Color.orange : Color.white.opacity(0.4))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pinned ? "Bỏ ghim" : "Ghim (giữ lại lâu dài)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(pinned: pinned) }
    }

    @ViewBuilder private var leading: some View {
        switch item.category {
        case .color:
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: item.text.flatMap(ClipParse.color) ?? .gray))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .frame(width: 18, height: 18)
        case .image:
            if case .image(let img) = item.kind {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
            }
        default:
            Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder private var title: some View {
        switch item.category {
        case .code:
            Text(ClipParse.highlight(String(item.preview.prefix(160)))).font(.system(size: 11.5, design: .monospaced))
        case .color:
            Text(item.preview).font(.system(size: 12, design: .monospaced))
        case .link:
            Text(item.linkTitle ?? item.preview).font(.system(size: 12))
        default:
            Text(item.preview).font(.system(size: 12))
        }
    }

    @ViewBuilder private func menu(pinned: Bool) -> some View {
        Button("Sao chép") { ClipboardWatcher.shared?.restore(item) }
        Button(pinned ? "Bỏ ghim" : "Ghim") { ClipboardWatcher.shared?.togglePin(item) }
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
