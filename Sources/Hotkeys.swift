// RinNotch — phím tắt toàn hệ thống (đổi được trong Cài đặt).
// Mặc định: ⌥⌘N ẩn / hiện, ⌃⌘1 → ⌃⌘8 mở thẳng từng mục (8 = Dịch nhanh).
// Chọn ⌃⌘ + số vì Final Cut Pro đã dùng ⌥ + số, ⌃⌥ + số, ⇧⌥ + số, ⌃⌥⌘ + số; macOS dùng ⇧⌘3/4/5 và ⌃ + số.

import AppKit
import SwiftUI
import Carbon.HIToolbox

struct KeyCombo: Equatable {
    var keyCode: UInt32
    var mods: UInt32
    var label: String

    var storage: String { "\(keyCode)|\(mods)|\(label)" }

    init(keyCode: UInt32, mods: UInt32, label: String) {
        self.keyCode = keyCode
        self.mods = mods
        self.label = label
    }

    init?(storage: String) {
        let parts = storage.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        keyCode = k
        mods = m
        label = String(parts[2])
    }

    var display: String { Self.modsString(mods) + label }

    static func modsString(_ m: UInt32) -> String {
        (m & UInt32(controlKey) != 0 ? "⌃" : "")
            + (m & UInt32(optionKey) != 0 ? "⌥" : "")
            + (m & UInt32(shiftKey) != 0 ? "⇧" : "")
            + (m & UInt32(cmdKey) != 0 ? "⌘" : "")
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func cocoaMods(_ m: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m & UInt32(cmdKey) != 0 { f.insert(.command) }
        if m & UInt32(optionKey) != 0 { f.insert(.option) }
        if m & UInt32(controlKey) != 0 { f.insert(.control) }
        if m & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    static func label(for e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let s = e.charactersIgnoringModifiers?.uppercased() ?? ""
            return s.isEmpty ? "#\(e.keyCode)" : s
        }
    }
}

/// Việc mà một phím tắt làm. Thứ tự này cũng là số id đăng ký với hệ thống.
enum HotAction: String, CaseIterable, Identifiable {
    case toggleHidden, media, shelf, clipboard, notes, timer, system, tools, translate
    var id: String { rawValue }

    var tab: Tab? { Tab(rawValue: rawValue) }

    var title: String {
        switch self {
        case .toggleHidden: return L("Ẩn / hiện RinNotch", "Hide / show RinNotch")
        case .translate: return L("Dịch nhanh chữ đang bôi đen", "Translate selected text")
        default: return L("Mở ", "Open ") + (tab?.title ?? "")
        }
    }

    static let digitCodes: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    var defaultCombo: KeyCombo? {
        if self == .toggleHidden {
            return KeyCombo(keyCode: UInt32(kVK_ANSI_N), mods: UInt32(cmdKey | optionKey), label: "N")
        }
        guard let t = tab, let i = Tab.allCases.firstIndex(of: t), i < Self.digitCodes.count else { return nil }
        return KeyCombo(keyCode: UInt32(Self.digitCodes[i]), mods: UInt32(controlKey | cmdKey), label: "\(i + 1)")
    }

    /// Phím mở mục chỉ chạy khi Cách mở tai thỏ có Phím tắt. Ẩn / hiện và Dịch nhanh luôn chạy.
    var opensNotch: Bool { tab != nil && self != .translate }
}

extension Notification.Name {
    static let rinHotkeysChanged = Notification.Name("RinNotchHotkeysChanged")
}

@MainActor
enum HotkeyCenter {
    private static var refs: [HotAction: EventHotKeyRef] = [:]
    private static var installed = false
    private static var suspended = false
    /// Phím đăng ký không được (đang bị app khác giữ bằng phím tắt toàn hệ thống).
    static private(set) var failed: Set<HotAction> = []

    private static func key(_ a: HotAction) -> String { "hotkey.\(a.rawValue)" }

    static func combo(_ a: HotAction) -> KeyCombo? {
        if let s = UserDefaults.standard.string(forKey: key(a)) {
            return s == "off" ? nil : KeyCombo(storage: s)
        }
        return a.defaultCombo
    }

    static func set(_ a: HotAction, _ c: KeyCombo?) {
        UserDefaults.standard.set(c?.storage ?? "off", forKey: key(a))
        registerAll()
    }

    static func reset(_ a: HotAction) {
        UserDefaults.standard.removeObject(forKey: key(a))
        registerAll()
    }

    static func isEnabled(_ a: HotAction) -> Bool {
        !(a.opensNotch && Prefs.openMode == .hover)
    }

    /// Hành động khác đang dùng đúng tổ hợp này (để không cho gán trùng).
    static func owner(of c: KeyCombo, except a: HotAction) -> HotAction? {
        HotAction.allCases.first { $0 != a && combo($0).map { $0.keyCode == c.keyCode && $0.mods == c.mods } == true }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr else { return st }
            let index = Int(hk.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.fire(index: index) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func registerAll() {
        install()
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs = [:]
        failed = []
        if !suspended {
            for (i, a) in HotAction.allCases.enumerated() {
                guard isEnabled(a), let c = combo(a) else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x524E_4348), id: UInt32(i + 1))
                let st = RegisterEventHotKey(c.keyCode, c.mods, id, GetApplicationEventTarget(), 0, &ref)
                if st == noErr, let ref { refs[a] = ref } else { failed.insert(a) }
            }
        }
        NotificationCenter.default.post(name: .rinHotkeysChanged, object: nil)
    }

    /// Lúc đang ghi phím mới trong Cài đặt thì tạm bỏ mọi phím tắt, để phím vừa bấm tới được ô ghi.
    static func suspend(_ on: Bool) {
        guard suspended != on else { return }
        suspended = on
        registerAll()
    }

    private static func fire(index: Int) {
        let all = HotAction.allCases
        guard index >= 1, index <= all.count else { return }
        AppDelegate.shared?.perform(all[index - 1])
    }

    /// Phím tắt hiện trong menu thanh menu (chỉ để xem, phím thật do hệ thống bắt).
    static func menuKey(_ a: HotAction) -> (String, NSEvent.ModifierFlags)? {
        guard isEnabled(a), let c = combo(a), c.label.count == 1 else { return nil }
        return (c.label.lowercased(), KeyCombo.cocoaMods(c.mods))
    }
}

/// Ô ghi phím tắt trong Cài đặt: bấm vào rồi nhấn tổ hợp mới. Esc để huỷ, ⌫ để tắt phím này.
struct KeyRecorder: View {
    let action: HotAction
    @State private var recording = false
    @State private var monitor: Any?
    @State private var combo: KeyCombo?
    @State private var note: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? L("Nhấn phím…", "Press keys…") : (combo?.display ?? L("Tắt", "Off")))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 92)
                }
                .glassButton(prominent: recording)
                Button {
                    stop()
                    HotkeyCenter.reset(action)
                    refresh()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help(L("Về phím mặc định", "Reset to default"))
            }
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.orange)
            } else if failed && combo != nil {
                Text(L("Đang bị app khác giữ, chọn phím khác", "Taken by another app, pick another"))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            } else if !HotkeyCenter.isEnabled(action) {
                Text(L("Đang tắt vì Cách mở tai thỏ là Rê chuột", "Off: open mode is Hover"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onAppear { refresh() }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: .rinHotkeysChanged)) { _ in refresh() }
    }

    private func refresh() {
        combo = HotkeyCenter.combo(action)
        failed = HotkeyCenter.failed.contains(action)
    }

    private func start() {
        note = nil
        recording = true
        HotkeyCenter.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotkeyCenter.suspend(false)
        }
    }

    private func handle(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Int(e.keyCode) == kVK_Escape && flags.isEmpty { stop(); return }
        if (Int(e.keyCode) == kVK_Delete || Int(e.keyCode) == kVK_ForwardDelete) && flags.isEmpty {
            stop()
            HotkeyCenter.set(action, nil)
            refresh()
            return
        }
        let mods = KeyCombo.carbonMods(flags)
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            note = L("Cần giữ thêm ⌘, ⌃ hoặc ⌥", "Hold ⌘, ⌃ or ⌥ too")
            return
        }
        let c = KeyCombo(keyCode: UInt32(e.keyCode), mods: mods, label: KeyCombo.label(for: e))
        if let other = HotkeyCenter.owner(of: c, except: action) {
            note = L("Trùng với: ", "Already used by: ") + other.title
            return
        }
        note = nil
        stop()
        HotkeyCenter.set(action, c)
        refresh()
    }
}
