// RinNotch — Kệ file dạng thẻ + bảng lớn (cửa sổ chứa hết Bộ nhớ tạm và Kệ file).

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Loại file trên kệ

enum ShelfKind: String, CaseIterable {
    case image, video, pdf, doc, folder, other

    var title: String {
        switch self {
        case .image: return "Ảnh"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .doc: return "Tài liệu"
        case .folder: return "Thư mục"
        case .other: return "Khác"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .doc: return "doc.text"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    static func of(_ u: URL) -> ShelfKind {
        var isDir: ObjCBool = false
        let ext = u.pathExtension.lowercased()
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, ext != "app" { return .folder }
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .text) || t.conforms(to: .spreadsheet) || t.conforms(to: .presentation)
            || t.conforms(to: .rtf) || ["doc", "docx", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx"].contains(ext) { return .doc }
        return .other
    }
}

extension NotchModel {
    var visibleShelf: [URL] {
        guard let k = shelfKind else { return shelf }
        return shelf.filter { ShelfKind.of($0) == k }
    }
}

struct ShelfChips: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        let kinds = Dictionary(grouping: m.shelf, by: ShelfKind.of).mapValues(\.count)
        chip("Tất cả", symbol: "square.grid.2x2", count: m.shelf.count, on: m.shelfKind == nil) { m.shelfKind = nil }
        ForEach(ShelfKind.allCases, id: \.self) { k in
            if let n = kinds[k], n > 0, kinds.count > 1 {
                chip(k.title, symbol: k.symbol, count: n, on: m.shelfKind == k) {
                    m.shelfKind = m.shelfKind == k ? nil : k
                }
            }
        }
    }

    private func chip(_ title: String, symbol: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                m.shelfSelection = []
                action()
            }
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
        .buttonStyle(.plain)
    }
}

/// Ảnh xem trước to cho thẻ file: ảnh, video, PDF phủ kín thẻ; file không xem trước được thì hiện icon.
struct FileCardThumb: View {
    let url: URL
    let size: CGSize
    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                    .padding(size.height * 0.16)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb = rep.nsImage
            }
        }
    }
}

enum FileInfo {
    static func size(_ u: URL) -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return "Không còn" }
        if isDir.boolValue { return "Thư mục" }
        let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Bảng lớn

enum LibraryTab: String { case clipboard, shelf }

struct LibraryView: View {
    @ObservedObject var m: NotchModel
    @State private var shelfSearch = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $m.libraryTab) {
                    Text("Bộ nhớ tạm \(m.clips.count)").tag(LibraryTab.clipboard)
                    Text("Kệ file \(m.shelf.count)").tag(LibraryTab.shelf)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    if m.libraryTab == .clipboard {
                        TextField("", text: $m.clipSearch, prompt: Text("Tìm, không cần dấu · @link @image @color @code @file @tên-app").foregroundColor(.white.opacity(0.35)))
                            .textFieldStyle(.plain)
                    } else {
                        TextField("", text: $shelfSearch, prompt: Text("Tìm tên file").foregroundColor(.white.opacity(0.35)))
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.09)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if m.libraryTab == .clipboard { ClipChips(m: m, large: true) } else { ShelfChips(m: m) }
                }
            }
            if m.libraryTab == .clipboard { clipGrid } else { shelfGrid }
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .padding(.bottom, 14)
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(white: 0.07))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var clipGrid: some View {
        let items = m.visibleClips
        return Group {
            if items.isEmpty {
                empty(symbol: "doc.on.clipboard", text: m.clips.isEmpty && m.pins.isEmpty ? "Copy gì đó, nó sẽ hiện ở đây" : "Không có mục nào khớp")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            ClipCard(item: item, m: m, selected: m.clipSelection == item.id, w: 186, h: 146)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shelfGrid: some View {
        let q = ClipParse.fold(shelfSearch)
        let files = m.visibleShelf.filter { q.isEmpty || ClipParse.fold($0.lastPathComponent).contains(q) }
        return Group {
            if files.isEmpty {
                empty(symbol: "tray.and.arrow.down", text: m.shelf.isEmpty ? "Kéo file thả vào đây hoặc lên tai thỏ" : "Không có file nào khớp")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 240), spacing: 12)], spacing: 12) {
                        ForEach(files, id: \.self) { url in
                            ShelfItem(url: url, m: m, selected: m.shelfSelection.contains(url), w: 186, h: 156)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in m.addToShelf([url]) }
                }
            }
            return true
        }
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 8) {
            if m.libraryTab == .clipboard {
                Text("Bấm thẻ để chép · chuột phải: ghim, sửa chữ, mã màu, dịch · ghim giữ lại khi tắt app")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer()
                if !m.clips.isEmpty {
                    Button("Xoá lịch sử") { ClipboardWatcher.shared?.clearHistory() }.buttonStyle(PillButton())
                }
            } else {
                let sel = m.selectedShelf
                let targets = sel.isEmpty ? m.visibleShelf : sel
                if m.shelfBusy { ProgressView().controlSize(.mini) }
                Text(m.shelfStatus ?? (sel.isEmpty ? "Bấm để chọn, ⌘ + bấm chọn thêm · kéo thẻ ra ngoài = sao chép, giữ ⌘ = chuyển"
                                                    : "Đã chọn \(sel.count) file"))
                    .font(.system(size: 11))
                    .foregroundStyle(m.shelfStatus != nil ? Color.green.opacity(0.9) : .white.opacity(0.5))
                    .lineLimit(1)
                Spacer()
                if !targets.isEmpty {
                    Button("AirDrop") { Actions.airDrop(targets) }.buttonStyle(PillButton(prominent: true))
                    Button("Sao chép") { Actions.copyFiles(targets) }.buttonStyle(PillButton())
                    Menu {
                        ForEach(ShelfTools.ops(for: targets), id: \.self) { op in
                            Button(op.title) { ShelfTools.run(op, on: targets, m: m) }
                        }
                    } label: {
                        Text("Xử lý").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .disabled(m.shelfBusy)
                    if sel.isEmpty {
                        Button("Xoá kệ") { m.clearShelf() }.buttonStyle(PillButton())
                    } else {
                        Button("Bỏ khỏi kệ") { m.removeFromShelf(sel) }.buttonStyle(PillButton())
                    }
                }
            }
        }
    }

    private func empty(symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30))
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?

    var isFrontmost: Bool { window?.isVisible == true && window?.isKeyWindow == true }

    func show(_ m: NotchModel) {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "RinNotch"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 640, height: 420)
            w.backgroundColor = NSColor(white: 0.07, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.contentView = NSHostingView(rootView: LibraryView(m: m))
            w.setFrameAutosaveName("RinNotchLibrary")
            if !w.setFrameUsingName("RinNotchLibrary") { w.center() }
            w.delegate = self
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() { window?.performClose(nil) }
}
