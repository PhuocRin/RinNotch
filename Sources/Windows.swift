// RinNotch — mục Cửa sổ (⌃⇧9): chỉnh nhanh cửa sổ của app đang dùng (nửa, góc, ⅓, ⅔, phóng to, giữa,
// sang màn hình kế bên) và xếp nhiều app cùng lúc (2 app, 3 app, 3 cột, 4 góc, xếp hết), giống menu
// "Lấp đầy & sắp xếp" ở nút xanh của macOS nhưng bấm một lần là xong, chạy cả trên macOS 14.
//
// Cách làm: quyền Trợ năng (AXUIElement) để đọc / đặt vị trí và cỡ cửa sổ. Thứ tự cửa sổ trước sau lấy từ
// CGWindowList (chỉ đọc chủ cửa sổ và khung, không đọc tên cửa sổ nên không cần quyền Ghi màn hình).
// Không gán phím cho từng kiểu: macOS 15 trở lên đã có Fn + ⌃ + mũi tên để xếp cửa sổ, tránh trùng.

import AppKit
import SwiftUI

// MARK: - Kiểu xếp

/// Chỉnh một cửa sổ (của app đang dùng).
enum WindowLayout: String, CaseIterable, Identifiable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds, maximize, center, nextScreen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Nửa trái"
        case .right: return "Nửa phải"
        case .top: return "Nửa trên"
        case .bottom: return "Nửa dưới"
        case .topLeft: return "Góc trên trái"
        case .topRight: return "Góc trên phải"
        case .bottomLeft: return "Góc dưới trái"
        case .bottomRight: return "Góc dưới phải"
        case .leftThird: return "⅓ trái"
        case .centerThird: return "⅓ giữa"
        case .rightThird: return "⅓ phải"
        case .leftTwoThirds: return "⅔ trái"
        case .rightTwoThirds: return "⅔ phải"
        case .maximize: return "Phóng to"
        case .center: return "Giữa màn hình"
        case .nextScreen: return "Sang màn hình kế bên"
        }
    }

    /// Vùng trên màn hình, gốc ở góc trên bên trái, đơn vị 0…1.
    var unit: CGRect? {
        let t: CGFloat = 1.0 / 3
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: t, height: 1)
        case .centerThird: return CGRect(x: t, y: 0, width: t, height: 1)
        case .rightThird: return CGRect(x: 2 * t, y: 0, width: t, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2 * t, height: 1)
        case .rightTwoThirds: return CGRect(x: t, y: 0, width: 2 * t, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: return CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        case .nextScreen: return nil
        }
    }

    static let rows: [[WindowLayout]] = [
        [.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight],
        [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds, .maximize, .center, .nextScreen],
    ]
}

/// Xếp nhiều app cùng lúc. App dùng gần nhất vào ô đầu (trái / trên).
enum MultiLayout: String, CaseIterable, Identifiable {
    case twoSide, twoStack, threeMain, threeColumns, threeRows, fourGrid, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoSide: return "2 cạnh nhau"
        case .twoStack: return "2 trên dưới"
        case .threeMain: return "3 app"
        case .threeColumns: return "3 cột dọc"
        case .threeRows: return "3 hàng ngang"
        case .fourGrid: return "4 góc"
        case .all: return "Xếp hết"
        }
    }

    /// Số app cần; nil = mọi cửa sổ đang mở trên màn hình (tối đa 9).
    var count: Int? {
        switch self {
        case .twoSide, .twoStack: return 2
        case .threeMain, .threeColumns, .threeRows: return 3
        case .fourGrid: return 4
        case .all: return nil
        }
    }

    func slots(_ n: Int) -> [CGRect] {
        let t: CGFloat = 1.0 / 3
        switch self {
        case .twoSide: return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .twoStack: return [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .threeMain: return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                                 CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .threeColumns: return [CGRect(x: 0, y: 0, width: t, height: 1), CGRect(x: t, y: 0, width: t, height: 1),
                                    CGRect(x: 2 * t, y: 0, width: t, height: 1)]
        case .threeRows: return [CGRect(x: 0, y: 0, width: 1, height: t), CGRect(x: 0, y: t, width: 1, height: t),
                                 CGRect(x: 0, y: 2 * t, width: 1, height: t)]
        case .fourGrid: return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .all: return Self.grid(n)
        }
    }

    /// Lưới cho n cửa sổ: số cột ≈ căn bậc hai, hàng cuối thiếu thì các ô kéo rộng ra cho kín.
    static func grid(_ n: Int) -> [CGRect] {
        guard n > 0 else { return [] }
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        var out: [CGRect] = []
        for r in 0..<rows {
            let inRow = r == rows - 1 ? n - cols * (rows - 1) : cols
            for c in 0..<inRow {
                out.append(CGRect(x: CGFloat(c) / CGFloat(inRow), y: CGFloat(r) / CGFloat(rows),
                                  width: 1 / CGFloat(inRow), height: 1 / CGFloat(rows)))
            }
        }
        return out
    }

    /// Hình minh hoạ (Xếp hết vẽ 6 ô).
    var glyphSlots: [CGRect] { slots(self == .all ? 6 : (count ?? 6)) }
}

// MARK: - Chỉnh cửa sổ

@MainActor
enum WindowSnap {
    /// Khung cũ của các cửa sổ vừa chỉnh (nút Trả lại). Bấm nhiều kiểu liên tiếp thì vẫn giữ khung gốc ban đầu.
    private static var undo: [(window: AXUIElement, frame: CGRect)] = []
    /// Khung RinNotch vừa đặt: cửa sổ còn đúng khung này nghĩa là người dùng chưa tự kéo lại.
    private static var applied: [(window: AXUIElement, frame: CGRect)] = []

    private struct Move {
        let window: AXUIElement
        let current: CGRect
        let target: CGRect
    }

    private static func ensureTrusted(_ m: NotchModel) -> Bool {
        guard Access.trusted else {
            Access.prompt()
            m.flashToolStatus("Cần quyền Trợ năng: Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → RinNotch")
            return false
        }
        return true
    }

    /// Cửa sổ đang dùng (của app đang được chọn, không phải RinNotch).
    private static func frontWindow(_ m: NotchModel) -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let win = focusedWindow(app.processIdentifier) else {
            m.flashToolStatus("Không thấy cửa sổ nào của app đang dùng")
            return nil
        }
        if bool(win, "AXFullScreen") {
            m.flashToolStatus("Cửa sổ đang toàn màn hình, thoát toàn màn hình trước nha")
            return nil
        }
        return win
    }

    static func apply(_ layout: WindowLayout, model m: NotchModel) {
        guard ensureTrusted(m), let win = frontWindow(m), let current = frame(of: win) else { return }
        var target: CGRect
        if layout == .nextScreen {
            let screens = NSScreen.screens
            guard screens.count > 1, let from = screen(for: current), let i = screens.firstIndex(of: from) else {
                m.flashToolStatus("Chỉ có một màn hình")
                return
            }
            let a = axVisible(from), b = axVisible(screens[(i + 1) % screens.count])
            // Giữ tỉ lệ vị trí và cỡ so với màn hình cũ.
            let rx = (current.minX - a.minX) / a.width, ry = (current.minY - a.minY) / a.height
            let w = min(current.width / a.width, 1) * b.width, h = min(current.height / a.height, 1) * b.height
            target = CGRect(x: b.minX + max(rx, 0) * b.width, y: b.minY + max(ry, 0) * b.height, width: w, height: h).integral
        } else {
            guard let unit = layout.unit, let s = screen(for: current) else { return }
            target = place(unit, in: axVisible(s))
        }
        commit([Move(window: win, current: current, target: target)])
        Diag.log("Cửa sổ: \(layout.rawValue) · \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "")")
    }

    static func arrange(_ layout: MultiLayout, model m: NotchModel) {
        guard ensureTrusted(m) else { return }
        let all = visibleWindows()
        guard let first = all.first, let s = screen(for: first.bounds) else {
            m.flashToolStatus("Không thấy cửa sổ nào đang mở")
            return
        }
        let limit = layout.count ?? 9
        var picked: [(AXUIElement, CGRect)] = []
        var pids = Set<pid_t>()
        for c in all where screen(for: c.bounds) == s {
            // Kiểu 2 / 3 / 4 app: mỗi app một cửa sổ (cửa sổ trên cùng của app đó). Xếp hết: mọi cửa sổ.
            if layout != .all && pids.contains(c.pid) { continue }
            guard let ax = axWindow(pid: c.pid, bounds: c.bounds), isStandard(ax), !bool(ax, "AXFullScreen") else { continue }
            pids.insert(c.pid)
            picked.append((ax, c.bounds))
            if picked.count == limit { break }
        }
        if let need = layout.count, picked.count < need {
            m.flashToolStatus("Cần mở \(need) app trên màn hình này, đang thấy \(picked.count)")
            return
        }
        guard picked.count >= (layout == .all ? 2 : 1) else {
            m.flashToolStatus("Cần ít nhất 2 cửa sổ đang mở")
            return
        }
        let v = axVisible(s)
        let slots = layout.slots(picked.count)
        let moves = zip(picked, slots).map { Move(window: $0.0, current: $0.1, target: place($1, in: v)) }
        commit(moves)
        // Đưa các cửa sổ vừa xếp lên trên cửa sổ khác (không đổi app đang dùng); app gần nhất lên trên cùng.
        for mv in moves.reversed() { AXUIElementPerformAction(mv.window, kAXRaiseAction as CFString) }
        Diag.log("Cửa sổ: xếp \(layout.rawValue) · \(moves.count) cửa sổ")
    }

    static func restore(model m: NotchModel) {
        guard ensureTrusted(m) else { return }
        guard !undo.isEmpty else {
            m.flashToolStatus("Chưa chỉnh cửa sổ nào nên không có chỗ cũ để trả")
            return
        }
        for (w, f) in undo { set(w, f) }
        undo = []
        applied = []
    }

    static func minimize(model m: NotchModel) {
        guard ensureTrusted(m), let win = frontWindow(m) else { return }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    private static func commit(_ moves: [Move]) {
        // Bấm tiếp một kiểu khác trên đúng các cửa sổ vừa xếp (chưa bị kéo tay): giữ khung gốc ban đầu cho Trả lại.
        let chained = !undo.isEmpty && moves.allSatisfy { mv in
            undo.contains { CFEqual($0.window, mv.window) }
                && applied.contains { CFEqual($0.window, mv.window) && near($0.frame, mv.current) }
        }
        if !chained { undo = moves.map { ($0.window, $0.current) } }
        if !chained { applied = [] }
        for mv in moves {
            set(mv.window, mv.target)
            applied.removeAll { CFEqual($0.window, mv.window) }
            if let real = frame(of: mv.window) { applied.append((mv.window, real)) }
        }
    }

    private static func place(_ unit: CGRect, in v: CGRect) -> CGRect {
        CGRect(x: v.minX + unit.minX * v.width, y: v.minY + unit.minY * v.height,
               width: unit.width * v.width, height: unit.height * v.height).integral
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) < 6
    }

    // MARK: Danh sách cửa sổ

    private struct OnScreen {
        let pid: pid_t
        let bounds: CGRect
    }

    /// Cửa sổ thường đang hiện, từ trên xuống dưới (cửa sổ đang dùng đứng đầu).
    private static func visibleWindows() -> [OnScreen] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        var out: [OnScreen] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  r.width >= 120, r.height >= 80 else { continue }
            if let a = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, a < 0.05 { continue }
            out.append(OnScreen(pid: pid, bounds: r))
        }
        return out
    }

    /// Tìm cửa sổ Trợ năng khớp khung với cửa sổ trong danh sách.
    private static func axWindow(pid: pid_t, bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let list = v as? [AXUIElement] else { return nil }
        var best: AXUIElement?
        var bestD = CGFloat.infinity
        for w in list {
            guard let f = frame(of: w) else { continue }
            let d = abs(f.minX - bounds.minX) + abs(f.minY - bounds.minY) + abs(f.width - bounds.width) + abs(f.height - bounds.height)
            if d < bestD { bestD = d; best = w }
        }
        return bestD < 10 ? best : nil
    }

    private static func isStandard(_ w: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &v) == .success, let s = v as? String else { return true }
        return s == (kAXStandardWindowSubrole as String)
    }

    // MARK: AX

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success, let v,
               CFGetTypeID(v) == AXUIElementGetTypeID() {
                return (v as! AXUIElement)
            }
        }
        return nil
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    /// Khung cửa sổ theo toạ độ Trợ năng (gốc góc trên trái màn hình chính, y đi xuống).
    private static func frame(of el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func set(_ el: AXUIElement, _ r: CGRect) {
        var origin = r.origin, size = r.size
        guard let pv = AXValueCreate(.cgPoint, &origin), let sv = AXValueCreate(.cgSize, &size) else { return }
        // Vị trí trước, rồi cỡ, rồi vị trí lần nữa: có app không cho to hơn phần còn lại của màn hình
        // tính từ vị trí cũ, hoặc tự đẩy cửa sổ khi đổi cỡ.
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
    }

    // MARK: Màn hình

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Vùng dùng được của màn hình (trừ thanh menu và Dock), theo toạ độ Trợ năng.
    private static func axVisible(_ s: NSScreen) -> CGRect {
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }

    /// Màn hình chứa phần lớn cửa sổ.
    private static func screen(for axFrame: CGRect) -> NSScreen? {
        let cocoa = CGRect(x: axFrame.minX, y: primaryHeight - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(cocoa).area < b.frame.intersection(cocoa).area
        } ?? NSScreen.main
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Giao diện

/// Hình nhỏ: khung màn hình, các ô sáng là chỗ cửa sổ sẽ nằm (ô đầu sáng nhất).
struct TilesGlyph: View {
    let slots: [CGRect]
    var width: CGFloat = 22
    var height: CGFloat = 15
    var tint: Color = .white

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.5), lineWidth: 1.2)
            ForEach(Array(slots.enumerated()), id: \.offset) { i, u in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint.opacity(i == 0 ? 0.95 : 0.5))
                    .frame(width: max(u.width * (width - 4) - 1, 2), height: max(u.height * (height - 4) - 1, 2))
                    .offset(x: 2 + u.minX * (width - 4) + 0.5, y: 2 + u.minY * (height - 4) + 0.5)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Ô bấm có hiệu ứng rê chuột; nhãn tên nổi phía trên.
struct SnapTile<Label: View>: View {
    let name: String?
    let width: CGFloat
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: width, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovered ? 0.18 : 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Tab.windows.tint.opacity(hovered ? 0.6 : 0), lineWidth: 1))
                .scaleEffect(hovered ? 1.06 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if hovered, let name {
                HoverTag(text: name)
                    .offset(y: -28)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovered ? 2 : 0)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = inside } }
    }
}

struct WindowsView: View {
    @ObservedObject var m: NotchModel
    @State private var front = NSWorkspace.shared.frontmostApplication
    @State private var trusted = Access.trusted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = front?.icon, front?.processIdentifier != getpid() {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(m.toolStatus != nil ? Color.orange : .white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if !trusted {
                    Button("Cấp quyền") {
                        Access.prompt()
                        AppDelegate.shared?.controller.collapse()
                        Access.openSettings()
                    }
                    .buttonStyle(PillButton(prominent: true))
                }
                Button { WindowSnap.minimize(model: m) } label: {
                    HStack(spacing: 4) { Image(systemName: "minus.rectangle"); Text("Thu nhỏ") }
                }
                .buttonStyle(PillButton())
                .help("Cất cửa sổ đang dùng xuống Dock")
                Button { WindowSnap.restore(model: m) } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.uturn.backward"); Text("Trả lại") }
                }
                .buttonStyle(PillButton())
                .help("Đưa các cửa sổ vừa chỉnh về chỗ cũ")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    caption("Cửa sổ đang dùng")
                    ForEach(Array(WindowLayout.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 5) {
                            ForEach(row) { l in
                                SnapTile(name: l.title, width: 30, action: { WindowSnap.apply(l, model: m) }) {
                                    if let u = l.unit {
                                        TilesGlyph(slots: [u], tint: Tab.windows.tint)
                                    } else {
                                        Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 12, weight: .semibold))
                                    }
                                }
                            }
                        }
                        .zIndex(1)
                    }
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    caption("Xếp nhiều app")
                    ForEach([Array(MultiLayout.allCases.prefix(4)), Array(MultiLayout.allCases.dropFirst(4))], id: \.first) { row in
                        HStack(spacing: 5) {
                            ForEach(row) { l in
                                SnapTile(name: nil, width: 66, action: { WindowSnap.arrange(l, model: m) }) {
                                    VStack(spacing: 3) {
                                        TilesGlyph(slots: l.glyphSlots, width: 26, height: 17, tint: Tab.windows.tint)
                                        Text(l.title).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            front = NSWorkspace.shared.frontmostApplication
            trusted = Access.trusted
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            front = NSWorkspace.shared.frontmostApplication
        }
    }

    private var statusText: String {
        if let s = m.toolStatus { return s }
        guard trusted else { return "Cần quyền Trợ năng để chỉnh cửa sổ" }
        guard let f = front, f.processIdentifier != getpid() else { return "Bấm vào app muốn chỉnh trước" }
        return "Đang chỉnh: \(f.localizedName ?? "")"
    }

    private func caption(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.4))
    }
}
