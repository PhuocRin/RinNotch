// RinNotch — viên "Đã chép" hiện ngay dưới tai thỏ mỗi lần copy.
// Nằm trong một cửa sổ riêng để không đụng tới tai thỏ (dạng gọn nhạc, hẹn giờ vẫn giữ nguyên).
// Rê chuột vào thì giữ lại và hiện nút Ghim / Dịch / Xoá.

import AppKit
import SwiftUI

@MainActor
final class CopyToast: ObservableObject {
    static let shared = CopyToast()

    @Published var item: ClipItem?
    @Published var showID = UUID()
    @Published var hovering = false
    @Published var notchHeight: CGFloat = 32
    /// Đang Copy liên tục thì hiện "Thêm #3" màu cam thay cho "Đã chép".
    @Published var stackIndex: Int?
    var pillSize: CGSize = .zero

    private var panel: NotchPanel?
    private var hideWork: DispatchWorkItem?
    private static let panelSize = CGSize(width: 520, height: 140)

    func setup() {
        let p = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        let host = NSHostingView(rootView: CopyToastView(t: self))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        panel = p
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CopyToast.shared.layout() }
        }
    }

    func layout() {
        let g = NotchGeometry.current()
        notchHeight = g.height
        let f = g.screenFrame
        panel?.setFrame(CGRect(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height,
                               width: Self.panelSize.width, height: Self.panelSize.height), display: false)
    }

    /// Vùng viên thuốc trên màn hình (để biết chuột có đang ở trên nó không).
    private var pillRect: CGRect {
        guard let f = panel?.frame else { return .zero }
        let w = max(pillSize.width, 60), h = max(pillSize.height, 24)
        return CGRect(x: f.midX - w / 2, y: f.maxY - notchHeight - 8 - h, width: w, height: h).insetBy(dx: -4, dy: -4)
    }

    func show(_ item: ClipItem, model m: NotchModel) {
        guard Prefs.showCopyToast, !m.hidden, !m.expanded, m.transient == nil, m.keyboardLockUntil == nil else { return }
        guard let panel else { return }
        if self.item == nil { panel.orderFrontRegardless() }
        hovering = false
        panel.ignoresMouseEvents = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            self.item = item
            stackIndex = m.stack?.count
            showID = UUID()
        }
        scheduleHide(after: 1.6)
    }

    func hide() {
        hideWork?.cancel()
        guard item != nil else { return }
        hovering = false
        panel?.ignoresMouseEvents = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { item = nil }
        let shownID = showID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.item == nil, self.showID == shownID else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func scheduleHide(after s: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.hide()
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    /// Gọi từ theo dõi chuột của tai thỏ. Chỉ nhận chuột khi chuột nằm trên viên thuốc,
    /// chỗ còn lại của cửa sổ vẫn để click xuyên qua.
    func mouseMoved(_ p: NSPoint) {
        guard item != nil else { return }
        let inside = pillRect.contains(p)
        guard inside != hovering else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { hovering = inside }
        panel?.ignoresMouseEvents = !inside
        if inside { hideWork?.cancel() } else { scheduleHide(after: 0.7) }
    }

    func pin() {
        guard let item else { return }
        ClipboardWatcher.shared?.togglePin(item)
        objectWillChange.send()
    }

    func translate() {
        guard let text = item?.text else { return }
        hide()
        TranslateModel.shared.start(text: text)
    }

    func delete() {
        guard let item else { return }
        ClipboardWatcher.shared?.remove(item)
        hide()
    }
}

struct CopyToastView: View {
    @ObservedObject var t: CopyToast

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: t.notchHeight + 8)
            if let item = t.item {
                CopyPill(item: item, hovering: t.hovering, pinned: ClipboardWatcher.shared?.isPinned(item) ?? false,
                         stackIndex: t.stackIndex, t: t)
                    .id(t.showID)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { t.pillSize = g.size }
                            .onChange(of: g.size) { _, s in t.pillSize = s }
                    })
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.82, anchor: .top)).combined(with: .offset(y: -10)),
                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)).combined(with: .offset(y: -6))
                    ))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

struct CopyPill: View {
    let item: ClipItem
    let hovering: Bool
    let pinned: Bool
    let stackIndex: Int?
    let t: CopyToast
    @State private var ripple = false

    private var accent: Color { stackIndex != nil ? Color.orange : Color(red: 0.35, green: 0.9, blue: 0.5) }

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppIcons.icon(item.sourceID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            preview
            if hovering {
                HStack(spacing: 4) {
                    action(pinned ? "pin.slash" : "pin", pinned ? "Bỏ ghim" : "Ghim") { t.pin() }
                    if item.text != nil { action("character.bubble", "Dịch") { t.translate() } }
                    action("trash", "Xoá") { t.delete() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            } else {
                Text(stackIndex.map { "Thêm #\($0)" } ?? "Đã chép")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        // Gợn viền xanh lan ra lúc vừa chép.
        .background(
            Capsule()
                .stroke(accent.opacity(ripple ? 0 : 0.7), lineWidth: ripple ? 1 : 2)
                .scaleEffect(x: ripple ? 1.18 : 1, y: ripple ? 1.9 : 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .foregroundStyle(.white)
        .fixedSize()
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.05)) { ripple = true }
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(item.preview).font(.system(size: 12, weight: .medium)).lineLimit(1)
        case .files(let urls):
            Image(systemName: "doc.fill").font(.system(size: 11))
            Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file")
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 210, alignment: .leading)
        case .text(let s):
            if item.category == .color, let c = ClipParse.color(s) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c)).frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3)))
            }
            Text(item.category == .link ? (item.linkTitle ?? ClipParse.link(s)?.host ?? item.preview) : item.preview)
                .font(.system(size: 12, weight: .medium, design: item.category == .code ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 230, alignment: .leading)
        }
    }

    private func action(_ symbol: String, _ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
