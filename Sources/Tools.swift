// RinNotch — mục Công cụ: lấy mã màu, giữ máy thức, khoá bàn phím để lau, báo mất mạng.

import AppKit
import SwiftUI
import IOKit.pwr_mgt
import Network
import Carbon.HIToolbox

// MARK: - Quyền Trợ năng (đọc chữ đang bôi đen, khoá bàn phím)

enum Access {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Hiện hộp thoại của macOS mời bật quyền (chỉ hiện khi chưa có quyền).
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Giữ máy thức

@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    weak var model: NotchModel?
    private var assertion: IOPMAssertionID = 0
    private var endTimer: Timer?
    private var sleepObserver: NSObjectProtocol?

    enum StopReason { case user, ended, lowBattery, sleep, quit }

    var active: Bool { assertion != 0 }

    func setup(model: NotchModel) {
        self.model = model
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if KeepAwake.shared.active && Prefs.awakeStopOnSleep { KeepAwake.shared.stop(.sleep) }
            }
        }
    }

    /// minutes = nil: giữ tới khi tắt.
    func start(minutes: Int?) {
        stop(.user, silent: true)
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "RinNotch: Giữ máy thức" as CFString, &id)
        guard r == kIOReturnSuccess else { return }
        assertion = id
        model?.keepAwakeOn = true
        model?.keepAwakeUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if let minutes {
            let t = Timer(timeInterval: Double(minutes) * 60, repeats: false) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.stop(.ended) }
            }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            endTimer = t
        }
        Diag.log("Giữ máy thức: bật \(minutes.map { "\($0) phút" } ?? "tới khi tắt")")
    }

    func stop(_ reason: StopReason, silent: Bool = false) {
        endTimer?.invalidate()
        endTimer = nil
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        model?.keepAwakeOn = false
        model?.keepAwakeUntil = nil
        guard !silent, let m = model else { return }
        switch reason {
        case .ended: m.showTransient(.message(symbol: "cup.and.saucer", title: "Hết giờ giữ máy thức", detail: "Máy sẽ ngủ như bình thường"), seconds: 4)
        case .lowBattery: m.showTransient(.message(symbol: "battery.25percent", title: "Đã tắt Giữ máy thức", detail: "Pin còn dưới 10%, để máy được ngủ"), seconds: 5)
        default: break
        }
    }
}

// MARK: - Khoá bàn phím để lau

@MainActor
final class KeyboardLock {
    static let shared = KeyboardLock()
    weak var model: NotchModel?
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var autoTimer: Timer?
    private var escTimes: [Date] = []

    static let minutes: Double = 2

    var locked: Bool { tap != nil }

    /// Trả về false khi chưa có quyền Trợ năng (đã mời bật quyền).
    @discardableResult
    func lock() -> Bool {
        guard !locked else { return true }
        guard Access.trusted else {
            Access.prompt()
            return false
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        mask |= CGEventMask(1) << 14   // NX_SYSDEFINED: phím âm lượng, độ sáng, phát nhạc
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyboardLockCallback, userInfo: nil) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        escTimes = []
        AppDelegate.shared?.controller.collapse()
        model?.keyboardLockUntil = Date().addingTimeInterval(Self.minutes * 60)
        AppDelegate.shared?.controller.lockChanged()
        let timer = Timer(timeInterval: Self.minutes * 60, repeats: false) { _ in
            MainActor.assumeIsolated { KeyboardLock.shared.unlock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
        Diag.log("Khoá bàn phím để lau")
        return true
    }

    func unlock() {
        autoTimer?.invalidate()
        autoTimer = nil
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        escTimes = []
        guard model?.keyboardLockUntil != nil else { return }
        model?.keyboardLockUntil = nil
        AppDelegate.shared?.controller.lockChanged()
        model?.showTransient(.message(symbol: "keyboard", title: "Đã mở khoá bàn phím", detail: "Gõ phím như bình thường"), seconds: 2.5)
    }

    /// true = nuốt phím (không cho tới app nào).
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let now = Date()
            escTimes = escTimes.filter { now.timeIntervalSince($0) < 3 } + [now]
            model?.lockEscCount = escTimes.count
            if escTimes.count >= 5 {
                DispatchQueue.main.async { MainActor.assumeIsolated { KeyboardLock.shared.unlock() } }
            }
        }
        return true
    }
}

private func keyboardLockCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let swallow = MainActor.assumeIsolated { KeyboardLock.shared.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Lấy mã màu

@MainActor
enum ColorPick {
    static func start(_ m: NotchModel) {
        AppDelegate.shared?.controller.collapse()
        // Chờ tai thỏ thu lại cho khỏi che mép trên màn hình.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSColorSampler().show { color in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let c = color?.usingColorSpace(.sRGB) else { return }
                        let hex = ClipParse.hex(c)
                        m.lastColor = hex
                        ClipboardWatcher.shared?.copyText(hex, source: "RinNotch · Lấy mã màu")
                        m.showTransient(.colorPicked(hex: hex), seconds: 3)
                    }
                }
            }
        }
    }
}

// MARK: - Báo mất mạng

@MainActor
final class NetworkWatcher {
    static var shared: NetworkWatcher?
    private let m: NotchModel
    private let monitor = NWPathMonitor()
    private var online: Bool?
    private var shownOffline = false
    private var pending: DispatchWorkItem?
    private var lastWake = Date.distantPast
    private var wakeObserver: NSObjectProtocol?

    init(model: NotchModel) {
        m = model
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NetworkWatcher.shared?.update(ok) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.phuocrin.rinnotch.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NetworkWatcher.shared?.lastWake = Date() }
        }
    }

    private func update(_ ok: Bool) {
        let was = online
        online = ok
        guard let was, was != ok else { return }
        if !ok {
            // Đợi vài giây cho khỏi báo lúc Wi-Fi chập chờn; vừa mở máy dậy thì Wi-Fi cần thời gian kết nối lại.
            pending?.cancel()
            let delay = Date().timeIntervalSince(lastWake) < 20 ? 15.0 : 4.0
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.online == false else { return }
                    self.shownOffline = true
                    Diag.log("Mất kết nối mạng")
                    if Prefs.showNetwork { self.m.showTransient(.offline, seconds: 5) }
                }
            }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        } else {
            pending?.cancel()
            if shownOffline {
                shownOffline = false
                Diag.log("Có mạng lại")
                if Prefs.showNetwork { m.showTransient(.online, seconds: 2.5) }
            }
        }
    }
}

// MARK: - Giao diện mục Công cụ

struct ToolsView: View {
    @ObservedObject var m: NotchModel
    @State private var trusted = Access.trusted

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: cols, spacing: 10) {
            card(symbol: "eyedropper.halffull", tint: .pink, title: "Lấy mã màu",
                 detail: m.lastColor.map { "Vừa lấy \($0) · đã chép" } ?? "Bấm rồi chọn điểm bất kỳ trên màn hình") {
                if let hex = m.lastColor, let c = ClipParse.color(hex) {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: c)).frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.3)))
                }
                Button("Lấy màu") { ColorPick.start(m) }.buttonStyle(PillButton(prominent: true))
            }
            card(symbol: m.keepAwakeOn ? "cup.and.saucer.fill" : "cup.and.saucer", tint: .teal, title: "Giữ máy thức",
                 detail: awakeDetail) {
                Menu {
                    Button("15 phút") { KeepAwake.shared.start(minutes: 15) }
                    Button("30 phút") { KeepAwake.shared.start(minutes: 30) }
                    Button("1 giờ") { KeepAwake.shared.start(minutes: 60) }
                    Button("2 giờ") { KeepAwake.shared.start(minutes: 120) }
                    Button("4 giờ") { KeepAwake.shared.start(minutes: 240) }
                    Button("Tới khi tắt") { KeepAwake.shared.start(minutes: nil) }
                } label: {
                    Text(m.keepAwakeOn ? "Đổi" : "Bật").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(m.keepAwakeOn ? Color.white.opacity(0.12) : Color.accentColor))
                if m.keepAwakeOn {
                    Button("Tắt") { KeepAwake.shared.stop(.user) }.buttonStyle(PillButton())
                }
            }
            card(symbol: "keyboard", tint: .orange, title: "Lau bàn phím",
                 detail: trusted ? "Khoá phím \(Int(KeyboardLock.minutes)) phút. Esc 5 lần để mở sớm"
                                 : "Cần quyền Trợ năng để khoá phím") {
                if trusted {
                    Button("Khoá phím") { KeyboardLock.shared.lock() }.buttonStyle(PillButton(prominent: true))
                } else {
                    Button("Cấp quyền") {
                        Access.prompt()
                        AppDelegate.shared?.controller.collapse()
                        Access.openSettings()
                    }
                    .buttonStyle(PillButton(prominent: true))
                }
            }
            card(symbol: "character.bubble", tint: .blue, title: "Dịch nhanh",
                 detail: "Bôi đen chữ ở app bất kỳ rồi bấm \(HotkeyCenter.combo(.translate)?.display ?? "phím Dịch nhanh")") {
                Button("Mở") { m.tab = .translate }.buttonStyle(PillButton(prominent: true))
            }
        }
        .onAppear { trusted = Access.trusted }
    }

    private var awakeDetail: String {
        guard m.keepAwakeOn else { return "Màn hình và máy không tự ngủ, hợp lúc xuất video dài" }
        guard let until = m.keepAwakeUntil else { return "Đang bật · tới khi tắt" }
        let left = max(Int(until.timeIntervalSinceNow / 60 + 0.99), 1)
        return left >= 60 ? "Đang bật · còn \(left / 60) giờ \(left % 60) phút" : "Đang bật · còn \(left) phút"
    }

    private func card<Trailing: View>(symbol: String, tint: Color, title: String, detail: String,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 76)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
    }
}
