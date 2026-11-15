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

    /// Kiểm ngay, rồi kiểm lại hai lần: lúc vừa đổi Space, danh sách cửa sổ có khi chưa cập nhật kịp
    /// (hiệu ứng trượt vào toàn màn hình mất khoảng nửa giây).
    func checkSoon() {
        pending.forEach { $0.cancel() }
        pending = []
        check()
        for delay in [0.45, 1.2] {
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
            pending.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    func check() {
        guard let g = geometry(), Prefs.hideInFullscreen, g.screenFrame.width > 0 else {
            set(false)
            return
        }
        let inset = NSScreen.screens.first(where: { $0.frame == g.screenFrame })?.safeAreaInsets.top ?? 0
        set(Self.isFullscreen(on: g.screenFrame, notchInset: inset))
    }

    private func set(_ v: Bool) {
        guard model.fullscreenHidden != v else { return }
        model.fullscreenHidden = v
        Diag.log("Toàn màn hình: \(v ? "ẩn" : "hiện lại") tai thỏ")
        if v { CopyToast.shared.hide() }
    }

    /// Cửa sổ thường (layer 0) đứng trước nhất trên màn hình này có phủ kín cả màn hình không.
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
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  r.width > 100, r.height > 100,
                  r.intersection(target).width > target.width / 2 else { continue }
            // Cửa sổ đầu tiên (đứng trước nhất) trên màn hình này: phủ kín bề ngang, chạm đáy, mép trên ở sát mép màn hình
            // (hoặc ngay dưới dải tai thỏ) = toàn màn hình.
            return abs(r.minX - target.minX) < 2 && abs(r.width - target.width) < 2
                && abs(r.maxY - target.maxY) < 2
                && r.minY >= target.minY - 1 && r.minY <= target.minY + notchInset + 2
        }
        return false
    }
}
