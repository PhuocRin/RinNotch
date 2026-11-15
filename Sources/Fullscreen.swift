// Tự ẩn tai thỏ khi app đang toàn màn hình, CHỈ trên màn hình không có tai thỏ thật
// (MacBook đời cũ, màn hình rời, iPad làm màn hình phụ). Ở đó viên thuốc / tai thỏ giả nằm đè lên nội dung app
// (thanh địa chỉ Safari, thanh tab Chrome…). MacBook có tai thỏ thì app toàn màn hình đã nằm dưới tai thỏ, không cần ẩn.
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
        guard let g = geometry(), Prefs.hideInFullscreen, !g.physical, g.screenFrame.width > 0 else {
            set(false)
            return
        }
        set(Self.isFullscreen(on: g.screenFrame))
    }

    private func set(_ v: Bool) {
        guard model.fullscreenHidden != v else { return }
        model.fullscreenHidden = v
        Diag.log("Toàn màn hình: \(v ? "ẩn" : "hiện lại") tai thỏ")
        if v { CopyToast.shared.hide() }
    }

    /// Cửa sổ thường (layer 0) đứng trước nhất trên màn hình này có phủ kín cả màn hình không.
    static func isFullscreen(on frame: CGRect) -> Bool {
        // Toạ độ danh sách cửa sổ: gốc trên trái của màn hình chính.
        guard let main = NSScreen.screens.first else { return false }
        let target = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  r.width > 100, r.height > 100,
                  r.intersection(target).width > target.width / 2 else { continue }
            // Cửa sổ đầu tiên (đứng trước nhất) trên màn hình này: phủ kín cả màn hình, kể cả chỗ thanh menu = toàn màn hình.
            return abs(r.minX - target.minX) < 2 && abs(r.minY - target.minY) < 2
                && abs(r.width - target.width) < 2 && abs(r.height - target.height) < 2
        }
        return false
    }
}
