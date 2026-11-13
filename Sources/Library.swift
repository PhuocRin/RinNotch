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
        .buttonStyle(HoverPlain())
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

/// Đổi tên file thật trên ổ (chuột phải trên thẻ → Đổi tên file…).
@MainActor
enum ShelfRename {
    static func run(_ u: URL, m: NotchModel) {
        guard let name = Prompt.text(title: "Đổi tên file", message: "File gốc trong Finder cũng được đổi tên.",
                                     value: u.lastPathComponent, ok: "Đổi tên", selectBaseName: true) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != u.lastPathComponent else { return }
        let dest = u.deletingLastPathComponent().appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: dest.path) {
            m.flashShelfStatus("Đã có file tên \"\(clean)\" trong thư mục đó")
            return
        }
        do {
            try FileManager.default.moveItem(at: u, to: dest)
            if let i = m.shelf.firstIndex(of: u) { m.shelf[i] = dest }
            if m.shelfSelection.remove(u) != nil { m.shelfSelection.insert(dest) }
            if m.shelfAnchor == u { m.shelfAnchor = dest }
            m.saveShelfNow()
            m.flashShelfStatus("Đã đổi tên thành \(clean)")
        } catch {
            m.flashShelfStatus("Không đổi tên được: \(error.localizedDescription)")
        }
    }
}

/// Vị trí từng thẻ file, để kéo khung chọn nhiều (hàng ngang trên tai thỏ lẫn lưới trong bảng lớn).
struct ShelfFrameKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] { [:] }
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Trạng thái khung chọn, dùng chung giữa chỗ trống ở hàng trên và chỗ trống trong hàng thẻ.
@MainActor
final class MarqueeState: ObservableObject {
    @Published var rect: CGRect?
    var base: Set<URL> = []
    var frames: [URL: CGRect] = [:]
}

/// Kéo khung ở chỗ trống để chọn nhiều file; giữ ⌘ hoặc ⇧ thì cộng thêm vào vùng chọn cũ.
/// Bấm chỗ trống (không kéo) thì bỏ chọn. `root` = vùng ngoài cùng: đặt hệ toạ độ, vẽ khung, gom vị trí thẻ.
struct ShelfMarquee: ViewModifier {
    @ObservedObject var m: NotchModel
    let space: String
    @ObservedObject var state: MarqueeState
    var root = true

    func body(content: Content) -> some View {
        let caught = content.background(
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(drag)
        )
        if root {
            caught
                .overlay(alignment: .topLeading) {
                    if let r = state.rect, r.width > 2 || r.height > 2 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(ShelfFrameKey.self) { f in state.frames = f }
        } else {
            caught
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if state.rect == nil {
                    let mods = NSEvent.modifierFlags
                    state.base = mods.contains(.command) || mods.contains(.shift) ? m.shelfSelection : []
                    m.marqueeActive = true
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                state.rect = r
                var sel = state.base
                if r.width > 2 || r.height > 2 {
                    for (u, f) in state.frames where f.intersects(r) && m.shelf.contains(u) { sel.insert(u) }
                }
                if sel != m.shelfSelection { m.shelfSelection = sel }
            }
            .onEnded { _ in
                state.rect = nil
                m.marqueeActive = false
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

enum LibraryTab: String, CaseIterable {
    case clipboard, shelf, notes, translate
    var title: String {
        switch self {
        case .clipboard: return "Bộ nhớ tạm"
        case .shelf: return "Kệ file"
        case .notes: return "Ghi chú"
        case .translate: return "Dịch"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: return Tab.clipboard.symbol
        case .shelf: return Tab.shelf.symbol
        case .notes: return Tab.notes.symbol
        case .translate: return Tab.translate.symbol
        }
    }
}

/// Nền kính: Liquid Glass của hệ thống trên macOS 26 trở lên, kính mờ ở bản cũ hơn.
struct GlassBackdrop: View {
    var radius: CGFloat = 28

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            VisualBlur().clipShape(shape)
        }
        #else
        VisualBlur().clipShape(shape)
        #endif
    }
}

struct VisualBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Viên kính nhỏ (nút, ô tìm) trên bảng lớn.
struct GlassCapsule: ViewModifier {
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            } else {
                content.glassEffect(.regular.interactive(), in: Capsule())
            }
        } else {
            content.background(Capsule().fill(tint ?? Color.white.opacity(0.1)))
        }
        #else
        content.background(Capsule().fill(tint ?? Color.white.opacity(0.1)))
        #endif
    }
}

struct LibraryView: View {
    @ObservedObject var m: NotchModel
    @State private var shelfSearch = ""
    @StateObject private var bigMarquee = MarqueeState()
    @StateObject private var clipMarquee = ClipMarqueeState()

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(LibraryTab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { m.libraryTab = t }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.symbol).font(.system(size: 13, weight: .semibold))
                            Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if t == .clipboard { badge(m.clips.count) }
                            if t == .shelf { badge(m.shelf.count) }
                        }
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white.opacity(m.libraryTab == t ? 1 : 0.7))
                        .modifier(GlassCapsule(tint: m.libraryTab == t ? Color.accentColor.opacity(0.55) : nil))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(HoverPlain())
                }
                Spacer(minLength: 8)
                if m.libraryTab == .clipboard || m.libraryTab == .shelf {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                        if m.libraryTab == .clipboard {
                            TextField("", text: $m.clipSearch, prompt: Text("Tìm, không cần dấu · @link @code @tên-app").foregroundColor(.white.opacity(0.4)))
                                .textFieldStyle(.plain)
                        } else {
                            TextField("", text: $shelfSearch, prompt: Text("Tìm tên file").foregroundColor(.white.opacity(0.4)))
                                .textFieldStyle(.plain)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minWidth: 160, maxWidth: 360)
                    .modifier(GlassCapsule())
                }
            }
            if m.libraryTab == .clipboard || m.libraryTab == .shelf {
                if m.libraryTab == .clipboard && !m.clipMulti.isEmpty {
                    ClipSelectionBar(m: m, large: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if m.libraryTab == .clipboard { ClipChips(m: m, large: true) } else { ShelfChips(m: m) }
                        }
                    }
                }
            }
            Group {
                switch m.libraryTab {
                case .clipboard: clipGrid
                case .shelf: shelfGrid
                case .notes: BigNotesView(m: m)
                case .translate: TranslateView(m: m).padding(.top, 4)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            if m.libraryTab == .clipboard || m.libraryTab == .shelf { bottomBar }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(minWidth: 820, minHeight: 460)
        // Kính phủ luôn thanh tiêu đề (hàng có ba nút đỏ / vàng / xanh) như cửa sổ thường.
        // Góc bo do cửa sổ quyết định (bo theo macOS); kính bo nhỏ hơn để không hở góc.
        .background(GlassBackdrop(radius: 10).ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Bung ra từ phía trên (như từ tai thỏ) thay vì hiện cái rụp.
        .scaleEffect(appeared ? 1 : 0.86, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rinLibraryWillClose)) { _ in
            withAnimation(.easeIn(duration: 0.16)) { appeared = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rinLibraryWillOpen)) { _ in
            appeared = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true }
        }
    }

    private func badge(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
    }

    private var clipGrid: some View {
        let items = m.visibleClips
        return Group {
            if m.clipFilter == .vault && !m.privateUnlocked {
                VaultLockedView(m: m, cardW: 186, cardH: 146, large: true)
            } else if items.isEmpty {
                empty(symbol: "doc.on.clipboard", text: m.clips.isEmpty && m.pins.isEmpty ? "Copy gì đó, nó sẽ hiện ở đây" : "Không có mục nào khớp")
            } else {
                GeometryReader { geo in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 240), spacing: 12)], spacing: 12) {
                            ForEach(items) { item in
                                ClipCard(item: item, m: m, selected: m.clipSelection == item.id, w: 186, h: 146, space: "bigClip")
                            }
                        }
                        .padding(4)
                        // Lưới phủ kín chiều cao để kéo khung ở chỗ trống bên dưới cũng được.
                        .frame(minHeight: geo.size.height, alignment: .top)
                        .modifier(ClipMarquee(m: m, space: "bigClip", state: clipMarquee))
                    }
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
                GeometryReader { geo in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 240), spacing: 12)], spacing: 12) {
                            ForEach(files, id: \.self) { url in
                                ShelfItem(url: url, m: m, selected: m.shelfSelection.contains(url), w: 186, h: 156, space: "bigShelf")
                            }
                        }
                        .padding(8)
                        // Lưới phủ kín chiều cao để kéo khung ở chỗ trống bên dưới cũng được.
                        .frame(minHeight: geo.size.height, alignment: .top)
                        .modifier(ShelfMarquee(m: m, space: "bigShelf", state: bigMarquee))
                    }
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

extension Notification.Name {
    static let rinLibraryWillClose = Notification.Name("RinNotchLibraryWillClose")
    static let rinLibraryWillOpen = Notification.Name("RinNotchLibraryWillOpen")
}

/// Bảng lớn nổi trên màn hình: không viền, nền kính, không giành focus của app đang dùng (giống RinKeys).
final class LibraryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { LibraryWindow.shared.close() }
    }
}

@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var panel: LibraryPanel?
    private var closing = false

    var isFrontmost: Bool { panel?.isVisible == true && !closing }

    func show(_ m: NotchModel) {
        if panel == nil {
            // Có ba nút đỏ / vàng / xanh như cửa sổ thường (và ⌘W để đóng), thanh tiêu đề trong suốt
            // để nền kính phủ kín cả cửa sổ.
            let p = LibraryPanel(contentRect: CGRect(x: 0, y: 0, width: 980, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            // Hàng tiêu đề riêng như cửa sổ khác: ba nút bên trái, tên ở giữa.
            p.titleVisibility = .visible
            p.title = "RinNotch · Bảng lớn"
            p.delegate = self
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 820, height: 460)
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
            p.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: LibraryView(m: m))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            p.contentView = host
            p.setFrameAutosaveName("RinNotchBigBoard")
            if !p.setFrameUsingName("RinNotchBigBoard") { place(p) }
            panel = p
        } else if panel?.isVisible == false {
            NotificationCenter.default.post(name: .rinLibraryWillOpen, object: nil)
        }
        closing = false
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    /// Lần đầu: giữa màn hình đang có chuột, rộng khoảng 70% × 75%.
    private func place(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let w = min(max(f.width * 0.7, 760), 1280), h = min(max(f.height * 0.75, 480), 860)
        p.setFrame(CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: false)
    }

    /// Nút đỏ và ⌘W đi qua đây: chạy hiệu ứng thu lại rồi mới ẩn.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func close() {
        guard let p = panel, p.isVisible, !closing else { return }
        closing = true
        NotificationCenter.default.post(name: .rinLibraryWillClose, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                p.orderOut(nil)
                self.closing = false
            }
        }
    }
}

/// Ghi chú cỡ lớn trong bảng lớn: ô gõ to + danh sách ghi chú gần đây.
struct BigNotesView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $m.noteDraft)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            NotesSaver.save(m)
                            return .handled
                        }
                    if m.noteDraft.isEmpty {
                        Text("Gõ ý tưởng… Enter để xuống dòng, ⌘ Enter để lưu vào Notes")
                            .font(.system(size: 15)).foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.25)))
                HStack {
                    Text(m.noteStatus ?? "Lưu vào app Ghi chú, thư mục RinNotch")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    Spacer()
                    Button("Lưu vào Notes") { NotesSaver.save(m) }
                        .buttonStyle(PillButton(prominent: true))
                        .disabled(m.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Gần đây").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(m.notes) { n in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.text).font(.system(size: 12)).lineLimit(4)
                                HStack(spacing: 6) {
                                    Image(systemName: n.savedToNotes ? "checkmark.circle.fill" : "circle.dashed")
                                        .foregroundStyle(n.savedToNotes ? Color.green : Color.white.opacity(0.4))
                                    Text(n.date, style: .relative)
                                    Spacer()
                                    Button("Chép") { ClipboardWatcher.shared?.copyText(n.text, source: "RinNotch · Ghi chú") }
                                        .buttonStyle(HoverPlain()).foregroundStyle(Color.accentColor)
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
                        }
                        if m.notes.isEmpty {
                            Text("Chưa có ghi chú nào").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            .frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
