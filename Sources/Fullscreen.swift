// Tự ẩn tai thỏ khi app đang toàn màn hình, trên mọi màn hình (Phước chốt 15/11/2026).
// Màn hình không tai thỏ: viên thuốc / tai thỏ giả nằm đè lên nội dung app (thanh địa chỉ Safari, thanh tab Chrome…).
// MacBook có tai thỏ: app toàn màn hình nằm dưới tai thỏ, ẩn cho gọn (dạng gọn nhạc, hẹn giờ… không còn nổi trên dải đen).
//
// Dò theo sự kiện, không chạy nhịp lặp: đổi Space (vào / thoát toàn màn hình là đổi Space), đổi app, app thoát,
// đổi màn hình. Mỗi lần chỉ đọc danh sách cửa sổ một lần (chủ cửa sổ + khung, không cần quyền Ghi màn hình).

import AppKit

@MainActor
final class FullscreenWatcher {
    private let model: NotchModel
    private let geometry: () -> NotchGeometry?
    private var pending: [DispatchWorkItem] = []

    init(model: NotchModel, geometry: @escaping () -> NotchGeometry?) {
        self.model = model
        self.geometry = geometry
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
        ]
        for n in names {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSoon() }
            }
        }
    }

    /// Kiểm ngay, rồi kiểm lại ba lần: lúc vừa đổi Space, danh sách cửa sổ có khi chưa cập nhật kịp
    /// (hiệu ứng trượt vào toàn màn hình mất khoảng nửa giây, trình duyệt nhân Chromium có khi lâu hơn).
    func checkSoon() {
        pending.forEach { $0.cancel() }
        pending = []
        check()
        for delay in [0.45, 1.2, 2.5] {
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
            pending.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    func check() {
        guard let g = geometry(), Prefs.hideInFullscreen, g.screenFrame.width > 0 else {
            set(false, why: nil)
            return
        }
        let inset = NSScreen.screens.first(where: { $0.frame == g.screenFrame })?.safeAreaInsets.top ?? 0
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "?"
        // 1. Có quyền Trợ năng: hỏi thẳng cửa sổ đang dùng có đang toàn màn hình không (chính xác, không phải đoán).
        if let pid = app?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier,
           Self.axFullscreen(pid: pid, on: g.screenFrame) == true {
            set(true, why: "\(name), Trợ năng")
            return
        }
        // 2. Không có quyền, hoặc app tự phủ kín màn hình mà không dùng chế độ toàn màn hình của macOS
        //    (trình chiếu, game): đoán theo khung cửa sổ.
        set(Self.isFullscreen(on: g.screenFrame, notchInset: inset),
            why: "\(name), \(AXIsProcessTrusted() ? "Trợ năng + " : "")khung cửa sổ")
    }

    private var lastWhy = ""
    private func set(_ v: Bool, why: String?) {
        if let why {
            // Ghi mỗi khi kết quả hoặc app đổi (không ghi lặp), để người dùng báo lỗi thì biết ngay app nào, đo bằng cách nào.
            let line = "\(v ? "toàn màn hình" : "không") (\(why))"
            if line != lastWhy { Diag.log("Dò toàn màn hình: \(line)"); lastWhy = line }
        }
        guard model.fullscreenHidden != v else { return }
        model.fullscreenHidden = v
        Diag.log("Toàn màn hình: \(v ? "ẩn" : "hiện lại") tai thỏ")
        if v { CopyToast.shared.hide() }
    }

    /// Hỏi Trợ năng: cửa sổ đang dùng (hoặc cửa sổ chính) của app có thuộc tính AXFullScreen = true và nằm trên màn hình này.
    /// nil = không hỏi được (chưa có quyền, app không trả lời) → dùng cách đoán theo khung cửa sổ.
    static func axFullscreen(pid: pid_t, on frame: CGRect) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)   // app treo thì không kéo RinNotch treo theo
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) != .success || win == nil {
            guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &win) == .success, win != nil else { return nil }
        }
        let w = win as! AXUIElement
        AXUIElementSetMessagingTimeout(w, 0.25)
        var fs: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs) == .success,
              let on = fs as? Bool else { return nil }
        guard on else { return false }
        // Cửa sổ toàn màn hình phải nằm trên đúng màn hình RinNotch đang hiện (nhiều màn hình).
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posV) == .success,
           AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeV) == .success,
           let pv = posV, let sv = sizeV {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
            guard let main = NSScreen.screens.first else { return true }
            let target = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            let r = CGRect(origin: pos, size: size)
            if r.width > 0, r.intersection(target).width < target.width / 2 { return false }
        }
        return true
    }

    /// Đoán khi không có quyền Trợ năng: app đứng trước nhất trên màn hình này có cửa sổ nào phủ kín màn hình không.
    /// Xét MỌI cửa sổ của app đó, không chỉ cửa sổ đầu tiên: Chrome, Brave, Edge (nhân Chromium) khi toàn màn hình
    /// có thêm một cửa sổ riêng nằm trên cùng chứa thanh tab + thanh công cụ trượt xuống, không phủ kín màn hình.
    /// Màn hình có tai thỏ: app toàn màn hình mặc định nằm dưới dải tai thỏ (chừa `notchInset` ở trên), giống hệt
    /// một cửa sổ phóng to khi Dock ẩn, nên phải xem thêm thanh menu: toàn màn hình thì thanh menu không hiện.
    static func isFullscreen(on frame: CGRect, notchInset: CGFloat) -> Bool {
        // Toạ độ danh sách cửa sổ: gốc trên trái của màn hình chính.
        guard let main = NSScreen.screens.first else { return false }
        let target = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let topStrip = CGRect(x: target.minX, y: target.minY, width: target.width, height: max(notchInset, 24))
        if notchInset > 0 {
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == menuLevel,
                      let dict = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                      r.intersects(topStrip), r.width > target.width / 2 else { continue }
                return false   // thanh menu đang hiện trên màn hình này → không phải toàn màn hình
            }
        }
        var owner: Int?
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid_t(pid) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  r.width > 100, r.intersection(target).width > target.width / 2 else { continue }
            // App của cửa sổ đứng trước nhất trên màn hình này; chỉ xét cửa sổ của app đó.
            if owner == nil { owner = pid }
            guard pid == owner else { continue }
            // Phủ kín bề ngang, chạm đáy, mép trên ở sát mép màn hình (hoặc ngay dưới dải tai thỏ) = toàn màn hình.
            if abs(r.minX - target.minX) < 2 && abs(r.width - target.width) < 2
                && abs(r.maxY - target.maxY) < 2
                && r.minY >= target.minY - 1 && r.minY <= target.minY + notchInset + 2 { return true }
        }
        return false
    }
}
