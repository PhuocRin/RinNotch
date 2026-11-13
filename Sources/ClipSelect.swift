import AppKit
import SwiftUI

// Chọn nhiều thẻ Bộ nhớ tạm: kéo khung ở chỗ trống, ⌘ bấm (thêm/bớt), ⇧ bấm (chọn dải), ⌘A (chọn hết).
// Chọn xong thì làm một lần cho cả nhóm: chép gộp, Copy liên tục, ghim, cất Riêng tư, xoá.

/// Vị trí từng thẻ Bộ nhớ tạm trong vùng kéo khung.
struct ClipFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

@MainActor
final class ClipMarqueeState: ObservableObject {
    @Published var rect: CGRect?
    var base: Set<UUID> = []
    var frames: [UUID: CGRect] = [:]
}

/// Giống khung chọn của Kệ file: kéo ở chỗ trống để chọn, giữ ⌘/⇧ thì cộng thêm, bấm chỗ trống (không kéo) thì bỏ chọn.
/// `root` = vùng ngoài cùng: đặt hệ toạ độ, vẽ khung, gom vị trí thẻ.
struct ClipMarquee: ViewModifier {
    @ObservedObject var m: NotchModel
    let space: String
    @ObservedObject var state: ClipMarqueeState
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
                .onPreferenceChange(ClipFrameKey.self) { f in state.frames = f }
        } else {
            caught
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                // Riêng tư đang khoá thì không có thẻ để chọn.
                if m.clipFilter == .vault && !m.privateUnlocked { return }
                if state.rect == nil {
                    let mods = NSEvent.modifierFlags
                    state.base = mods.contains(.command) || mods.contains(.shift) ? m.clipMulti : []
                    m.marqueeActive = true
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                state.rect = r
                var sel = state.base
                if r.width > 2 || r.height > 2 {
                    let visible = Set(m.visibleClips.map(\.id))
                    for (id, f) in state.frames where f.intersects(r) && visible.contains(id) { sel.insert(id) }
                }
                if sel != m.clipMulti { m.clipMulti = sel }
            }
            .onEnded { _ in
                state.rect = nil
                m.marqueeActive = false
            }
    }
}

@MainActor
enum ClipSelect {
    /// Thẻ đang chọn và còn hiện trên màn hình, theo thứ tự đang hiện (mới trước).
    static func items(_ m: NotchModel) -> [ClipItem] {
        m.visibleClips.filter { m.clipMulti.contains($0.id) }
    }

    /// ⌘ bấm: thêm/bớt một thẻ. ⇧ bấm: chọn cả dải từ thẻ bấm trước tới thẻ này.
    static func click(_ item: ClipItem, m: NotchModel, range: Bool) {
        let list = m.visibleClips
        if range, let a = m.clipAnchor, let ia = list.firstIndex(where: { $0.id == a }),
           let ib = list.firstIndex(where: { $0.id == item.id }) {
            m.clipMulti.formUnion(list[min(ia, ib)...max(ia, ib)].map(\.id))
            return
        }
        if m.clipMulti.contains(item.id) { m.clipMulti.remove(item.id) } else { m.clipMulti.insert(item.id) }
        m.clipAnchor = item.id
    }

    static func clear(_ m: NotchModel) {
        m.clipMulti = []
        m.clipAnchor = nil
    }

    static func selectAll(_ m: NotchModel) {
        m.clipMulti = Set(m.visibleClips.map(\.id))
    }

    /// Chép gộp: toàn file thì chép cả nhóm file (dán vào Finder được hết); có chữ thì nối chữ mỗi mục một dòng
    /// (file thì thành đường dẫn). Ảnh không nối vào chữ được nên bỏ qua. Trả về số mục đã chép.
    @discardableResult
    static func copyJoined(_ m: NotchModel) -> Int {
        let its = items(m)
        guard !its.isEmpty else { return 0 }
        let vault = m.clipFilter == .vault
        var urls: [URL] = []
        var texts: [String] = []
        var used = 0
        for it in its.reversed() { // cũ trước, đúng thứ tự đã copy
            switch it.kind {
            case .files(let u): urls += u; texts += u.map(\.path); used += 1
            case .text(let s): texts.append(s); used += 1
            case .image: break
            }
        }
        let onlyFiles = !urls.isEmpty && its.allSatisfy { if case .files = $0.kind { return true } else { return false } }
        if onlyFiles {
            let item = ClipItem(kind: .files(urls))
            if vault {
                PrivateVault.shared.copyRaw(item)
            } else {
                // Ghi như copy thường để nhóm file mới hiện đầu lịch sử.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls as [NSURL])
            }
        } else if !texts.isEmpty {
            let joined = texts.joined(separator: "\n")
            if vault {
                PrivateVault.shared.copyRaw(ClipItem(kind: .text(joined)))
            } else {
                ClipboardWatcher.shared?.copyText(joined, source: "RinNotch · gộp \(used) mục")
            }
        } else if let img = its.first(where: { if case .image = $0.kind { return true } else { return false } }) {
            // Toàn ảnh: chỉ chép được một ảnh mỗi lần, lấy ảnh mới nhất (muốn dán hết thì dùng Copy liên tục).
            if vault { PrivateVault.shared.copy(img) } else { ClipboardWatcher.shared?.restore(img) }
            return 1
        }
        return used
    }

    /// Nạp các mục đã chọn vào Copy liên tục, dán theo thứ tự đã copy (cũ trước).
    static func pasteInOrder(_ m: NotchModel) {
        let its = items(m).sorted { $0.date < $1.date }
        guard !its.isEmpty else { return }
        clear(m)
        PasteStack.shared.start(with: its)
    }

    /// Ghim cả nhóm; nếu đã ghim hết rồi thì bỏ ghim cả nhóm.
    static func togglePin(_ m: NotchModel) {
        guard let w = ClipboardWatcher.shared else { return }
        let its = items(m)
        let allPinned = its.allSatisfy { w.isPinned($0) }
        for it in its.reversed() where w.isPinned(it) == allPinned { w.togglePin(it) }
        clear(m)
    }

    static func toPrivate(_ m: NotchModel) {
        let its = items(m)
        clear(m)
        for it in its.reversed() { PrivateVault.shared.add(it) }
    }

    static func moveOut(_ m: NotchModel) {
        let its = items(m)
        clear(m)
        for it in its.reversed() { PrivateVault.shared.moveOut(it) }
    }

    static func delete(_ m: NotchModel) {
        let its = items(m)
        clear(m)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            for it in its {
                if m.clipFilter == .vault { PrivateVault.shared.delete(it) } else { ClipboardWatcher.shared?.remove(it) }
            }
        }
    }

    static func allPinned(_ m: NotchModel) -> Bool {
        guard let w = ClipboardWatcher.shared else { return false }
        let its = items(m)
        return !its.isEmpty && its.allSatisfy { w.isPinned($0) }
    }
}

/// Hàng nút thay cho hàng lọc khi đang chọn nhiều thẻ.
struct ClipSelectionBar: View {
    @ObservedObject var m: NotchModel
    var large = false
    @State private var copied = 0

    var body: some View {
        let n = ClipSelect.items(m).count
        let vault = m.clipFilter == .vault
        HStack(spacing: large ? 8 : 5) {
            Text(copied > 0 ? "Đã chép gộp \(copied) mục" : "Đã chọn \(n)")
                .font(.system(size: large ? 13 : 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(copied > 0 ? Color.green : Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
            act("doc.on.doc", "Chép gộp", help: "Chép tất cả thành một lần dán (chữ nối mỗi mục một dòng, file chép cả nhóm)") {
                let c = ClipSelect.copyJoined(m)
                guard c > 0 else { return }
                copied = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    MainActor.assumeIsolated {
                        copied = 0
                        ClipSelect.clear(m)
                    }
                }
            }
            if !vault {
                act("square.stack.3d.up.fill", "Copy liên tục", tint: .orange,
                    help: "⌘V dán lần lượt từng mục đã chọn, theo thứ tự đã copy (cũ trước)") { ClipSelect.pasteInOrder(m) }
                let pinned = ClipSelect.allPinned(m)
                act(pinned ? "pin.slash" : "pin.fill", pinned ? "Bỏ ghim" : "Ghim",
                    help: pinned ? "Bỏ ghim cả nhóm" : "Ghim cả nhóm") { ClipSelect.togglePin(m) }
                act("lock.fill", "Riêng tư", help: "Cất cả nhóm vào Riêng tư (khoá bằng vân tay)") { ClipSelect.toPrivate(m) }
            } else {
                act("lock.open", "Bỏ khỏi Riêng tư", help: "Đưa cả nhóm về Bộ nhớ tạm thường") { ClipSelect.moveOut(m) }
            }
            act("trash", "Xoá", tint: .red, help: vault ? "Xoá hẳn cả nhóm khỏi Riêng tư" : "Xoá cả nhóm khỏi lịch sử") {
                ClipSelect.delete(m)
            }
            Spacer(minLength: 4)
            if large && n < m.visibleClips.count {
                act(nil, "Chọn hết", help: "⌘A") { ClipSelect.selectAll(m) }
            }
            Button { ClipSelect.clear(m) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: large ? 12 : 10.5, weight: .bold))
                    .frame(width: large ? 28 : 24, height: large ? 28 : 24)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(HoverPlain())
            .help("Bỏ chọn (Esc)")
        }
        .padding(.vertical, 2)
    }

    private func act(_ symbol: String?, _ title: String, tint: Color? = nil, help: String,
                     _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: large ? 11.5 : 10, weight: .bold)) }
                Text(title).font(.system(size: large ? 12.5 : 11, weight: .semibold)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(tint ?? Color.white)
            .padding(.horizontal, large ? 11 : 8)
            .padding(.vertical, large ? 6 : 4)
            .background(Capsule().fill((tint ?? Color.white).opacity(tint == nil ? 0.1 : 0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverPlain())
        .help(help)
    }
}

/// Menu chuột phải khi bấm vào một thẻ nằm trong nhóm đang chọn: làm cho cả nhóm.
struct ClipSelectionMenu: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        let n = ClipSelect.items(m).count
        let vault = m.clipFilter == .vault
        Button("Chép gộp \(n) mục") {
            if ClipSelect.copyJoined(m) > 0 { ClipSelect.clear(m) }
        }
        if !vault {
            Button("Copy liên tục \(n) mục (⌘V dán lần lượt)") { ClipSelect.pasteInOrder(m) }
            Button(ClipSelect.allPinned(m) ? "Bỏ ghim \(n) mục" : "Ghim \(n) mục") { ClipSelect.togglePin(m) }
            Button("Chuyển \(n) mục vào Riêng tư 🔒") { ClipSelect.toPrivate(m) }
        } else {
            Button("Bỏ \(n) mục khỏi Riêng tư") { ClipSelect.moveOut(m) }
        }
        Divider()
        Button("Bỏ chọn") { ClipSelect.clear(m) }
        Button(vault ? "Xoá hẳn \(n) mục" : "Xoá \(n) mục") { ClipSelect.delete(m) }
    }
}
