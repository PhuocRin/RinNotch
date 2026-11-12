// RinNotch — Dịch nhanh: bôi đen chữ ở app bất kỳ, bấm phím tắt, tai thỏ hiện bản dịch.
// Dịch bằng bộ dịch có sẵn của macOS (Translation, macOS 15+), chạy trên máy.
// Đọc chữ đang bôi đen cần quyền Trợ năng; chưa có quyền thì báo rõ, không tự lấy chữ khác thay vào.

import AppKit
import SwiftUI
import Carbon.HIToolbox
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Đọc chữ đang bôi đen

@MainActor
enum Selection {
    /// Đọc chữ đang chọn qua Trợ năng. Trả về phần tử đang focus nếu cho phép thay chữ trực tiếp.
    static func read() -> (text: String?, element: AXUIElement?) {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.6)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return (nil, nil) }
        let el = f as! AXUIElement
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = sel as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable)
        return (s, settable.boolValue ? el : nil)
    }

    /// App không cho đọc qua Trợ năng (Chrome, app Electron…): bấm ⌘C giúp rồi trả bộ nhớ tạm như cũ.
    static func copyFallback(_ done: @escaping @MainActor (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        ClipboardWatcher.shared?.pause(seconds: 1.5)
        postKey(kVK_ANSI_C, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                var text: String?
                if pb.changeCount != before {
                    text = pb.string(forType: .string)
                    restore(pb, saved)
                    ClipboardWatcher.shared?.ignore(pb.changeCount)
                }
                done(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil)
            }
        }
    }

    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restore(_ pb: NSPasteboard, _ snap: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items = snap.map { d -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, data) in d { it.setData(data, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func postKey(_ key: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Trạng thái dịch

struct TargetLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TargetLanguage] = [
        .init(code: "auto", name: "Tự động: Việt ⇄ Anh"),
        .init(code: "vi", name: "Tiếng Việt"),
        .init(code: "en", name: "English"),
        .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"),
        .init(code: "zh-Hans", name: "中文 (giản thể)"),
        .init(code: "zh-Hant", name: "中文 (phồn thể)"),
        .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "es", name: "Español"),
        .init(code: "th", name: "ไทย"),
        .init(code: "id", name: "Bahasa Indonesia"),
    ]

    static func name(_ code: String?) -> String {
        guard let code else { return "Tự nhận" }
        if let t = all.first(where: { $0.code == code }), code != "auto" { return t.name }
        return Locale(identifier: "vi").localizedString(forIdentifier: code)?.capitalized ?? code
    }
}

@MainActor
final class TranslateModel: ObservableObject {
    static let shared = TranslateModel()

    enum Replace { case none, ax(AXUIElement), paste }

    @Published var input = ""
    @Published var output = ""
    @Published var status: String?
    @Published var busy = false
    @Published var needsPermission = false
    @Published var target = UserDefaults.standard.string(forKey: "translateTarget") ?? "auto" {
        didSet { UserDefaults.standard.set(target, forKey: "translateTarget") }
    }
    @Published var requestID = 0
    @Published var sourceCode: String?
    @Published var targetCode = "vi"
    @Published var showLanguageHelp = false
    var replace: Replace = .none

    var canReplace: Bool {
        if case .none = replace { return false }
        return !output.isEmpty
    }

    static var engineAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: Bắt đầu

    /// Bấm phím Dịch nhanh: lấy chữ đang bôi đen ở app đang dùng rồi mở tai thỏ.
    func startFromHotkey() {
        guard let ctrl = AppDelegate.shared?.controller, let m = AppDelegate.shared?.model else { return }
        if m.expanded && m.tab == .translate && ctrl.panel.isKeyWindow {
            ctrl.collapse()
            return
        }
        if m.hidden { AppDelegate.shared?.toggleHidden() }
        guard Access.trusted else {
            needsPermission = true
            replace = .none
            Access.prompt()
            ctrl.expand(tab: .translate, byKeyboard: true)
            return
        }
        needsPermission = false
        let r = Selection.read()
        if let text = r.text {
            replace = r.element.map { .ax($0) } ?? .paste
            begin(text)
            ctrl.expand(tab: .translate, byKeyboard: true)
            return
        }
        // Đang mở tai thỏ để gõ thì ⌘C sẽ rơi vào chính RinNotch: chỉ dùng cách này khi app khác đang được gõ.
        guard !ctrl.panel.isKeyWindow else {
            noSelection()
            ctrl.expand(tab: .translate, byKeyboard: true)
            return
        }
        Selection.copyFallback { text in
            if let text {
                self.replace = .paste
                self.begin(text)
            } else {
                self.noSelection()
            }
            ctrl.expand(tab: .translate, byKeyboard: true)
        }
    }

    /// Dịch một đoạn có sẵn (chuột phải trong Bộ nhớ tạm).
    func start(text: String) {
        replace = .none
        needsPermission = false
        begin(text)
        AppDelegate.shared?.controller.expand(tab: .translate)
    }

    private func noSelection() {
        replace = .none
        input = ""
        output = ""
        status = "Chưa thấy chữ đang bôi đen. Bôi đen chữ rồi bấm lại, hoặc gõ / dán chữ vào ô bên trái."
    }

    private func begin(_ text: String) {
        input = String(text.prefix(5000))
        translate()
    }

    // MARK: Dịch

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            return
        }
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        let detected = rec.dominantLanguage.map { Self.normalize($0.rawValue) }
        sourceCode = detected
        if target == "auto" {
            targetCode = detected == "vi" ? "en" : "vi"
        } else {
            targetCode = target
        }
        if detected == targetCode {
            output = text
            status = "Đoạn này đã là \(TargetLanguage.name(targetCode)), chọn ngôn ngữ khác ở trên nếu muốn."
            return
        }
        output = ""
        status = nil
        showLanguageHelp = false
        guard Self.engineAvailable else {
            status = "Bộ dịch có sẵn của Mac cần macOS 15 trở lên. Bấm Mở Google Dịch để dịch đoạn này."
            return
        }
        busy = true
        requestID += 1
    }

    /// Mã ngôn ngữ của NaturalLanguage → mã của bộ dịch (zh-Hans, zh-Hant giữ nguyên).
    static func normalize(_ code: String) -> String {
        if code.hasPrefix("zh") { return code }
        return String(code.prefix(2))
    }

    func finish(_ text: String) {
        busy = false
        output = text
    }

    func fail(_ message: String, languageHelp: Bool = false) {
        busy = false
        status = message
        showLanguageHelp = languageHelp
    }

    // MARK: Sau khi dịch

    func copyOutput() {
        guard !output.isEmpty else { return }
        ClipboardWatcher.shared?.copyText(output, source: "RinNotch · Dịch nhanh")
        status = "Đã chép bản dịch"
    }

    func replaceSelection() {
        guard !output.isEmpty else { return }
        switch replace {
        case .ax(let el):
            if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, output as CFTypeRef) == .success {
                AppDelegate.shared?.controller.collapse()
                return
            }
            pasteReplace()
        case .paste:
            pasteReplace()
        case .none:
            break
        }
    }

    /// App không cho thay chữ trực tiếp: dán bản dịch đè lên chữ đang chọn, xong trả bộ nhớ tạm như cũ.
    private func pasteReplace() {
        let pb = NSPasteboard.general
        let saved = Selection.snapshot(pb)
        pb.clearContents()
        pb.setString(output, forType: .string)
        ClipboardWatcher.shared?.ignore(pb.changeCount)
        AppDelegate.shared?.controller.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Selection.postKey(kVK_ANSI_V, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    Selection.restore(pb, saved)
                    ClipboardWatcher.shared?.ignore(pb.changeCount)
                }
            }
        }
    }

    func openGoogle() {
        var c = URLComponents(string: "https://translate.google.com/")!
        c.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target == "auto" ? targetCode : target),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "op", value: "translate"),
        ]
        if let u = c.url { NSWorkspace.shared.open(u) }
        AppDelegate.shared?.controller.collapse()
    }

    static func openLanguageSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
        AppDelegate.shared?.controller.collapse()
    }
}

// MARK: - Bộ dịch (macOS 15+)

#if canImport(Translation)
@available(macOS 15.0, *)
struct TranslationRunner: View {
    @ObservedObject var t: TranslateModel
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                let text = await MainActor.run { t.input }
                do {
                    let r = try await session.translate(text)
                    await MainActor.run { t.finish(r.targetText) }
                } catch {
                    let msg = "\(error)".lowercased()
                    await MainActor.run {
                        if msg.contains("notinstalled") || msg.contains("not installed") || msg.contains("unable to") {
                            t.fail("Máy chưa có gói ngôn ngữ để dịch. Tải ở Cài đặt hệ thống → Chung → Ngôn ngữ & Vùng → Ngôn ngữ dịch.", languageHelp: true)
                        } else if msg.contains("unsupported") {
                            t.fail("Bộ dịch của Mac chưa hỗ trợ cặp ngôn ngữ này.")
                        } else {
                            t.fail("Chưa dịch được. Thử lại, hoặc tải gói ngôn ngữ ở Cài đặt hệ thống → Chung → Ngôn ngữ & Vùng → Ngôn ngữ dịch.", languageHelp: true)
                        }
                    }
                }
            }
            .onChange(of: t.requestID) { run() }
            .onAppear { if t.busy { run() } }
    }

    private func run() {
        let src = t.sourceCode.map { Locale.Language(identifier: $0) }
        let tgt = Locale.Language(identifier: t.targetCode)
        if config == nil || config?.source != src || config?.target != tgt {
            config = TranslationSession.Configuration(source: src, target: tgt)
        } else {
            config?.invalidate()
        }
    }
}
#endif

// MARK: - Giao diện

struct TranslateView: View {
    @ObservedObject var m: NotchModel
    @ObservedObject var t = TranslateModel.shared
    @State private var trusted = Access.trusted

    var body: some View {
        Group {
            if t.needsPermission && !trusted {
                permissionCard
            } else {
                content
            }
        }
        .background(runner)
        .onAppear { trusted = Access.trusted }
    }

    @ViewBuilder private var runner: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { TranslationRunner(t: t) }
        #endif
    }

    private var permissionCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.orange)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color.orange.opacity(0.15)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Cần quyền Trợ năng để đọc chữ bạn đang bôi đen")
                    .font(.system(size: 14, weight: .semibold))
                Text("Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → bật RinNotch. Bật xong bôi đen chữ rồi bấm lại phím Dịch nhanh.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Mở Cài đặt Trợ năng") {
                        AppDelegate.shared?.controller.collapse()
                        Access.openSettings()
                    }
                    .buttonStyle(PillButton(prominent: true))
                    Button("Đã bật rồi") {
                        trusted = Access.trusted
                        if trusted { t.needsPermission = false }
                    }
                    .buttonStyle(PillButton())
                    Button("Tự gõ chữ để dịch") { t.needsPermission = false }
                        .buttonStyle(PillButton())
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t.sourceCode.map { TargetLanguage.name($0) } ?? "Chữ gốc")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $t.input)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .onKeyPress(.return, phases: .down) { press in
                                guard press.modifiers.contains(.command) else { return .ignored }
                                t.translate()
                                return .handled
                            }
                        if t.input.isEmpty {
                            Text("Gõ hoặc dán chữ vào đây · ⌘ Enter để dịch")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                }
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 60)
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $t.target) {
                        ForEach(TargetLanguage.all) { l in Text(l.name).tag(l.code) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 190, alignment: .leading)
                    .onChange(of: t.target) { t.translate() }
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(t.output.isEmpty ? " " : t.output)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        if t.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Đang dịch…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Text(t.status ?? (t.canReplace ? "Thay chỗ chọn: đưa bản dịch vào đúng chỗ bạn vừa bôi đen" : "Dịch trên máy bằng bộ dịch của macOS"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                Spacer(minLength: 4)
                if t.showLanguageHelp {
                    Button("Ngôn ngữ dịch") { TranslateModel.openLanguageSettings() }.buttonStyle(PillButton())
                }
                if !TranslateModel.engineAvailable {
                    Button("Mở Google Dịch") { t.openGoogle() }.buttonStyle(PillButton(prominent: true))
                } else {
                    Button("Dịch") { t.translate() }.buttonStyle(PillButton())
                }
                Button("Sao chép") { t.copyOutput() }.buttonStyle(PillButton()).disabled(t.output.isEmpty)
                if t.canReplace {
                    Button("Thay chỗ chọn") { t.replaceSelection() }.buttonStyle(PillButton(prominent: true))
                }
            }
        }
    }
}
