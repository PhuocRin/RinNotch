// RinNotch — Kệ file: đổi định dạng ảnh, nén ảnh, đổi cỡ, xoá nền, gộp PDF, nén ZIP.
// File mới luôn nằm cạnh file gốc (thư mục không ghi được thì vào Tải về), file gốc giữ nguyên.

import AppKit
import UniformTypeIdentifiers
import ImageIO
import Vision
import CoreImage
import PDFKit

enum ShelfOp: Hashable, Sendable {
    case convert(String)   // định danh UTType: public.jpeg, public.png, public.heic
    case compress
    case resize(Int)       // cạnh dài tối đa (px)
    case half
    case removeBackground
    case pdf
    case zip

    var title: String {
        switch self {
        case .convert(let t):
            return "Đổi sang " + (t == UTType.jpeg.identifier ? "JPG" : t == UTType.png.identifier ? "PNG" : "HEIC")
        case .compress: return "Nén ảnh (giảm dung lượng)"
        case .resize(let px): return "Thu nhỏ còn \(px) px"
        case .half: return "Thu nhỏ một nửa"
        case .removeBackground: return "Xoá nền (ra PNG trong suốt)"
        case .pdf: return "Gộp thành một file PDF"
        case .zip: return "Nén ZIP"
        }
    }

    var needsImage: Bool { self != .zip && self != .pdf }

    static let imageOps: [ShelfOp] = [
        .convert(UTType.jpeg.identifier), .convert(UTType.png.identifier), .convert(UTType.heic.identifier),
        .compress, .resize(3840), .resize(1920), .resize(1280), .half, .removeBackground,
    ]
}

enum ShelfError: Error { case cannotRead, cannotWrite, noSubject, unsupported }

enum ShelfTools {
    // MARK: Chạy (luồng nền) và báo kết quả lên kệ

    @MainActor
    static func run(_ op: ShelfOp, on urls: [URL], m: NotchModel) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        m.shelfStatus = "Đang xử lý…"
        m.shelfBusy = true
        Task.detached(priority: .userInitiated) {
            let r = ShelfTools.work(op, files)
            await MainActor.run {
                m.shelfBusy = false
                if !r.outputs.isEmpty {
                    m.addToShelf(r.outputs)
                    m.shelfSelection = Set(r.outputs)
                    m.shelfAnchor = r.outputs.last
                }
                m.flashShelfStatus(r.message)
            }
        }
    }

    /// Các thao tác hợp với nhóm file này (ảnh mới có thao tác ảnh).
    static func ops(for urls: [URL]) -> [ShelfOp] {
        var list: [ShelfOp] = []
        if urls.contains(where: isImage) { list += ShelfOp.imageOps }
        if urls.contains(where: { isImage($0) || isPDF($0) }) { list.append(.pdf) }
        list.append(.zip)
        return list
    }

    static func isImage(_ u: URL) -> Bool {
        let ext = u.pathExtension.lowercased()
        guard !["svg", "pdf", "ai", "eps", "psd"].contains(ext) else { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }

    static func isPDF(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }

    static func work(_ op: ShelfOp, _ files: [URL]) -> (outputs: [URL], message: String) {
        switch op {
        case .zip: return zip(files)
        case .pdf: return makePDF(files)
        default: break
        }
        let images = files.filter(isImage)
        guard !images.isEmpty else { return ([], "Không có ảnh nào để xử lý") }
        var outs: [URL] = []
        var failed = 0
        var before: Int64 = 0, after: Int64 = 0
        for u in images {
            do {
                let out = try processImage(op, u)
                outs.append(out)
                before += fileSize(u)
                after += fileSize(out)
            } catch ShelfError.noSubject {
                failed += 1
            } catch {
                failed += 1
            }
        }
        let n = outs.count
        let fail = failed > 0 ? " · \(failed) ảnh không làm được" : ""
        guard n > 0 else {
            if op == .removeBackground { return ([], "Không tìm thấy chủ thể để tách nền, hoặc máy này chưa hỗ trợ") }
            return ([], "Không xử lý được ảnh nào")
        }
        let size = ByteCountFormatter.string(fromByteCount: before, countStyle: .file) + " → "
            + ByteCountFormatter.string(fromByteCount: after, countStyle: .file)
        switch op {
        case .convert: return (outs, "\(op.title.replacingOccurrences(of: "Đổi sang", with: "Đã đổi \(n) ảnh sang"))\(fail)")
        case .compress:
            let pct = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            return (outs, "Đã nén \(n) ảnh: \(size)" + (pct > 0 ? " (giảm \(pct)%)" : "") + fail)
        case .resize, .half: return (outs, "Đã thu nhỏ \(n) ảnh: \(size)\(fail)")
        case .removeBackground: return (outs, "Đã xoá nền \(n) ảnh\(fail)")
        default: return (outs, "Xong\(fail)")
        }
    }

    // MARK: Ảnh

    private static func processImage(_ op: ShelfOp, _ u: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(src) > 0 else { throw ShelfError.cannotRead }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longSide = max(w, h, 1)
        let srcType = CGImageSourceGetType(src).map { $0 as String } ?? UTType.jpeg.identifier

        func image(maxPixel: Int) throws -> CGImage {
            // Đọc qua thumbnail đúng cỡ để xoay ảnh theo EXIF luôn (ảnh iPhone hay bị xoay).
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw ShelfError.cannotRead }
            return img
        }

        /// Định dạng ghi được để giữ nguyên kiểu ảnh khi thu nhỏ.
        let keepType: UTType = [UTType.jpeg, .png, .heic, .tiff].first { $0.identifier == srcType } ?? .jpeg

        switch op {
        case .convert(let id):
            let t = UTType(id) ?? .jpeg
            let out = outputURL(for: u, suffix: "", ext: t.preferredFilenameExtension ?? "jpg")
            try write(try image(maxPixel: longSide), to: out, type: t, quality: 0.9)
            return out
        case .compress:
            let t: UTType = srcType == UTType.heic.identifier ? .heic : .jpeg
            let out = outputURL(for: u, suffix: "-nen", ext: t.preferredFilenameExtension ?? "jpg")
            try write(try image(maxPixel: longSide), to: out, type: t, quality: t == .heic ? 0.6 : 0.72)
            return out
        case .resize(let px):
            let target = min(px, longSide)
            let out = outputURL(for: u, suffix: "-\(target)px", ext: keepType.preferredFilenameExtension ?? "jpg")
            try write(try image(maxPixel: target), to: out, type: keepType, quality: 0.88)
            return out
        case .half:
            let target = max(longSide / 2, 1)
            let out = outputURL(for: u, suffix: "-mot-nua", ext: keepType.preferredFilenameExtension ?? "jpg")
            try write(try image(maxPixel: target), to: out, type: keepType, quality: 0.88)
            return out
        case .removeBackground:
            let cut = try removeBackground(try image(maxPixel: longSide))
            let out = outputURL(for: u, suffix: "-xoa-nen", ext: "png")
            try write(cut, to: out, type: .png, quality: 1)
            return out
        default:
            throw ShelfError.unsupported
        }
    }

    private static func write(_ img: CGImage, to url: URL, type: UTType, quality: Double) throws {
        var image = img
        if type == .jpeg && hasAlpha(img), let flat = flatten(img) { image = flat }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ShelfError.unsupported }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ShelfError.cannotWrite
        }
    }

    private static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// JPG không có nền trong suốt: lót nền trắng thay vì để macOS tô đen.
    private static func flatten(_ img: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage()
    }

    /// Tách chủ thể bằng Vision của Apple (chạy trên máy, không gửi ảnh đi đâu).
    private static func removeBackground(_ img: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { throw ShelfError.noSubject }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { throw ShelfError.cannotWrite }
        return out
    }

    // MARK: PDF

    private static func makePDF(_ files: [URL]) -> (outputs: [URL], message: String) {
        let doc = PDFDocument()
        var count = 0
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        for u in files {
            if isPDF(u), let src = PDFDocument(url: u) {
                for i in 0..<src.pageCount {
                    if let p = src.page(at: i)?.copy() as? PDFPage {
                        doc.insert(p, at: doc.pageCount)
                        count += 1
                    }
                }
            } else if isImage(u), let s = CGImageSourceCreateWithURL(u as CFURL, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3000,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                let landscape = cg.width > cg.height
                let box = landscape ? CGRect(x: 0, y: 0, width: a4.height, height: a4.width) : a4
                if let page = PDFPage(image: img, options: [.mediaBox: NSValue(rect: box), .compressionQuality: 0.85]) {
                    doc.insert(page, at: doc.pageCount)
                    count += 1
                }
            }
        }
        guard count > 0, let first = files.first(where: { isImage($0) || isPDF($0) }) else { return ([], "Không có ảnh hoặc PDF nào để gộp") }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        let name = files.count == 1 ? first.deletingPathExtension().lastPathComponent : "RinNotch \(df.string(from: Date()))"
        let out = outputURL(for: first.deletingLastPathComponent().appendingPathComponent(name + ".pdf"), suffix: "", ext: "pdf")
        guard doc.write(to: out) else { return ([], "Không ghi được file PDF") }
        return ([out], "Đã tạo PDF \(count) trang · \(ByteCountFormatter.string(fromByteCount: fileSize(out), countStyle: .file))")
    }

    // MARK: ZIP

    private static func zip(_ files: [URL]) -> (outputs: [URL], message: String) {
        guard let first = files.first else { return ([], "") }
        let name = files.count == 1 ? first.lastPathComponent : "RinNotch \(files.count) file"
        let out = outputURL(for: first.deletingLastPathComponent().appendingPathComponent(name + ".zip"), suffix: "", ext: "zip")
        // Gom theo thư mục cha để giữ đúng cấu trúc thư mục con trong file nén.
        var groups = Dictionary(grouping: files, by: { $0.deletingLastPathComponent().path }).map { ($0.key, $0.value) }
        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        // Hai file trùng tên ở hai thư mục khác nhau: đặt lối tắt tên riêng trong thư mục tạm,
        // không thì file sau đè file trước trong file nén.
        let names = files.map(\.lastPathComponent)
        if Set(names).count != names.count {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rinnotch-zip-\(UUID().uuidString)")
            do { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { return ([], "Không nén được") }
            staging = tmp
            var used = Set<String>()
            var links: [URL] = []
            for f in files {
                let ext = f.pathExtension
                let base = f.deletingPathExtension().lastPathComponent
                var name = f.lastPathComponent
                var i = 2
                while used.contains(name) {
                    name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
                    i += 1
                }
                used.insert(name)
                let link = tmp.appendingPathComponent(name)
                do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f) } catch { return ([], "Không nén được") }
                links.append(link)
            }
            groups = [(tmp.path, links)]
        }
        for (dir, items) in groups {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            // "./tên" để tên bắt đầu bằng "-" không bị hiểu là tuỳ chọn. Thư mục tạm thì phải đi theo lối tắt (bỏ -y).
            let follow = staging == nil ? ["-y"] : []
            p.arguments = ["-r", "-q"] + follow + [out.path] + items.map { "./" + $0.lastPathComponent }
                + ["-x", "*.DS_Store", "-x", "*/__MACOSX/*"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return ([], "Không nén được") }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                try? FileManager.default.removeItem(at: out)
                return ([], "Không nén được (lỗi \(p.terminationStatus))")
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: fileSize(out), countStyle: .file)
        return ([out], "Đã nén ZIP \(files.count) mục · \(size)")
    }

    // MARK: Tiện ích

    private static func fileSize(_ u: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
    }

    /// Tên file mới không đè lên file có sẵn: "ảnh-nen.jpg", "ảnh-nen 2.jpg"…
    /// Thư mục gốc không ghi được (ổ chỉ đọc, thư mục hệ thống) thì để vào Tải về.
    private static func outputURL(for u: URL, suffix: String, ext: String) -> URL {
        var dir = u.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let base = u.deletingPathExtension().lastPathComponent + suffix
        var cand = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: cand.path) {
            cand = dir.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return cand
    }
}
