// RinNotch — Copy liên tục: nhấn ⌃ hai lần để bật, copy nhiều thứ liên tiếp, rồi mỗi lần ⌘V dán lần lượt
// từng thứ theo đúng thứ tự đã copy. Nhấn ⌃ hai lần nữa để tắt (dán hết thì tự tắt).
//
// Cách làm:
// - Nhận ⌃ hai lần: một event tap CHỈ nhận sự kiện phím bổ trợ (⌃ ⌘ ⌥ ⇧), không nhận phím chữ, nên không chạy theo
//   mỗi lần gõ. Có phím / bấm chuột / cuộn xen giữa (⌃Space đổi bộ gõ, ⌃-click…) thì hỏi đồng hồ của hệ thống
//   (`secondsSinceLastEventType`, đếm cả phím bị phím tắt app khác nuốt) và bỏ qua.
// - Dán lần lượt: chỉ khi đang bật mới gắn thêm một event tap chặn được (defaultTap) cho phím thường.
//   Thấy ⌘V thì đặt bộ nhớ tạm thành mục kế tiếp NGAY TRƯỚC khi app kia nhận phím, rồi cho phím đi tiếp.
// - Cả hai cần quyền Trợ năng (đã dùng cho Dịch nhanh và Lau bàn phím).

import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteStack {
    static let shared = PasteStack()
    weak var model: NotchModel?

    private var listenTap: CFMachPort?
    private var listenSource: CFRunLoopSource?
    private var pasteTap: CFMachPort?
    private var pasteSource: CFRunLoopSource?
    private var trustObserver: NSObjectProtocol?

    // Nhận ⌃ hai lần
    private var ctrlDownAt: TimeInterval?
    private var lastCtrlTap: TimeInterval?
    private var firstTapAt: TimeInterval?

    var active: Bool { model?.stack != nil }

    func setup(model: NotchModel) {
        self.model = model
        refresh()
        // Người dùng bật quyền Trợ năng lúc app đang chạy: macOS phát thông báo này, gắn lại tap.
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { PasteStack.shared.refresh() }
            }
        }
    }

    /// Gắn / gỡ phần nghe ⌃ hai lần theo Cài đặt và quyền Trợ năng.
    func refresh() {
        if Prefs.stackDoubleControl && Access.trusted {
            installListen()
        } else {
            removeListen()
        }
    }

    // MARK: Bật / tắt

    func toggle() {
        if active { stop(.user) } else { start() }
    }

    func start() {
        guard let m = model, !active else { return }
        guard Access.trusted else {
            Access.prompt()
            // Đang bung thì banner không hiện được: thu lại trước.
            if m.expanded { AppDelegate.shared?.controller.collapse() }
            m.showTransient(.message(symbol: "hand.raised", title: "Copy liên tục cần quyền Trợ năng",
                                     detail: "Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → RinNotch"), seconds: 5)
            return
        }
        guard installPasteTap() else { return }
        m.stack = []
        m.stackPasted = 0
        if m.expanded { AppDelegate.shared?.controller.collapse() }
        m.showTransient(.message(symbol: "square.stack.3d.up.fill", title: "Copy liên tục: đã bật",
                                 detail: "Copy từng thứ, rồi ⌘V dán lần lượt · nhấn ⌃ hai lần để tắt"), seconds: 2.5)
        Diag.log("Copy liên tục: bật")
    }

    enum StopReason { case user, done, quit }

    func stop(_ reason: StopReason) {
        removePasteTap()
        guard let m = model, let s = m.stack else { return }
        let pasted = m.stackPasted
        m.stack = nil
        m.stackPasted = 0
        Diag.log("Copy liên tục: tắt (\(pasted)/\(s.count))")
        switch reason {
        case .done:
            m.showTransient(.message(symbol: "checkmark.circle.fill", title: "Đã dán hết \(s.count) mục",
                                     detail: "Copy liên tục đã tắt"), seconds: 2.5)
        case .user:
            m.showTransient(.message(symbol: "square.stack.3d.up.slash", title: "Đã tắt Copy liên tục",
                                     detail: s.isEmpty ? "Chưa copy mục nào" : "Đã dán \(pasted)/\(s.count) mục"), seconds: 2.5)
        case .quit:
            break
        }
    }

    /// Bộ nhớ tạm vừa có mục mới (ClipboardWatcher gọi).
    func collect(_ item: ClipItem) {
        guard let m = model, m.stack != nil else { return }
        m.stack?.append(item)
    }

    // MARK: ⌘V

    fileprivate func pasteKey() {
        guard let m = model, m.stack != nil else { return }
        // Vừa ⌘C xong bấm ⌘V liền: lấy ngay mục mới chưa kịp ghi.
        ClipboardWatcher.shared?.checkNow()
        guard let s = m.stack, m.stackPasted < s.count else { return }
        ClipboardWatcher.shared?.writeQuietly(s[m.stackPasted])
        m.stackPasted += 1
        if m.stackPasted >= s.count {
            // Để app kia đọc xong bộ nhớ tạm rồi mới tắt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard let m = PasteStack.shared.model, let s = m.stack, m.stackPasted >= s.count else { return }
                    PasteStack.shared.stop(.done)
                }
            }
        }
    }

    // MARK: Event tap

    private func installListen() {
        guard listenTap == nil else { return }
        // Chỉ phím bổ trợ (rất ít sự kiện). defaultTap thay cho listenOnly: chỉ cần quyền Trợ năng, không cần thêm
        // quyền Theo dõi đầu vào; callback chỉ so vài con số rồi cho sự kiện đi tiếp ngay.
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: stackListenCallback, userInfo: nil) else {
            Diag.log("Copy liên tục: không tạo được tap nghe ⌃")
            return
        }
        listenTap = t
        listenSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), listenSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func removeListen() {
        if let t = listenTap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = listenSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        listenTap = nil
        listenSource = nil
        resetTaps()
    }

    private func resetTaps() {
        ctrlDownAt = nil
        lastCtrlTap = nil
        firstTapAt = nil
    }

    /// Có phím thường, bấm chuột hay cuộn nào từ thời điểm `t` (giây kể từ lúc máy chạy) tới giờ không.
    private func otherInput(since t: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - t
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed - 0.005 }
    }

    private func installPasteTap() -> Bool {
        guard pasteTap == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: stackPasteCallback, userInfo: nil) else {
            Diag.log("Copy liên tục: không tạo được tap ⌘V")
            return false
        }
        pasteTap = t
        pasteSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), pasteSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func removePasteTap() {
        if let t = pasteTap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = pasteSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        pasteTap = nil
        pasteSource = nil
    }

    fileprivate func handleListen(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = listenTap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let f = event.flags
        let others = f.intersection([.maskCommand, .maskShift, .maskAlternate, .maskSecondaryFn])
        let ctrl = f.contains(.maskControl)
        if ctrl && others.isEmpty {
            if ctrlDownAt == nil { ctrlDownAt = now }
        } else if !ctrl, let down = ctrlDownAt, others.isEmpty {
            ctrlDownAt = nil
            // Giữ ⌃ lâu, hoặc có phím / chuột xen giữa lúc giữ (⌃C, ⌃Space, ⌃-click…): không tính.
            guard now - down < 0.35, !otherInput(since: down) else { resetTaps(); return }
            if let last = lastCtrlTap, now - last < 0.45, let first = firstTapAt, !otherInput(since: first) {
                resetTaps()
                toggle()
            } else {
                lastCtrlTap = now
                firstTapAt = down
            }
        } else {
            // Đang giữ thêm phím bổ trợ khác: không tính.
            resetTaps()
        }
    }

    fileprivate func handlePaste(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = pasteTap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        // ⌘V do chính RinNotch giả lập (Dịch nhanh → Thay chỗ chọn) thì để yên, không đổi sang mục kế.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        let f = event.flags
        guard f.contains(.maskCommand), f.intersection([.maskShift, .maskAlternate, .maskControl]).isEmpty else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
        if code == Int64(kVK_ANSI_V) || chars == "v" {
            pasteKey()
        } else if code == Int64(kVK_ANSI_C) || chars == "c" || code == Int64(kVK_ANSI_X) || chars == "x" {
            // Vừa copy: hỏi bộ nhớ tạm sớm hơn nhịp 0,6 giây để thẻ đếm cập nhật ngay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { ClipboardWatcher.shared?.checkNow() }
            }
        }
    }
}

private func stackListenCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated { PasteStack.shared.handleListen(type, event) }
    return Unmanaged.passUnretained(event)
}

private func stackPasteCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated { PasteStack.shared.handlePaste(type, event) }
    return Unmanaged.passUnretained(event)
}
