// RinNotch — chỉnh nhanh cửa sổ: bấm một nút trong mục Công cụ để đưa cửa sổ của app đang dùng sang nửa trái,
// nửa phải, một góc, giữa màn hình, phóng to, sang màn hình kế bên, hoặc trả lại cỡ cũ.
// Dùng quyền Trợ năng (AXUIElement) để đọc / đặt vị trí và cỡ cửa sổ, giống các app xếp cửa sổ khác.
// Không gán phím tắt: macOS 15 trở lên đã có phím xếp cửa sổ riêng (Fn + ⌃ + mũi tên), tránh trùng.

import AppKit
import SwiftUI

enum WindowLayout: String, CaseIterable, Identifiable {
    case left, right, top, bottom, maximize, center
    case topLeft, topRight, bottomLeft, bottomRight, nextScreen, restore
    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Nửa trái"
        case .right: return "Nửa phải"
        case .top: return "Nửa trên"
        case .bottom: return "Nửa dưới"
        case .maximize: return "Phóng to"
        case .center: return "Giữa màn hình"
        case .topLeft: return "Góc trên trái"
        case .topRight: return "Góc trên phải"
        case .bottomLeft: return "Góc dưới trái"
        case .bottomRight: return "Góc dưới phải"
        case .nextScreen: return "Sang màn hình kế bên"
        case .restore: return "Trả lại cỡ cũ"
        }
    }

    /// Vùng trên màn hình, gốc ở góc trên bên trái, đơn vị 0…1.
    var unit: CGRect? {
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: return CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .nextScreen, .restore: return nil
        }
    }

    var symbol: String? {
        switch self {
        case .nextScreen: return "rectangle.portrait.and.arrow.right"
        case .restore: return "arrow.uturn.backward"
        default: return nil
        }
    }

    static let rows: [[WindowLayout]] = [
        [.left, .right, .top, .bottom, .maximize, .center],
        [.topLeft, .topRight, .bottomLeft, .bottomRight, .nextScreen, .restore],
    ]
}

@MainActor
enum WindowSnap {
    /// Cỡ cũ của các cửa sổ vừa chỉnh (để Trả lại), giữ vài cửa sổ gần nhất.
    private static var saved: [(window: AXUIElement, frame: CGRect)] = []
    /// Khung RinNotch vừa đặt cho từng cửa sổ: cửa sổ còn đúng khung này thì không ghi đè cỡ cũ.
    private static var applied: [(window: AXUIElement, frame: CGRect)] = []

    static func apply(_ layout: WindowLayout, model m: NotchModel) {
        guard Access.trusted else {
            Access.prompt()
            m.flashToolStatus("Cần quyền Trợ năng: Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → RinNotch")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let win = focusedWindow(app.processIdentifier), let current = frame(of: win) else {
            m.flashToolStatus("Không thấy cửa sổ nào của app đang dùng")
            return
        }
        if bool(win, "AXFullScreen") {
            m.flashToolStatus("Cửa sổ đang toàn màn hình, thoát toàn màn hình trước nha")
            return
        }

        var target: CGRect
        switch layout {
        case .restore:
            guard let old = saved.last(where: { CFEqual($0.window, win) })?.frame else {
                m.flashToolStatus("Cửa sổ này chưa được chỉnh nên không có cỡ cũ")
                return
            }
            target = old
        case .nextScreen:
            let screens = NSScreen.screens
            guard screens.count > 1, let from = screen(for: current), let i = screens.firstIndex(of: from) else {
                m.flashToolStatus("Chỉ có một màn hình")
                return
            }
            let a = axVisible(from), b = axVisible(screens[(i + 1) % screens.count])
            // Giữ tỉ lệ vị trí và cỡ so với màn hình cũ.
            let rx = (current.minX - a.minX) / a.width, ry = (current.minY - a.minY) / a.height
            let w = min(current.width / a.width, 1) * b.width, h = min(current.height / a.height, 1) * b.height
            target = CGRect(x: b.minX + rx * b.width, y: b.minY + ry * b.height, width: w, height: h)
        default:
            guard let unit = layout.unit, let s = screen(for: current) else { return }
            let v = axVisible(s)
            target = CGRect(x: v.minX + unit.minX * v.width, y: v.minY + unit.minY * v.height,
                            width: unit.width * v.width, height: unit.height * v.height).integral
        }

        if layout != .restore { remember(win, current) }
        set(win, target)
        if let real = frame(of: win) {
            applied.removeAll { CFEqual($0.window, win) }
            applied.append((win, real))
        }
        if layout == .restore { saved.removeAll { CFEqual($0.window, win) } }
        Diag.log("Chỉnh cửa sổ: \(layout.rawValue) · \(app.localizedName ?? "")")
    }

    /// Ghi cỡ cũ, trừ khi cửa sổ vẫn đang ở đúng khung RinNotch vừa đặt (bấm liên tiếp nhiều kiểu).
    private static func remember(_ win: AXUIElement, _ current: CGRect) {
        if let a = applied.last(where: { CFEqual($0.window, win) }), a.frame.equalTo(current),
           saved.contains(where: { CFEqual($0.window, win) }) { return }
        saved.removeAll { CFEqual($0.window, win) }
        saved.append((win, current))
        if saved.count > 12 { saved.removeFirst(saved.count - 12) }
    }

    // MARK: AX

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
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
        // Đặt vị trí trước, rồi cỡ, rồi vị trí lần nữa: có app không cho to hơn phần còn lại của màn hình
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

/// Hình nhỏ của một kiểu xếp: khung màn hình, phần sáng là chỗ cửa sổ sẽ nằm.
struct LayoutGlyph: View {
    let layout: WindowLayout
    var body: some View {
        if let symbol = layout.symbol {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        } else if let u = layout.unit {
            let w: CGFloat = 20, h: CGFloat = 13
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.white.opacity(0.55), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(u.width * (w - 4), 2), height: max(u.height * (h - 4), 2))
                    .offset(x: 2 + u.minX * (w - 4), y: 2 + u.minY * (h - 4))
            }
            .frame(width: w, height: h)
        }
    }
}

struct WindowSnapButton: View {
    let layout: WindowLayout
    let m: NotchModel
    @State private var hovered = false

    var body: some View {
        Button { WindowSnap.apply(layout, model: m) } label: {
            LayoutGlyph(layout: layout)
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered ? 0.2 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(hovered ? 0.25 : 0), lineWidth: 1))
                .scaleEffect(hovered ? 1.08 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(layout.title)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hovered = inside } }
    }
}
