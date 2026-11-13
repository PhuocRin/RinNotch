// RinNotch — biến tai thỏ MacBook thành khu tiện ích nhỏ.
// Bản 1: hiệu ứng bung từ tai thỏ, kệ file, bộ nhớ tạm, ghi chú nhanh (lưu vào Apple Notes),
// báo tai nghe kết nối, báo cắm sạc, sóng âm khi có app đang ghi âm, phím tắt ẩn ⌥⌘N.

import AppKit
import SwiftUI
import Combine
import AVFoundation
import CoreAudio
import IOKit.ps
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Security

// MARK: - Hình học tai thỏ

struct NotchGeometry {
    let screenFrame: CGRect
    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    /// Màn hình không tai thỏ (màn hình rời, iPad làm màn hình phụ, Mac mini…): dạng viên thuốc nổi
    /// cách mép trên một chút, bo tròn cả bốn góc, nằm giữa thanh menu.
    var topInset: CGFloat { hasNotch ? 0 : 3 }

    /// Màn hình mặc định: màn hình có tai thỏ, không có thì màn hình chính.
    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        return of(screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first)
    }

    static func of(_ screen: NSScreen?) -> NotchGeometry {
        guard let s = screen else {
            return NotchGeometry(screenFrame: .zero, hasNotch: false, width: 110, height: 24)
        }
        let top = s.safeAreaInsets.top
        if top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let w = s.frame.width - l.width - r.width
            return NotchGeometry(screenFrame: s.frame, hasNotch: true, width: max(w, 120), height: top)
        }
        // Viên thuốc cao vừa trong thanh menu (thanh menu ẩn thì lấy 24).
        let menuH = s.frame.maxY - s.visibleFrame.maxY
        let bar = menuH >= 20 && menuH <= 60 ? menuH : 24
        return NotchGeometry(screenFrame: s.frame, hasNotch: false, width: 110, height: max(bar - 4, 22))
    }
}

// MARK: - Dữ liệu

enum Tab: String, CaseIterable, Identifiable {
    case media, shelf, clipboard, notes, timer, system, tools, translate, windows
    var id: String { rawValue }
    /// Số trên bàn phím: ⌃⇧ + số mở thẳng mục này, hoặc bấm số khi tai thỏ đang mở.
    var number: Int { (Tab.allCases.firstIndex(of: self) ?? 0) + 1 }
    var title: String {
        switch self {
        case .media: return "Nhạc"
        case .shelf: return "Kệ file"
        case .clipboard: return "Bộ nhớ tạm"
        case .notes: return "Ghi chú"
        case .timer: return "Hẹn giờ"
        case .system: return "Hệ thống"
        case .tools: return "Công cụ"
        case .translate: return "Dịch nhanh"
        case .windows: return "Cửa sổ"
        }
    }
    /// Màu riêng của từng mục: chỉ tô cho icon mục đang chọn / đang rê chuột, các mục còn lại giữ màu trắng.
    var tint: Color {
        switch self {
        case .media: return Color(red: 1.0, green: 0.36, blue: 0.5)
        case .shelf: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .clipboard: return Color(red: 0.35, green: 0.85, blue: 0.5)
        case .notes: return Color(red: 1.0, green: 0.82, blue: 0.3)
        case .timer: return Color(red: 1.0, green: 0.62, blue: 0.25)
        case .system: return Color(red: 0.3, green: 0.85, blue: 0.85)
        case .tools: return Color(red: 0.65, green: 0.7, blue: 0.8)
        case .translate: return Color(red: 0.4, green: 0.8, blue: 1.0)
        case .windows: return Color(red: 0.72, green: 0.55, blue: 1.0)
        }
    }
    var symbol: String {
        switch self {
        case .media: return "music.note"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "square.and.pencil"
        case .timer: return "timer"
        case .system: return "cpu"
        case .tools: return "wrench.and.screwdriver"
        case .translate: return "character.bubble"
        case .windows: return "macwindow.on.rectangle"
        }
    }
}

struct HeadphoneInfo: Equatable {
    var name: String
    var symbol: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var main: Int?
    var hasBattery: Bool { left != nil || right != nil || caseLevel != nil || main != nil }
}

enum Transient: Equatable {
    case headphones(HeadphoneInfo)
    case charging(percent: Int)
    case unplugged(percent: Int)
    case lowBattery(percent: Int)
    case timerDone(minutes: Int)
    case offline
    case online
    case colorPicked(hex: String)
    case message(symbol: String, title: String, detail: String)
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var playing: Bool
    var pid: Int32

    func position(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        let r = playing ? max(rate, playing ? 1 : 0) : 0
        return min(max(elapsed + now.timeIntervalSince(timestamp) * r, 0), duration)
    }
    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "" }
}

enum TimerMode: String { case stopwatch, countdown }

struct TimerState: Equatable {
    var mode: TimerMode = .stopwatch
    var running = false
    var startedAt: Date?
    var accumulated: TimeInterval = 0
    var countdownTotal: TimeInterval = 5 * 60

    var active: Bool { running || accumulated > 0 }
    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }
    func display(at now: Date) -> TimeInterval {
        mode == .stopwatch ? elapsed(at: now) : max(countdownTotal - elapsed(at: now), 0)
    }
}

func formatClock(_ t: TimeInterval, alwaysHours: Bool = false) -> String {
    let s = max(0, Int(t.rounded(.down)))
    if alwaysHours || s >= 3600 {
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

struct RecordingInfo: Equatable {
    var appName: String
    var bundleID: String?
    var pid: pid_t
    /// Thời gian đã ghi của các đoạn trước (cộng dồn qua các lần tạm dừng).
    var accumulated: TimeInterval = 0
    /// Lúc bắt đầu đoạn đang ghi; nil = đang tạm dừng.
    var segmentStart: Date?
    var pausedAt: Date?

    var paused: Bool { segmentStart == nil }
    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (segmentStart.map { now.timeIntervalSince($0) } ?? 0)
    }
}

struct NoteItem: Identifiable, Codable {
    var id = UUID()
    var text: String
    var date: Date
    var savedToNotes: Bool
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var tab: Tab = .shelf
    @Published var transient: Transient?
    @Published var recording: RecordingInfo?
    @Published var levels: [CGFloat] = Array(repeating: 0.08, count: 14)
    @Published var hidden = false
    @Published var hasNotch = true
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var shelf: [URL] = []
    @Published var shelfSelection: Set<URL> = []
    var shelfAnchor: URL?
    var marqueeActive = false
    @Published var clips: [ClipItem] = []
    @Published var pins: [ClipItem] = []
    @Published var clipFilter: ClipFilter = .recent
    @Published var clipCategory: ClipCategory?
    @Published var clipApp: String?
    @Published var shelfKind: ShelfKind?
    @Published var shelfHover: URL?
    @Published var libraryTab: LibraryTab = .clipboard
    @Published var clipSearch = ""
    @Published var clipSelection: UUID?
    @Published var clipFlash: UUID?
    @Published var shelfStatus: String?
    @Published var shelfBusy = false
    @Published var keepAwakeOn = false
    @Published var keepAwakeUntil: Date?
    @Published var keyboardLockUntil: Date?
    @Published var lockEscCount = 0
    @Published var lastColor: String?
    @Published var notes: [NoteItem] = []
    @Published var noteDraft = ""
    @Published var noteStatus: String?
    @Published var dropTargeted = false
    @Published var micDenied = false
    @Published var nowPlaying: NowPlaying?
    @Published var artwork: NSImage?
    @Published var timer = TimerState()
    /// Copy liên tục: nil = đang tắt; các mục đã copy theo thứ tự.
    @Published var stack: [ClipItem]?
    @Published var stackPasted = 0
    /// File đang tải trong thư mục Tải về (nil = không có).
    @Published var downloads: DownloadSummary?

    var musicCompact: Bool { Prefs.showMusic && nowPlaying?.playing == true && !(nowPlaying?.title.isEmpty ?? true) }
    var timerCompact: Bool { Prefs.showTimer && timer.running }
    var awakeCompact: Bool { Prefs.showAwake && keepAwakeOn }

    var draggingOut = false
    private var transientTimer: Timer?
    private var shelfStatusWork: DispatchWorkItem?

    /// Dòng báo ngắn trong mục Công cụ (chỉnh cửa sổ không được…).
    @Published var toolStatus: String?
    private var toolStatusWork: DispatchWorkItem?
    func flashToolStatus(_ text: String) {
        toolStatus = text
        toolStatusWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.toolStatus = nil } }
        toolStatusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func flashShelfStatus(_ text: String) {
        shelfStatus = text
        shelfStatusWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.shelfStatus = nil } }
        shelfStatusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: w)
    }

    init() {
        let d = UserDefaults.standard
        if let paths = d.stringArray(forKey: "shelf") {
            shelf = paths.map { URL(fileURLWithPath: $0) }
        }
        if let data = d.data(forKey: "notes"), let list = try? JSONDecoder().decode([NoteItem].self, from: data) {
            notes = list
        }
    }

    func showTransient(_ t: Transient, seconds: Double = 3) {
        transient = t
        transientTimer?.invalidate()
        transientTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.transient = nil }
        }
    }

    func pushLevel(_ v: CGFloat) {
        var l = levels
        l.removeFirst()
        l.append(v)
        levels = l
    }

    // Kệ file
    func addToShelf(_ urls: [URL]) {
        for u in urls where !shelf.contains(u) { shelf.append(u) }
        saveShelf()
    }
    func removeFromShelf(_ url: URL) { removeFromShelf([url]) }
    func removeFromShelf(_ urls: [URL]) {
        let drop = Set(urls)
        shelf.removeAll { drop.contains($0) }
        shelfSelection.subtract(drop)
        saveShelf()
    }
    func clearShelf() {
        shelf.removeAll()
        shelfSelection = []
        shelfAnchor = nil
        saveShelf()
    }
    /// File đang chọn, theo đúng thứ tự trên kệ.
    var selectedShelf: [URL] { shelf.filter { shelfSelection.contains($0) } }
    func saveShelfNow() { saveShelf() }
    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: "shelf")
    }

    // Ghi chú
    func saveNotes() {
        let keep = Array(notes.prefix(30))
        if let data = try? JSONEncoder().encode(keep) {
            UserDefaults.standard.set(data, forKey: "notes")
        }
    }
}

// MARK: - Hình tai thỏ

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, (r.height - t) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Khung tai thỏ: có tai thỏ thì vẽ NotchShape, không thì hình chữ nhật bo góc (viên thuốc). Một kiểu hình
/// duy nhất để bán kính bo vẫn chạy mượt khi đổi trạng thái.
struct IslandShape: Shape {
    var pill: Bool
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        if pill {
            return Path(roundedRect: r, cornerRadius: min(bottomRadius, r.height / 2, r.width / 2), style: .continuous)
        }
        return NotchShape(bottomRadius: bottomRadius, topRadius: topRadius).path(in: r)
    }
}

// MARK: - Giao diện

struct PillButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent)
    }
}

/// Nút viên thuốc: rê chuột thì sáng hơn và nhích to, bấm thì lún xuống.
private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? Color.accentColor
                                         : Color.white.opacity(configuration.isPressed ? 0.26 : (hovered ? 0.2 : 0.12)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovered && enabled ? 0.2 : 0), lineWidth: 1))
            .brightness(prominent && hovered && enabled ? 0.08 : 0)
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.93 : (hovered && enabled ? 1.09 : 1))
            .shadow(color: (prominent ? Color.accentColor : Color.white).opacity(hovered && enabled ? 0.35 : 0), radius: 6)
            .contentShape(Capsule())
            .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }
}

/// Thay cho .plain: mọi nút trên tai thỏ đều có hiệu ứng khi rê chuột (sáng lên, nhích to) và khi bấm (lún).
/// Nhịp nảy dùng chung cho hiệu ứng rê chuột: lò xo ít hãm nên phóng lố một chút rồi về, nhìn ra là "nảy".
enum HoverAnim {
    static let bounce = Animation.spring(response: 0.32, dampingFraction: 0.52)
}

struct HoverPlain: ButtonStyle {
    var scale: CGFloat = 1.12
    func makeBody(configuration: Configuration) -> some View {
        HoverPlainBody(configuration: configuration, scale: scale)
    }
}

private struct HoverPlainBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .brightness(hovered && enabled ? 0.15 : 0)
            .scaleEffect(configuration.isPressed ? 0.92 : (hovered && enabled ? scale : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }
}

struct HoverOutline: ViewModifier {
    var cornerRadius: CGFloat = 10
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white.opacity(hovered ? 0.28 : 0), lineWidth: 1))
            .shadow(color: .white.opacity(hovered ? 0.12 : 0), radius: 6)
            .onHover { inside in withAnimation(.easeOut(duration: 0.18)) { hovered = inside } }
    }
}

/// Hiệu ứng nảy cho thứ không phải nút (menu Xử lý, ô chọn ngôn ngữ…).
struct HoverPop: ViewModifier {
    var scale: CGFloat = 1.08
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .brightness(hovered && enabled ? 0.12 : 0)
            .scaleEffect(hovered && enabled ? scale : 1)
            .shadow(color: .white.opacity(hovered && enabled ? 0.25 : 0), radius: 6)
            .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }
}

/// Thẻ / ô không phải nút (thẻ Công cụ, vòng Hệ thống): rê chuột thì nền sáng hơn, có viền và nhấc nhẹ.
struct HoverCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color = .white
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(hovered ? 0.3 : 0), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.05 : 0)))
            .scaleEffect(hovered ? 1.035 : 1)
            .shadow(color: .black.opacity(hovered ? 0.4 : 0), radius: 10, y: 4)
            .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }
}

extension View {
    func hoverCard(cornerRadius: CGFloat = 14, tint: Color = .white) -> some View {
        modifier(HoverCard(cornerRadius: cornerRadius, tint: tint))
    }
    func hoverPop(scale: CGFloat = 1.08) -> some View { modifier(HoverPop(scale: scale)) }
    /// Ô gõ chữ: không phóng to (khó đọc), chỉ hiện viền sáng khi rê chuột.
    func hoverOutline(cornerRadius: CGFloat = 10) -> some View { modifier(HoverOutline(cornerRadius: cornerRadius)) }
}

struct IslandView: View {
    @ObservedObject var m: NotchModel

    enum Phase: Equatable { case idle, compact, banner, expanded }

    var phase: Phase {
        if m.keyboardLockUntil != nil { return .banner }
        if m.expanded { return .expanded }
        if m.transient != nil { return .banner }
        if m.stack != nil || m.recording != nil || m.timerCompact || m.downloads != nil || m.musicCompact || m.awakeCompact { return .compact }
        return .idle
    }

    var size: CGSize {
        switch phase {
        case .idle: return CGSize(width: m.notchWidth, height: m.notchHeight)
        case .compact:
            let wide = m.stack != nil || m.recording != nil || m.timerCompact || m.downloads != nil
            // Viên thuốc không có tai thỏ ở giữa nên hai bên đứng sát nhau hơn.
            let gap = m.hasNotch ? m.notchWidth : 34
            return CGSize(width: gap + (wide ? 210 : 130), height: m.notchHeight)
        case .banner: return CGSize(width: max(m.notchWidth + 170, m.keyboardLockUntil != nil ? 490 : 420), height: m.notchHeight + 78)
        case .expanded: return CGSize(width: NotchController.expandedWidth, height: m.notchHeight + NotchController.expandedHeight)
        }
    }

    var bottomRadius: CGFloat {
        if !m.hasNotch {
            switch phase {
            case .idle, .compact: return 100   // bo hết cỡ = viên thuốc
            case .banner: return 24
            case .expanded: return 26
            }
        }
        switch phase {
        case .idle: return 9
        case .compact: return 14
        case .banner: return 26
        case .expanded: return 28
        }
    }

    var topRadius: CGFloat { (phase == .idle || !m.hasNotch) ? 0 : 8 }

    /// Có tai thỏ: khung ôm tai thỏ (hai tai cong ở mép trên). Không tai thỏ: viên thuốc bo tròn cả bốn góc.
    var shape: IslandShape { IslandShape(pill: !m.hasNotch, bottomRadius: bottomRadius, topRadius: topRadius) }

    /// Viên thuốc lúc rảnh trên màn hình không tai thỏ (tắt được trong Cài đặt).
    var idleHidden: Bool { phase == .idle && !m.hasNotch && !Prefs.showIdlePill }

    /// Kích thước đang vẽ: chạy theo `size` bằng hai nhịp (bung: kéo ngang trước rồi mới thả xuống;
    /// thu: kéo lên trước rồi mới thu ngang), nhìn giống Dynamic Island hơn là phóng to đều.
    @State private var w: CGFloat = 0
    @State private var h: CGFloat = 0

    var body: some View {
        let s = size
        Group {
            switch phase {
            case .idle:
                Color.clear
            case .compact:
                CompactView(m: m)
                    .frame(height: m.notchHeight)
                    .padding(.horizontal, topRadius)
            case .banner:
                BannerView(m: m)
                    .padding(.horizontal, topRadius)
            case .expanded:
                ExpandedView(m: m)
                    .padding(.horizontal, topRadius)
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                .animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.09))
        ))
        // Nội dung luôn ở đúng cỡ cuối, khung tai thỏ lớn dần và cắt bớt: chữ không bị xô lệch lúc bung.
        .frame(width: s.width + 2 * topRadius, height: s.height, alignment: .top)
        .frame(width: (w > 0 ? w : s.width) + 2 * topRadius, height: h > 0 ? h : s.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        // Viên thuốc nằm trên thanh menu (có khi là nền tối): viền mảnh cho khỏi lẫn vào nền.
        .overlay(shape.stroke(Color.white.opacity(m.hasNotch ? 0 : 0.16), lineWidth: 1))
        .shadow(color: .black.opacity(phase == .idle ? (m.hasNotch ? 0 : 0.25) : 0.45), radius: phase == .idle ? 4 : 18, x: 0, y: phase == .idle ? 1 : 8)
        .padding(.top, m.hasNotch ? 0 : 3)
        .opacity((m.hidden || idleHidden) ? 0 : 1)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: phase)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: m.transient)
        .animation(.easeOut(duration: 0.2), value: m.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { w = s.width; h = s.height }
        .onChange(of: s) { _, new in animate(to: new) }
    }

    private func animate(to new: CGSize) {
        if new.height > h + 1 {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) { w = new.width }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.74).delay(0.05)) { h = new.height }
        } else if new.height < h - 1 {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) { h = new.height }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88).delay(0.05)) { w = new.width }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                w = new.width
                h = new.height
            }
        }
    }
}

// MARK: Dạng gọn (ôm hai bên tai thỏ)

struct CompactView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: m.hasNotch ? m.notchWidth : 34)
            trailing
        }
        .padding(.horizontal, 14)
        .foregroundStyle(.white)
    }

    @ViewBuilder var leading: some View {
        if m.stack != nil {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("Copy liên tục")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
        } else if let r = m.recording {
            RecordingBadge(info: r)
        } else if m.timerCompact {
            HStack(spacing: 5) {
                Image(systemName: m.timer.mode == .countdown ? "timer" : "stopwatch")
                    .foregroundStyle(Color.orange)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Text(formatClock(m.timer.display(at: ctx.date)))
                        .monospacedDigit()
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.system(size: 12, weight: .semibold))
        } else if let d = m.downloads {
            HStack(spacing: 5) {
                Image(systemName: d.copying ? "doc.on.doc.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Color.blue)
                Text(d.fraction.map { "\(Int($0 * 100))%" } ?? (d.count > 1 ? "\(d.count) file" : "Đang tải"))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .help(d.name)
        } else if m.musicCompact {
            ArtworkView(image: m.artwork, size: 20, radius: 5)
        } else if m.awakeCompact {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.teal)
        }
    }

    @ViewBuilder var trailing: some View {
        if let s = m.stack {
            Text(s.isEmpty ? "0" : "\(m.stackPasted)/\(s.count)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.orange)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: m.stackPasted)
                .animation(.spring(response: 0.3), value: s.count)
        } else if m.recording != nil {
            Waveform(levels: m.levels)
        } else if m.timerCompact {
            if m.timer.mode == .countdown {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let total = max(m.timer.countdownTotal, 1)
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: CGFloat(m.timer.display(at: ctx.date) / total))
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                }
            } else {
                Text("Bấm giờ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        } else if let d = m.downloads {
            HStack(spacing: 6) {
                if d.bytesPerSecond > 0 {
                    Text(DownloadWatcher.speedText(d.bytesPerSecond))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
                ProgressRing(fraction: d.fraction)
            }
        } else if m.musicCompact {
            MusicBars().frame(width: 18, height: 18)
        } else if m.awakeCompact {
            if let until = m.keepAwakeUntil {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("\(max(Int(until.timeIntervalSince(ctx.date) / 60 + 0.99), 1))p")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.teal)
                }
            } else {
                Text("∞").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.teal)
            }
        }
    }
}

/// Bốn thanh nhạc nhảy. Vẽ bằng Core Animation: hoạt ảnh chạy trong tiến trình vẽ của macOS,
/// RinNotch không phải tính lại từng khung hình suốt lúc nghe nhạc (bản SwiftUI cũ tốn CPU liên tục).
struct MusicBars: NSViewRepresentable {
    func makeNSView(context: Context) -> MusicBarsView { MusicBarsView() }
    func updateNSView(_ nsView: MusicBarsView, context: Context) {}
}

final class MusicBarsView: NSView {
    private static let low: [CGFloat] = [6, 14, 7, 13]
    private static let high: [CGFloat] = [14, 8, 16, 10]
    private static let durations: [Double] = [0.45, 0.38, 0.5, 0.42]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        for i in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = 1.5
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: Self.low[i])
            bar.position = CGPoint(x: 1.5 + CGFloat(i) * 5, y: 9)
            let a = CABasicAnimation(keyPath: "bounds.size.height")
            a.fromValue = Self.low[i]
            a.toValue = Self.high[i]
            a.duration = Self.durations[i]
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = false
            bar.add(a, forKey: "bounce")
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
}

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.28), Color(red: 1, green: 0.31, blue: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Thông báo thả xuống từ tai thỏ (tai nghe kết nối): hiện đủ tên thiết bị.
struct BannerView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: m.notchHeight)
            if let until = m.keyboardLockUntil {
                lockRow(until: until)
            } else {
                transientRow
            }
        }
        .foregroundStyle(.white)
    }

    func lockRow(until: Date) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 26))
                .foregroundStyle(Color.orange)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Đang khoá bàn phím để lau").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.orange)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(m.lockEscCount > 0 ? "Esc \(m.lockEscCount)/5 · tự mở sau \(formatClock(until.timeIntervalSince(ctx.date)))"
                                            : "Bấm Esc 5 lần để mở · tự mở sau \(formatClock(until.timeIntervalSince(ctx.date)))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            Button("Mở khoá") { KeyboardLock.shared.unlock() }.buttonStyle(PillButton(prominent: true))
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
    }

    func simpleRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder var transientRow: some View {
            switch m.transient {
            case .offline:
                simpleRow(symbol: "wifi.slash", tint: .red, title: "Mất kết nối mạng", detail: "Kiểm tra Wi-Fi hoặc dây mạng")
            case .online:
                simpleRow(symbol: "wifi", tint: .green, title: "Đã có mạng lại", detail: "Kết nối internet đã trở lại")
            case .message(let symbol, let title, let detail):
                simpleRow(symbol: symbol, tint: .white, title: title, detail: detail)
            case .colorPicked(let hex):
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: ClipParse.color(hex) ?? .gray))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 40, height: 40)
                        .padding(.horizontal, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hex).font(.system(size: 16, weight: .semibold, design: .monospaced))
                        Text("Đã chép mã màu · chuột phải trong Bộ nhớ tạm để lấy dạng RGB, HSL")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
            case .charging(let p):
                chargeRow(percent: p, charging: true)
            case .unplugged(let p):
                chargeRow(percent: p, charging: false)
            case .lowBattery(let p):
                HStack(spacing: 14) {
                    BigBattery(percent: p, charging: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pin yếu").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.red)
                        Text("Cắm sạc sớm nha").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    Text("\(p)%").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
            case .timerDone(let minutes):
                HStack(spacing: 14) {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.orange)
                        .frame(width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hết giờ").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.orange)
                        Text(minutes > 0 ? "Đã đếm ngược \(minutes) phút" : "Đã đếm ngược xong")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
            case .headphones(let info):
                HStack(spacing: 14) {
                    Image(systemName: info.symbol)
                        .font(.system(size: 30, weight: .regular))
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if info.hasBattery {
                            HStack(spacing: 10) {
                                if let v = info.main { BatteryChip(label: nil, value: v) }
                                if let v = info.left { BatteryChip(label: "T", value: v) }
                                if let v = info.right { BatteryChip(label: "P", value: v) }
                                if let v = info.caseLevel { BatteryChip(label: "Hộp", value: v) }
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Đã kết nối").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.green)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .frame(maxHeight: .infinity)
            case .none:
                EmptyView()
            }
    }

    func chargeRow(percent: Int, charging: Bool) -> some View {
        HStack(spacing: 14) {
            BigBattery(percent: percent, charging: charging)
            VStack(alignment: .leading, spacing: 3) {
                Text(charging ? "Đang sạc" : "Đã ngắt sạc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(charging ? Color.green : Color.white)
                Text(charging ? "Pin đang được sạc" : "Đang dùng pin")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            Text("\(percent)%")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(charging ? Color.green : Color.white)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
    }
}

struct BatteryChip: View {
    let label: String?
    let value: Int
    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label).foregroundStyle(.white.opacity(0.55)) }
            Image(systemName: value <= 20 ? "battery.25percent" : (value <= 60 ? "battery.50percent" : "battery.100percent"))
                .foregroundStyle(value <= 20 ? Color.red : Color.green)
            Text("\(value)%").monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
    }
}

/// Pin cỡ lớn cho thông báo sạc: thanh pin chạy đầy tới % hiện tại, có tia sét khi đang sạc.
struct BigBattery: View {
    let percent: Int
    let charging: Bool
    @State private var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.5), lineWidth: 2)
                    .frame(width: 58, height: 28)
                RoundedRectangle(cornerRadius: 5)
                    .fill(charging ? Color.green : (percent <= 20 ? Color.red : Color.white.opacity(0.9)))
                    .frame(width: max(4, 50 * fill), height: 20)
                    .padding(.leading, 4)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(width: 58, height: 28)
                }
            }
            RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.5)).frame(width: 3.5, height: 10)
        }
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.25)) {
                fill = CGFloat(min(max(percent, 0), 100)) / 100
            }
        }
    }
}

/// Dấu hiệu ghi âm: icon app đang dùng micro, chấm đỏ, thời gian cộng dồn qua các lần tạm dừng.
/// Thời gian là thời gian micro được dùng: khớp với app ghi âm khi app đó nhả micro lúc tạm dừng.
struct RecordingBadge: View {
    let info: RecordingInfo
    var showName = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = NSRunningApplication(processIdentifier: info.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            if info.paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                Text(Self.format(info.elapsed(at: ctx.date)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(info.paused ? Color.white.opacity(0.65) : Color(red: 1, green: 0.55, blue: 0.5))
            }
            if showName {
                Text(info.paused ? "· \(info.appName) tạm dừng" : "· \(info.appName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .help(info.paused ? "\(info.appName) đang tạm dừng" : "\(info.appName) đang dùng micro")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Waveform: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(Color(red: 1, green: 0.42, blue: 0.37))
                    .frame(width: 3, height: 3 + v * 17)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

// MARK: Dạng bung

struct ExpandedView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: max(m.notchHeight - 4, 0))
            HStack(spacing: 6) {
                TabBar(m: m)
                Spacer(minLength: 0)
                if let r = m.recording {
                    HStack(spacing: 8) {
                        RecordingBadge(info: r, showName: !m.micDenied)
                        if m.micDenied {
                            Button("Cấp quyền micro") {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            .buttonStyle(PillButton())
                        } else {
                            Waveform(levels: m.levels).scaleEffect(0.8)
                        }
                    }
                }
                // Bánh răng: mở Cài đặt ngay.
                NotchIconButton(symbol: "gearshape.fill", tint: .white.opacity(0.85), name: "Cài đặt") {
                    AppDelegate.shared?.controller.collapse()
                    AppDelegate.shared?.showSettings()
                }
                // Dấu ? nhỏ: mở Mẹo dùng đúng mục đang xem.
                NotchIconButton(symbol: "questionmark", tint: .white.opacity(0.85), name: "Mẹo dùng") {
                    let topic = TipTopic(tab: m.tab)
                    AppDelegate.shared?.controller.collapse()
                    AppDelegate.shared?.showTips(topic)
                }
                // Trái tim nhỏ: bấm vào mới mở cửa sổ Ủng hộ tác giả, không tự hiện gì.
                NotchIconButton(symbol: "heart.fill", tint: Color.pink.opacity(0.9), name: "Ủng hộ tác giả", tagAlignment: .bottomTrailing) {
                    AppDelegate.shared?.controller.collapse()
                    AppDelegate.shared?.showSupport()
                }
            }
            // Nhãn nổi dưới mục đang rê chuột phải vẽ đè lên phần nội dung bên dưới.
            .zIndex(1)
            Group {
                switch m.tab {
                case .media: MediaView(m: m)
                case .shelf: ShelfView(m: m)
                case .clipboard: ClipboardView(m: m)
                case .notes: NotesView(m: m)
                case .timer: TimerView(m: m)
                case .system: SystemView()
                case .tools: ToolsView(m: m)
                case .translate: TranslateView(m: m)
                case .windows: WindowsView(m: m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .onDrop(of: [UTType.fileURL], isTargeted: $m.dropTargeted) { providers in
            m.tab = .shelf
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in m.addToShelf([url]) }
                }
            }
            return true
        }
    }

}

/// Hàng mục trên tai thỏ. Rê chuột vào một mục: icon nhấc lên, nền sáng hơn, có viền mảnh, và một nhãn
/// nhỏ nổi ngay bên dưới (tên mục + phím tắt). Nhãn nằm đè, không đẩy các mục khác nên không bị giật.
/// Đổi mục thì nền sáng trượt sang mục mới.
struct TabBar: View {
    @ObservedObject var m: NotchModel
    @Namespace private var ns
    @State private var hover: Tab?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Tab.allCases) { t in
                tabButton(t)
            }
        }
    }

    private func tabButton(_ t: Tab) -> some View {
        let selected = m.tab == t
        let hovered = hover == t
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { m.tab = t }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected || hovered ? t.tint : Color.white.opacity(0.72))
                    .scaleEffect(hovered ? 1.14 : 1)
                    .offset(y: hovered && !selected ? -1.5 : 0)
                if selected && m.recording == nil {
                    Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    Capsule().fill(Color.white.opacity(hovered ? 0.13 : 0.06))
                    if selected {
                        // Nền mục đang chọn ngả nhẹ theo màu của mục, trượt sang khi đổi mục.
                        Capsule().fill(t.tint.opacity(0.2)).matchedGeometryEffect(id: "selected", in: ns)
                    }
                }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(hovered ? 0.22 : 0), lineWidth: 1))
            .shadow(color: .white.opacity(hovered ? 0.12 : 0), radius: 6)
            .foregroundStyle(.white.opacity(selected || hovered ? 1 : 0.72))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if hovered && (!selected || m.recording != nil) {
                HoverTag(text: tagText(t))
                    .offset(y: 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)).combined(with: .offset(y: -4)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovered ? 2 : 0)
        .onHover { inside in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                if inside { hover = t } else if hover == t { hover = nil }
            }
        }
    }

    private func tagText(_ t: Tab) -> String {
        guard let a = HotAction(rawValue: t.rawValue), HotkeyCenter.isEnabled(a), let c = HotkeyCenter.combo(a) else {
            return t.title
        }
        return "\(t.title)  \(c.display)"
    }
}

/// Nhãn nhỏ nổi dưới nút khi rê chuột.
struct HoverTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            .foregroundStyle(.white)
    }
}

/// Nút tròn nhỏ góc phải tai thỏ (Cài đặt, ?, trái tim), có hiệu ứng khi rê chuột như hàng mục.
struct NotchIconButton: View {
    let symbol: String
    let tint: Color
    let name: String
    /// Nút sát mép phải: nhãn canh phải cho khỏi bị mép tai thỏ cắt.
    var tagAlignment: Alignment = .bottom
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .scaleEffect(hovered ? 1.15 : 1)
                .rotationEffect(.degrees(symbol.hasPrefix("gearshape") && hovered ? 45 : 0))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.14 : 0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovered ? 0.22 : 0), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: tagAlignment) {
            if hovered {
                HoverTag(text: name)
                    .offset(y: 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(hovered ? 2 : 0)
        .onHover { inside in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { hovered = inside }
        }
    }
}

// MARK: Nhạc / video

struct MediaView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        if let np = m.nowPlaying, !np.title.isEmpty {
            HStack(spacing: 18) {
                ArtworkView(image: m.artwork, size: 112, radius: 18)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let icon = NSRunningApplication(processIdentifier: np.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        }
                        Text(np.appName).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }
                    Text(np.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(np.artist.isEmpty ? np.album : np.artist)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    if np.duration > 0 {
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            let pos = np.position(at: ctx.date)
                            VStack(spacing: 4) {
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.18))
                                        Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(pos / np.duration))
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { loc in
                                        MediaHub.shared?.command("seek \(Double(loc.x / g.size.width) * np.duration)")
                                    }
                                }
                                .frame(height: 5)
                                HStack {
                                    Text(formatClock(pos)).monospacedDigit()
                                    Spacer()
                                    Text("-" + formatClock(np.duration - pos)).monospacedDigit()
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    HStack(spacing: 22) {
                        mediaButton("backward.fill", size: 17) { MediaHub.shared?.command("prev") }
                        mediaButton(np.playing ? "pause.fill" : "play.fill", size: 24) { MediaHub.shared?.command("toggle") }
                        mediaButton("forward.fill", size: 17) { MediaHub.shared?.command("next") }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 22))
                Text("Chưa có gì đang phát").font(.system(size: 12, weight: .semibold))
                Text(MediaWatcher.shared?.statusText ?? "Mở nhạc hoặc video, tên bài sẽ hiện ở đây")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func mediaButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlain())
    }
}

// MARK: Hẹn giờ

struct TimerView: View {
    @ObservedObject var m: NotchModel
    private let presets = [1, 3, 5, 10, 15, 25, 30, 45, 60]

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    modeButton(.stopwatch, "Bấm giờ", "stopwatch")
                    modeButton(.countdown, "Đếm ngược", "timer")
                }
                if m.timer.mode == .stopwatch {
                    // Bấm giờ có phần trăm giây: vẽ lại theo khung hình chỉ khi đang chạy và mục này đang mở.
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !m.timer.running)) { ctx in
                        let t = m.timer.display(at: ctx.date)
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(formatClock(t, alwaysHours: true))
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                            Text(String(format: ",%02d", Int((t - t.rounded(.down)) * 100)))
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle((m.timer.running ? Color.orange : Color.white).opacity(0.7))
                        }
                        .monospacedDigit()
                        .foregroundStyle(m.timer.running ? Color.orange : Color.white)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                        Text(formatClock(m.timer.display(at: ctx.date), alwaysHours: true))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(m.timer.running ? Color.orange : Color.white)
                    }
                }
                HStack(spacing: 8) {
                    Button(m.timer.running ? "Tạm dừng" : (m.timer.accumulated > 0 ? "Tiếp tục" : "Bắt đầu")) {
                        TimerEngine.shared?.toggle()
                    }
                    .buttonStyle(PillButton(prominent: true))
                    Button("Đặt lại") { TimerEngine.shared?.reset() }
                        .buttonStyle(PillButton())
                        .disabled(!m.timer.active)
                }
            }
            if m.timer.mode == .countdown {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đếm ngược").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 3), spacing: 6) {
                        ForEach(presets, id: \.self) { min in
                            Button {
                                TimerEngine.shared?.setCountdown(minutes: min)
                            } label: {
                                Text(min == 60 ? "1 giờ" : "\(min) phút")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 58, height: 26)
                                    .background(Capsule().fill(Color.white.opacity(
                                        Int(m.timer.countdownTotal) == min * 60 ? 0.24 : 0.08)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(HoverPlain())
                            .disabled(m.timer.running)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bấm giờ tới phần trăm giây").font(.system(size: 12, weight: .semibold))
                    Text("Đang chạy thì tai thỏ hiện giờ ở hai bên, rê chuột vào để dừng hoặc đặt lại.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 200)
            }
            Spacer(minLength: 0)
        }
    }

    func modeButton(_ mode: TimerMode, _ title: String, _ symbol: String) -> some View {
        Button {
            TimerEngine.shared?.setMode(mode)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(m.timer.mode == mode ? 0.2 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(HoverPlain())
        .disabled(m.timer.running)
    }
}

@MainActor
final class TimerEngine {
    static var shared: TimerEngine?
    private let m: NotchModel
    /// Chỉ có khi đang đếm ngược: hẹn đúng lúc hết giờ, không chạy thường trực.
    private var doneTimer: Timer?

    init(model: NotchModel) {
        m = model
    }

    private func reschedule() {
        doneTimer?.invalidate()
        doneTimer = nil
        let t = m.timer
        guard t.running, t.mode == .countdown else { return }
        let left = max(t.countdownTotal - t.elapsed(at: Date()), 0)
        let timer = Timer(timeInterval: left + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        doneTimer = timer
    }

    func toggle() {
        var t = m.timer
        if t.running {
            t.accumulated = t.elapsed(at: Date())
            t.startedAt = nil
            t.running = false
        } else {
            if t.mode == .countdown && t.elapsed(at: Date()) >= t.countdownTotal { t.accumulated = 0 }
            t.startedAt = Date()
            t.running = true
        }
        m.timer = t
        reschedule()
    }

    func reset() {
        var t = m.timer
        t.running = false
        t.startedAt = nil
        t.accumulated = 0
        m.timer = t
        reschedule()
    }

    func setMode(_ mode: TimerMode) {
        guard !m.timer.running else { return }
        var t = m.timer
        t.mode = mode
        t.accumulated = 0
        t.startedAt = nil
        m.timer = t
        reschedule()
    }

    func setCountdown(minutes: Int) {
        guard !m.timer.running else { return }
        var t = m.timer
        t.countdownTotal = TimeInterval(minutes * 60)
        t.accumulated = 0
        m.timer = t
        reschedule()
    }

    private func check() {
        let t = m.timer
        guard t.running, t.mode == .countdown else { return }
        guard t.elapsed(at: Date()) >= t.countdownTotal else { reschedule(); return }
        var done = t
        done.running = false
        done.startedAt = nil
        done.accumulated = 0
        m.timer = done
        m.showTransient(.timerDone(minutes: Int(t.countdownTotal / 60)), seconds: 8)
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
        }
    }
}

// MARK: Hệ thống

@MainActor
final class SystemMonitor: ObservableObject {
    /// Cổng host lấy một lần: mỗi lần gọi mach_host_self() lại thêm một tham chiếu cổng mà không trả.
    nonisolated static let host: mach_port_t = mach_host_self()
    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var ramUsed: Double = 0
    @Published var ramTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var down: Double = 0
    @Published var up: Double = 0
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var battery: Int?

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    /// Đo luôn một lần lúc tạo để khung hình đầu tiên đã có số thật (RAM, pin, nhiệt).
    init() { sample() }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        lastNet = nil
    }

    private func sample() {
        // CPU
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(SystemMonitor.host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if kr == KERN_SUCCESS {
            let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
            let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
            let busy = user + sys + nice, total = busy + idle
            if let l = lastTicks, total > l.total {
                cpu = Double(busy - l.busy) / Double(total - l.total) * 100
                cpuHistory.removeFirst()
                cpuHistory.append(cpu)
            }
            lastTicks = (busy, total)
        }
        // RAM (cách tính gần giống Activity Monitor: bộ nhớ app + wired + nén)
        var vm = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
                host_statistics64(SystemMonitor.host, HOST_VM_INFO64, $0, &c)
            }
        }
        if kr2 == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            ramUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }
        // Mạng
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let ifa = cur.pointee
                if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                    let name = String(cString: ifa.ifa_name)
                    if !name.hasPrefix("lo") {
                        let d = data.assumingMemoryBound(to: if_data.self).pointee
                        rx += UInt64(d.ifi_ibytes)
                        tx += UInt64(d.ifi_obytes)
                    }
                }
                p = ifa.ifa_next
            }
            freeifaddrs(first)
        }
        let now = Date()
        if let l = lastNet {
            let dt = max(now.timeIntervalSince(l.at), 0.2)
            down = rx >= l.rx ? Double(rx - l.rx) / dt : down
            up = tx >= l.tx ? Double(tx - l.tx) / dt : up
        }
        lastNet = (rx, tx, now)
        thermal = ProcessInfo.processInfo.thermalState
        let b = PowerWatcher.read()
        battery = b.ac == nil ? nil : b.percent
    }

    static func speed(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        return String(format: "%.0f KB/s", bps / 1_000)
    }
    static func gb(_ b: Double) -> String { String(format: "%.1f", b / 1_073_741_824) }
}

struct SystemView: View {
    @StateObject private var mon = SystemMonitor()

    var thermalText: (String, Color) {
        switch mon.thermal {
        case .nominal: return ("Bình thường", .green)
        case .fair: return ("Hơi ấm", .yellow)
        case .serious: return ("Nóng", .orange)
        case .critical: return ("Rất nóng", .red)
        @unknown default: return ("Không rõ", .gray)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            RingTile(title: "CPU", value: mon.cpu / 100, text: String(format: "%.0f%%", mon.cpu),
                     detail: "đang dùng", colors: [Color.cyan, Color.blue])
            RingTile(title: "RAM", value: mon.ramUsed / max(mon.ramTotal, 1), text: "\(SystemMonitor.gb(mon.ramUsed))",
                     detail: "trên \(SystemMonitor.gb(mon.ramTotal)) GB", colors: [Color.purple, Color.pink])
            if let b = mon.battery {
                RingTile(title: "Pin", value: Double(b) / 100, text: "\(b)%", detail: b <= 20 ? "pin yếu" : "còn lại",
                         colors: b <= 20 ? [Color.red, Color.orange] : [Color.green, Color.mint])
            }
            RingTile(title: "Nhiệt", value: Double(levelIndex + 1) / 4, text: thermalText.0, detail: "macOS báo",
                     colors: [thermalText.1.opacity(0.7), thermalText.1], small: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mạng").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Label(SystemMonitor.speed(mon.down), systemImage: "arrow.down.circle.fill").foregroundStyle(Color.green)
                Label(SystemMonitor.speed(mon.up), systemImage: "arrow.up.circle.fill").foregroundStyle(Color.blue)
                Sparkline(values: mon.cpuHistory, maxValue: 100).stroke(Color.cyan.opacity(0.6), lineWidth: 1.2).frame(height: 22)
                Text("CPU 30 giây qua").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
            .hoverCard(tint: .blue)
        }
        .onAppear { mon.start() }
        .onDisappear { mon.stop() }
    }

    var levelIndex: Int {
        switch mon.thermal {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        default: return 3
        }
    }

}

/// Vòng tròn kiểu đồng hồ đo: số ở giữa, tên và ghi chú bên dưới.
struct RingTile: View {
    let title: String
    let value: Double
    let text: String
    let detail: String
    let colors: [Color]
    var small = false
    /// Lúc vừa mở mục Hệ thống: vẽ đúng số ngay, không cho vòng chạy từ 0 hay nhảy qua lại.
    @State private var settled = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0.02), 1)))
                    .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors.last!.opacity(0.5), radius: 4)
                Text(text)
                    .font(.system(size: small ? 11 : 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
            }
            .frame(width: 66, height: 66)
            .animation(settled ? .spring(response: 0.6, dampingFraction: 0.85) : nil, value: value)
            .transaction { if !settled { $0.animation = nil } }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled = true }
            }
            VStack(spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
        .hoverCard(tint: colors.first ?? .white)
    }
}

struct Sparkline: Shape {
    var values: [Double]
    var maxValue: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = r.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: r.maxY - r.height * CGFloat(min(v / maxValue, 1)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: Kệ file

struct ShelfView: View {
    @ObservedObject var m: NotchModel
    /// Chừa chỗ quanh hàng thẻ để thẻ phóng lên khi rê chuột không bị cắt.
    static let rowPad: CGFloat = 6
    /// Khung chọn dùng chung: kéo từ chỗ trống ở hàng nút lọc xuống hàng thẻ cũng được.
    @StateObject private var marquee = MarqueeState()

    var body: some View {
        if m.shelf.isEmpty {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(Color.white.opacity(m.dropTargeted ? 0.85 : 0.3))
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(m.dropTargeted ? 0.08 : 0)))
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                        Text("Kéo file thả vào tai thỏ").font(.system(size: 12, weight: .semibold))
                        Text("Kéo ra = sao chép · giữ ⌘ khi kéo = chuyển file")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                )
        } else {
            let sel = m.selectedShelf
            let list = m.visibleShelf
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // Đủ chỗ thì để hàng nút lọc bình thường: chỗ trống bên phải nhận kéo khung chọn.
                    // Nhiều loại file quá thì mới cho cuộn ngang.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            ShelfChips(m: m)
                            Spacer(minLength: 0)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) { ShelfChips(m: m) }
                        }
                    }
                    Button {
                        AppDelegate.shared?.showLibrary(.shelf)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(HoverPlain())
                    .help("Mở bảng lớn (\(HotkeyCenter.combo(.library)?.display ?? "⌃⇧0"))")
                }
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(list, id: \.self) { url in
                                ShelfItem(url: url, m: m, selected: m.shelfSelection.contains(url), space: "shelfArea")
                            }
                        }
                        .padding(Self.rowPad)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                        // Kéo khung ở chỗ trống để chọn nhiều, bấm chỗ trống để bỏ chọn.
                        .modifier(ShelfMarquee(m: m, space: "shelfArea", state: marquee, root: false))
                    }
                }
                .frame(height: ShelfItem.height + Self.rowPad * 2)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: list)
                }
                .modifier(ShelfMarquee(m: m, space: "shelfArea", state: marquee))
                HStack(spacing: 8) {
                    if m.shelfBusy {
                        ProgressView().controlSize(.mini)
                    }
                    Text(m.shelfStatus ?? (sel.isEmpty ? "Kéo chuột để chọn nhiều · kéo ra = sao chép · giữ ⌘ = chuyển"
                                     : "Đã chọn \(sel.count) file · kéo ra là đi cả nhóm"))
                        .font(.system(size: 11)).foregroundStyle(m.shelfStatus != nil ? Color.green.opacity(0.9) : .white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    let targets = sel.isEmpty ? list : sel
                    Button("AirDrop") { Actions.airDrop(targets) }.buttonStyle(PillButton(prominent: true))
                    Button("Sao chép") { Actions.copyFiles(targets) }.buttonStyle(PillButton())
                    Menu {
                        ForEach(ShelfTools.ops(for: targets), id: \.self) { op in
                            Button(op.title) { ShelfTools.run(op, on: targets, m: m) }
                        }
                    } label: {
                        Text("Xử lý").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .hoverPop(scale: 1.09)
                    .disabled(m.shelfBusy || targets.isEmpty)
                    .help("Đổi định dạng, nén, thu nhỏ, xoá nền ảnh · gộp PDF · nén ZIP")
                    if sel.isEmpty {
                        Button("Xoá kệ") { m.clearShelf() }.buttonStyle(PillButton())
                    } else {
                        Button("Bỏ khỏi kệ") { m.removeFromShelf(sel) }.buttonStyle(PillButton())
                    }
                }
            }
        }
    }
}

struct ShelfItem: View {
    static let width: CGFloat = 138
    static let height: CGFloat = 104

    let url: URL
    @ObservedObject var m: NotchModel
    var selected = false
    var w: CGFloat = ShelfItem.width
    var h: CGFloat = ShelfItem.height
    /// Vùng toạ độ của khung chọn (để báo vị trí thẻ cho việc kéo khung chọn nhiều).
    var space: String? = nil

    var body: some View {
        card.background {
            if let space {
                GeometryReader { g in
                    Color.clear.preference(key: ShelfFrameKey.self, value: [url: g.frame(in: .named(space))])
                }
            }
        }
    }

    @ViewBuilder private var card: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let kind = ShelfKind.of(url)
        ZStack(alignment: .bottom) {
            FileCardThumb(url: url, size: CGSize(width: w, height: h))
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 0) {
                    Text(exists ? url.lastPathComponent : "File không còn")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(FileInfo.size(url)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(m.shelfHover == url ? 0.28 : 0.1), lineWidth: selected ? 2 : 1)
        )
        // Vòng chọn góc trái: bấm vào là thêm / bớt file đó khỏi vùng chọn (khỏi cần giữ ⌘).
        .overlay(alignment: .topLeading) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
            } else if m.shelfHover == url || !m.shelfSelection.isEmpty {
                Circle()
                    .fill(Color.black.opacity(0.35))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .scaleEffect(m.shelfHover == url ? 1.03 : 1)
        .shadow(color: .black.opacity(m.shelfHover == url ? 0.4 : 0), radius: 8, y: 3)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: m.shelfHover == url)
        .opacity(exists ? 1 : 0.45)
        .overlay(FileDragArea(url: url, m: m))
        .help(url.path)
    }
}

/// Vùng kéo file ra khỏi kệ: kéo thường = sao chép, giữ ⌘ khi kéo = chuyển file.
/// Bấm để chọn, ⌘/⇧ + bấm để chọn thêm, bấm đúp để mở, chuột phải để xem thêm.
struct FileDragArea: NSViewRepresentable {
    let url: URL
    let m: NotchModel

    func makeNSView(context: Context) -> FileDragNSView {
        let v = FileDragNSView()
        v.url = url
        v.model = m
        return v
    }

    func updateNSView(_ v: FileDragNSView, context: Context) {
        v.url = url
        v.model = m
    }
}

final class FileDragNSView: NSView, NSDraggingSource {
    var url = URL(fileURLWithPath: "/")
    weak var model: NotchModel?
    private var downEvent: NSEvent?
    private var dragged: [URL] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Rê chuột lên thẻ: báo cho SwiftUI để thẻ nổi lên giống thẻ Bộ nhớ tạm.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { model?.shelfHover = url }
    override func mouseExited(with event: NSEvent) { if model?.shelfHover == url { model?.shelfHover = nil } }

    /// Các file sẽ tác động: cả vùng chọn nếu file này nằm trong đó, không thì chỉ file này.
    private var targets: [URL] {
        guard let m = model, m.shelfSelection.contains(url) else { return [url] }
        let sel = m.selectedShelf
        return sel.isEmpty ? [url] : sel
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            for u in targets where FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) }
            downEvent = nil
            return
        }
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        // Bấm rồi thả, không kéo: chọn file.
        guard downEvent != nil, let m = model else { downEvent = nil; return }
        downEvent = nil
        let p = convert(event.locationInWindow, from: nil)
        let inCircle = isFlipped ? (p.x < 32 && p.y < 32) : (p.x < 32 && p.y > bounds.height - 32)
        if inCircle {
            if m.shelfSelection.contains(url) { m.shelfSelection.remove(url) } else { m.shelfSelection.insert(url) }
            m.shelfAnchor = url
            return
        }
        let mods = event.modifierFlags
        if mods.contains(.shift), let anchor = m.shelfAnchor,
           let a = m.shelf.firstIndex(of: anchor), let b = m.shelf.firstIndex(of: url) {
            m.shelfSelection.formUnion(m.shelf[min(a, b)...max(a, b)])
        } else if mods.contains(.command) || mods.contains(.shift) {
            if m.shelfSelection.contains(url) { m.shelfSelection.remove(url) } else { m.shelfSelection.insert(url) }
            m.shelfAnchor = url
        } else {
            m.shelfSelection = [url]
            m.shelfAnchor = url
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        downEvent = nil
        // Kéo file chưa được chọn thì chỉ kéo riêng file đó (giống Finder).
        if let m = model, !m.shelfSelection.contains(url) {
            m.shelfSelection = [url]
            m.shelfAnchor = url
        }
        let urls = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        dragged = urls
        let p = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { i, u in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            icon.size = NSSize(width: 56, height: 56)
            let shift = CGFloat(min(i, 4)) * 5
            item.setDraggingFrame(NSRect(x: p.x - 28 + shift, y: p.y - 28 - shift, width: 56, height: 56), contents: icon)
            return item
        }
        model?.draggingOut = true
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return [] }
        // Mặc định sao chép; giữ ⌘ thì cho phép chuyển (Finder sẽ dời file đi).
        return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.draggingOut = false
        let moved = operation.contains(.move) || operation.contains(.generic)
        // Chỉ coi là đã chuyển khi file gốc thật sự không còn ở chỗ cũ.
        let files = dragged
        dragged = []
        guard moved else { return }
        let removeGone: () -> Void = { [weak self] in
            let gone = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard !gone.isEmpty, let m = self?.model else { return }
            m.removeFromShelf(gone)
            Diag.log("Đã chuyển \(gone.count) file ra khỏi kệ")
        }
        removeGone()
        // Chuyển sang ổ đĩa khác thì Finder chép xong mới xoá file gốc: kiểm lại sau 2 giây.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { removeGone() } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let m = model else { return nil }
        if !m.shelfSelection.contains(url) {
            m.shelfSelection = [url]
            m.shelfAnchor = url
        }
        let us = targets
        let n = us.count
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(n > 1 ? "Mở \(n) file" : "Mở") { for u in us { NSWorkspace.shared.open(u) } })
        menu.addItem(ClosureMenuItem(n > 1 ? "Gửi AirDrop \(n) file" : "Gửi AirDrop") { Actions.airDrop(us) })
        menu.addItem(ClosureMenuItem(n > 1 ? "Sao chép \(n) file" : "Sao chép") { Actions.copyFiles(us) })
        menu.addItem(ClosureMenuItem("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting(us) })
        if n == 1, let u = us.first, FileManager.default.fileExists(atPath: u.path) {
            menu.addItem(ClosureMenuItem("Đổi tên file…") { [weak m] in if let m { ShelfRename.run(u, m: m) } })
        }
        let tools = NSMenuItem(title: "Xử lý", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for op in ShelfTools.ops(for: us) {
            sub.addItem(ClosureMenuItem(op.title) { [weak m] in if let m { ShelfTools.run(op, on: us, m: m) } })
        }
        tools.submenu = sub
        tools.isEnabled = !m.shelfBusy
        menu.addItem(tools)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Chọn tất cả") { [weak m] in m?.shelfSelection = Set(m?.shelf ?? []) })
        menu.addItem(ClosureMenuItem(n > 1 ? "Bỏ \(n) file khỏi kệ" : "Bỏ khỏi kệ") { [weak m] in m?.removeFromShelf(us) })
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// Ảnh xem trước của file (ảnh, video, PDF…) qua QuickLook; chưa có thì dùng icon file.
struct FileThumb: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 64, height: 50), scale: scale, representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb = rep.nsImage
            }
        }
    }
}

// MARK: Ghi chú nhanh

struct NotesView: View {
    @ObservedObject var m: NotchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $m.noteDraft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 7)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.command) {
                                NotesSaver.save(m)
                                return .handled
                            }
                            return .ignored
                        }
                    if m.noteDraft.isEmpty {
                        Text("Gõ ý tưởng… Enter để xuống dòng")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
                .hoverOutline()
                HStack(spacing: 8) {
                    Text(m.noteStatus ?? "Lưu bằng nút Lưu hoặc ⌘ Enter")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Lưu vào Notes") { NotesSaver.save(m) }
                        .buttonStyle(PillButton(prominent: true))
                        .disabled(m.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        AppDelegate.shared?.showLibrary(.notes)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(HoverPlain())
                    .help("Mở bảng lớn")
                }
            }
            if !m.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gần đây").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(m.notes.prefix(10)) { n in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: n.savedToNotes ? "checkmark.circle.fill" : "circle.dashed")
                                        .font(.system(size: 10))
                                        .foregroundStyle(n.savedToNotes ? Color.green : Color.white.opacity(0.4))
                                        .padding(.top, 2)
                                    Text(n.text).font(.system(size: 11)).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(width: 170)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } }
    }
}

enum NotesSaver {
    @MainActor
    static func save(_ m: NotchModel) {
        let text = m.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = NoteItem(text: text, date: Date(), savedToNotes: false)
        m.notes.insert(item, at: 0)
        m.noteDraft = ""
        m.noteStatus = "Đang lưu vào Notes…"
        m.saveNotes()

        let html = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        // Nội dung đi qua file tạm: ghi chú bắt đầu bằng "-" (gạch đầu dòng) mà đưa thẳng làm tham số
        // thì osascript hiểu nhầm là tuỳ chọn và không lưu được.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rinnotch-note-\(UUID().uuidString).html")
        do { try html.write(to: tmp, atomically: true, encoding: .utf8) } catch {
            m.noteStatus = "Chưa lưu được vào Notes, ghi chú vẫn được giữ trong app."
            return
        }
        let script = [
            "on run argv",
            "set t to read (POSIX file (item 1 of argv)) as «class utf8»",
            "tell application \"Notes\"",
            "if not (exists folder \"RinNotch\") then make new folder with properties {name:\"RinNotch\"}",
            "make new note at folder \"RinNotch\" with properties {body:t}",
            "end tell",
            "end run",
        ]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = script.flatMap { ["-e", $0] } + [tmp.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        let id = item.id
        p.terminationHandler = { proc in
            try? FileManager.default.removeItem(at: tmp)
            let ok = proc.terminationStatus == 0
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                if let i = m.notes.firstIndex(where: { $0.id == id }) { m.notes[i].savedToNotes = ok }
                m.saveNotes()
                if ok {
                    m.noteStatus = "Đã lưu vào Notes, thư mục RinNotch ✓"
                } else if msg.contains("-1743") || msg.lowercased().contains("not authorized") {
                    m.noteStatus = "Chưa có quyền: Cài đặt → Quyền riêng tư & Bảo mật → Tự động hoá → RinNotch → bật Notes. Ghi chú vẫn được giữ trong app."
                } else {
                    m.noteStatus = "Chưa lưu được vào Notes, ghi chú vẫn được giữ trong app."
                }
            }
        }
        do { try p.run() } catch {
            try? FileManager.default.removeItem(at: tmp)
            m.noteStatus = "Chưa lưu được vào Notes, ghi chú vẫn được giữ trong app."
        }
    }
}

// MARK: - Hành động chung

enum Actions {
    @MainActor
    static func airDrop(_ urls: [URL]) {
        let items = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty, let svc = NSSharingService(named: .sendViaAirDrop) else { return }
        svc.perform(withItems: items)
    }

    @MainActor
    static func copyFiles(_ urls: [URL]) {
        let items = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items as [NSURL])
        ClipboardWatcher.shared?.ignore(pb.changeCount)
    }
}

// MARK: - Âm thanh: tai nghe và ghi âm

enum CA {
    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    static func name(_ dev: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return "" }
        return n.takeRetainedValue() as String
    }

    static func transport(_ dev: AudioDeviceID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t)
        return t
    }

    /// Các tiến trình (không phải RinNotch) đang dùng micro. Cần macOS 14+.
    /// Các thiết bị có đường thu (micro trong máy, AirPods, micro rời…).
    static func inputDevices() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var s = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var n: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr && n > 0
        }
    }

    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    static func micUsers() -> [pid_t] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        var result: [pid_t] = []
        for id in ids {
            var ra = addr(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var rs = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            var pa = addr(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid) == noErr, pid != me {
                result.append(pid)
            }
        }
        return result
    }
}

@MainActor
final class HeadphoneWatcher {
    private let m: NotchModel
    private var lastDevice: AudioDeviceID

    init(model: NotchModel) {
        m = model
        lastDevice = CA.defaultOutput()
        var a = CA.addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func changed() {
        let dev = CA.defaultOutput()
        guard dev != lastDevice else { return }
        lastDevice = dev
        let t = CA.transport(dev)
        guard t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE else { return }
        guard Prefs.showHeadphones else { return }
        let name = CA.name(dev)
        let info = HeadphoneInfo(name: name.isEmpty ? "Tai nghe" : name, symbol: Self.symbol(for: name))
        m.showTransient(.headphones(info), seconds: 5)
        fetchBattery(for: info, attempt: 0)
    }

    /// Đọc % pin tai nghe từ System Information (system_profiler). Không có API chính thức nên có thể trống.
    private func fetchBattery(for info: HeadphoneInfo, attempt: Int) {
        let name = info.name
        DispatchQueue.global(qos: .userInitiated).async {
            let levels = HeadphoneWatcher.readBattery(name: name)
            Task { @MainActor in
                guard case .headphones(let cur) = self.m.transient, cur.name == name else { return }
                if let l = levels {
                    var u = cur
                    u.left = l.left; u.right = l.right; u.caseLevel = l.caseLevel; u.main = l.main
                    if let pid = l.productID, let sym = HeadphoneWatcher.symbol(forProductID: pid) {
                        u.symbol = sym
                        Diag.log("Mã tai nghe \(pid) → \(sym)")
                    } else if let pid = l.productID {
                        Diag.log("Mã tai nghe \(pid) chưa có trong bảng, dùng icon theo tên")
                    }
                    self.m.transient = .headphones(u)
                    Diag.log("Pin tai nghe: T \(l.left ?? -1) P \(l.right ?? -1) Hộp \(l.caseLevel ?? -1) Chung \(l.main ?? -1)")
                } else if attempt == 0 {
                    // Vừa kết nối macOS có thể chưa có số pin, thử lại một lần.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated { self.fetchBattery(for: info, attempt: 1) }
                    }
                } else {
                    Diag.log("Không đọc được pin của \(name)")
                }
            }
        }
    }

    nonisolated static func readBattery(name: String) -> (left: Int?, right: Int?, caseLevel: Int?, main: Int?, productID: String?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        func num(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.filter(\.isNumber))
        }
        for item in items {
            guard let connected = item["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (devName, value) in entry {
                    guard let d = value as? [String: Any] else { continue }
                    guard devName == name || connected.count == 1 else { continue }
                    let r = (left: num(d["device_batteryLevelLeft"]), right: num(d["device_batteryLevelRight"]),
                             caseLevel: num(d["device_batteryLevelCase"]), main: num(d["device_batteryLevelMain"]),
                             productID: (d["device_productID"] as? String)?.lowercased())
                    if r.left != nil || r.right != nil || r.caseLevel != nil || r.main != nil || r.productID != nil { return r }
                }
            }
        }
        return nil
    }

    /// Mã sản phẩm Bluetooth của Apple/Beats → icon SF Symbols (theo bảng Bluetooth PIDs của The Apple Wiki).
    /// Mỗi mẫu có vài tên icon dự phòng vì tên icon khác nhau giữa các bản macOS.
    static let productSymbols: [String: [String]] = [
        "0x2002": ["airpods"], "0x200f": ["airpods"],
        "0x2013": ["airpods.gen3", "airpods"],
        "0x2019": ["airpods.gen4", "airpods.gen3", "airpods"], "0x201b": ["airpods.gen4", "airpods.gen3", "airpods"],
        "0x200e": ["airpodspro", "airpods.pro"], "0x2014": ["airpodspro", "airpods.pro"], "0x2024": ["airpodspro", "airpods.pro"],
        "0x200a": ["airpodsmax", "airpods.max"], "0x201f": ["airpodsmax", "airpods.max"], "0x202d": ["airpodsmax", "airpods.max"],
        "0x200b": ["beats.powerbeatspro", "beats.earphones"], "0x2003": ["beats.earphones"], "0x200d": ["beats.earphones"],
        "0x2005": ["beats.earphones"], "0x2010": ["beats.earphones"],
        "0x2006": ["beats.headphones"], "0x2009": ["beats.headphones"], "0x200c": ["beats.headphones"],
        "0x2017": ["beats.headphones"], "0x2025": ["beats.headphones"],
        "0x2011": ["beats.studiobuds", "beats.earphones"], "0x2016": ["beats.studiobuds", "beats.earphones"],
        "0x2012": ["beats.fitpro", "beats.earphones"], "0x2026": ["beats.solobuds", "beats.earphones"],
        "0x201a": ["beats.pill", "hifispeaker"], "0x2600": ["beats.pill", "hifispeaker"],
    ]

    static func symbol(forProductID pid: String) -> String? {
        guard let list = productSymbols[pid.lowercased()] else { return nil }
        return list.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        var candidates: [String] = []
        if n.contains("airpods max") { candidates.append("airpodsmax") }
        else if n.contains("airpods pro") { candidates.append("airpodspro") }
        else if n.contains("airpods") { candidates.append(contentsOf: ["airpods.gen3", "airpods"]) }
        else if n.contains("beats") || n.contains("powerbeats") { candidates.append("beats.headphones") }
        candidates.append("headphones")
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "headphones"
    }
}

@MainActor
final class RecordingWatcher {
    private let m: NotchModel
    private var timer: Timer?
    private var engine: AVAudioEngine?
    private var meterRetryAfter: Date?
    private var lastPush = Date.distantPast
    private var requesting = false
    private var peakSinceLog: CGFloat = 0
    private var lastLog = Date.distantPast

    /// macOS báo khi có micro bắt đầu / thôi được dùng. Micro rảnh thì chỉ hỏi lại mỗi 5 giây (phòng khi không nhận được báo),
    /// thay vì hỏi danh sách tiến trình âm thanh mỗi 0,5 giây suốt ngày.
    private var micActive = false
    private var inputs: [AudioObjectID] = []
    private var interval: TimeInterval = 0
    private var tickCount = 0
    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.inputsChanged() }
    }
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.watchInputs() }
    }

    init(model: NotchModel) {
        m = model
        var a = CA.addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, devicesListener)
        watchInputs()
        tick()
    }

    private func watchInputs() {
        var a = CA.addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for d in inputs { AudioObjectRemovePropertyListenerBlock(d, &a, DispatchQueue.main, runningListener) }
        inputs = CA.inputDevices()
        for d in inputs { AudioObjectAddPropertyListenerBlock(d, &a, DispatchQueue.main, runningListener) }
        inputsChanged()
    }

    private func inputsChanged() {
        let active = inputs.contains { CA.isRunningSomewhere($0) }
        guard active != micActive else { return }
        micActive = active
        tick()
    }

    private func tick() {
        tickCount += 1
        let recording = session.map { !$0.paused } ?? false
        // Micro rảnh và đang có phiên tạm dừng: không cần hỏi mỗi giây, chỉ cần đếm giờ ẩn / hết phiên.
        let query = micActive || recording || session == nil || tickCount % 5 == 0
        check(query: query)
        let next: TimeInterval = micActive ? 0.5 : (session != nil ? 1 : 5)
        guard next != interval || timer == nil else { return }
        interval = next
        timer?.invalidate()
        let t = Timer(timeInterval: next, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = next * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Phiên ghi âm giữ lại tối đa 15 phút sau khi tạm dừng để ghi tiếp thì cộng dồn thời gian.
    private var session: RecordingInfo?
    private let pausedVisible: TimeInterval = 8
    private let sessionKeep: TimeInterval = 15 * 60

    private func check(query: Bool) {
        let now = Date()
        let apps = (query ? CA.micUsers() : [])
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { $0.activationPolicy == .regular }
        if let app = apps.first {
            if var s = session, s.bundleID == app.bundleIdentifier, s.pid == app.processIdentifier {
                if s.paused {
                    s.segmentStart = now
                    s.pausedAt = nil
                    session = s
                    Diag.log("Ghi tiếp, đã có \(Int(s.accumulated)) giây")
                }
            } else {
                session = RecordingInfo(
                    appName: app.localizedName ?? "Ứng dụng",
                    bundleID: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    segmentStart: now
                )
                Diag.log("Micro đang được dùng bởi \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
            }
            // Đổi micro giữa chừng (vd vừa kết nối AirPods) thì engine tự dừng: tắt hẳn để mở lại.
            if let e = engine, !e.isRunning { stopMeter() }
            // Tắt "App đang ghi âm" trong Cài đặt thì RinNotch không mở micro.
            if Prefs.showRecording { startMeter() } else { stopMeter() }
        } else if var s = session {
            if !s.paused {
                s.accumulated += now.timeIntervalSince(s.segmentStart ?? now)
                s.segmentStart = nil
                s.pausedAt = now
                session = s
                stopMeter()
                Diag.log("Micro được nhả (tạm dừng hoặc xong), đã ghi \(Int(s.accumulated)) giây")
            }
            let pausedFor = now.timeIntervalSince(s.pausedAt ?? now)
            let appGone = NSRunningApplication(processIdentifier: s.pid)?.isTerminated ?? true
            if appGone || pausedFor > sessionKeep {
                session = nil
            }
        }
        // Chỉ hiện trên tai thỏ khi đang ghi, hoặc vừa tạm dừng trong vài giây.
        var visible: RecordingInfo?
        if Prefs.showRecording, let s = session, !s.paused || now.timeIntervalSince(s.pausedAt ?? now) < pausedVisible {
            visible = s
        }
        if m.recording != visible { m.recording = visible }
    }

    private func startMeter() {
        guard engine == nil, !requesting else { return }
        // Mở micro lỗi thì đợi 30 giây mới thử lại, khỏi tạo engine mỗi 0,5 giây và tràn nhật ký.
        if let t = meterRetryAfter, Date() < t { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            m.micDenied = false
        case .notDetermined:
            requesting = true
            Diag.log("Xin quyền micro…")
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    self.requesting = false
                    Diag.log(ok ? "Đã được cấp quyền micro" : "Bị từ chối quyền micro")
                    self.m.micDenied = !ok
                    if ok, let s = self.session, !s.paused { self.startMeter() }
                }
            }
            return
        default:
            if !m.micDenied { Diag.log("Không có quyền micro (trạng thái \(status.rawValue))") }
            m.micDenied = true
            return
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        Diag.log("Định dạng micro: \(fmt.channelCount) kênh, \(Int(fmt.sampleRate)) Hz")
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            Diag.log("Micro không có kênh nào, bỏ qua")
            meterRetryAfter = Date().addingTimeInterval(30)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt, block: RecordingWatcher.makeTap(self))
        do {
            try e.start()
            engine = e
            Diag.log("Bắt đầu đo sóng âm")
        } catch {
            input.removeTap(onBus: 0)
            meterRetryAfter = Date().addingTimeInterval(30)
            Diag.log("Không mở được micro: \(error.localizedDescription)")
        }
    }

    /// Tạo block chạy trên luồng âm thanh (không gắn với luồng chính).
    nonisolated static func makeTap(_ owner: RecordingWatcher) -> AVAudioNodeTapBlock {
        weak var w = owner
        return { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var peak: Float = 0
            var sum: Float = 0
            let c = ch[0]
            for i in 0..<n {
                let v = c[i]
                sum += v * v
                peak = max(peak, abs(v))
            }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 0.000_001))
            // -60 dB (im lặng) → 0, -12 dB (nói to) → 1
            let level = CGFloat(min(max((db + 60) / 48, 0.04), 1))
            Task { @MainActor in w?.push(level) }
        }
    }

    private func push(_ v: CGFloat) {
        peakSinceLog = max(peakSinceLog, v)
        let now = Date()
        if now.timeIntervalSince(lastLog) > 3 {
            Diag.log(String(format: "Mức âm lớn nhất 3 giây qua: %.2f", peakSinceLog))
            peakSinceLog = 0
            lastLog = now
        }
        guard now.timeIntervalSince(lastPush) > 0.05 else { return }
        lastPush = now
        m.pushLevel(v)
    }

    private func stopMeter() {
        guard engine != nil else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        m.levels = Array(repeating: 0.08, count: 14)
    }
}

/// Nhật ký chẩn đoán 80 dòng gần nhất (chỉ trong bộ nhớ). Menu → Sao chép nhật ký.
@MainActor
enum Diag {
    static var lines: [String] = []
    static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lines.append("\(f.string(from: Date()))  \(s)")
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }
}

// MARK: - Nhạc / video đang phát

/// Chạy trình đọc "Đang phát" (perl + librinmedia.dylib) và nhận thông tin qua từng dòng JSON.
@MainActor
final class MediaWatcher {
    static var shared: MediaWatcher?
    private let m: NotchModel
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0
    private var startedAt: Date?
    private(set) var statusText: String?

    init(model: NotchModel) {
        m = model
        start()
    }

    func start() {
        guard let res = Bundle.main.resourceURL else { return }
        let script = res.appendingPathComponent("rinmedia.pl")
        let lib = res.appendingPathComponent("librinmedia.dylib")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: lib.path) else {
            statusText = "Thiếu trình đọc nhạc trong app"
            Diag.log("Thiếu rinmedia.pl hoặc librinmedia.dylib")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, lib.path]
        let out = Pipe(), inp = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = err
        // Hết dữ liệu (trình đọc đã thoát) thì gỡ handler, nếu không handler chạy liên tục tốn CPU.
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            guard let t = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in Diag.log("Trình đọc nhạc báo lỗi: \(t.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        p.terminationHandler = { [weak self] pr in
            let code = pr.terminationStatus
            Task { @MainActor in self?.died(code) }
        }
        do {
            try p.run()
            proc = p
            input = inp.fileHandleForWriting
            startedAt = Date()
            Diag.log("Đã chạy trình đọc nhạc")
        } catch {
            statusText = "Không chạy được trình đọc nhạc"
            Diag.log("Không chạy được perl: \(error.localizedDescription)")
        }
    }

    func send(_ cmd: String) {
        guard let input, let data = (cmd + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    func stop() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
    }

    private func died(_ code: Int32) {
        proc = nil
        try? input?.close()
        input = nil
        // Chạy ổn hơn 2 phút rồi mới dừng thì coi như lần dừng mới, không cộng dồn vào số lần lỗi.
        if let t = startedAt, Date().timeIntervalSince(t) > 120 { restarts = 0 }
        startedAt = nil
        Diag.log("Trình đọc nhạc dừng (mã \(code))")
        guard restarts < 5 else {
            statusText = "Trình đọc nhạc dừng nhiều lần, có thể macOS đã chặn cách này"
            return
        }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { self.start() }
        }
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { parse(line) }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }
    }

    private func parse(_ line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let e = o["error"] as? String {
            statusText = e
            Diag.log("Trình đọc nhạc: \(e)")
            return
        }
        if o["ready"] != nil { return }
        if let cmd = o["command"] as? String {
            Diag.log("Lệnh \(cmd): \((o["ok"] as? Bool) == true ? "ok" : "không được")")
            return
        }
        let title = o["title"] as? String ?? ""
        guard !title.isEmpty else {
            MediaHub.shared?.setSystem(nil, artwork: nil, artworkChanged: true)
            return
        }
        let num: (String) -> Double = { (o[$0] as? NSNumber)?.doubleValue ?? 0 }
        let np = NowPlaying(
            title: title,
            artist: o["artist"] as? String ?? "",
            album: o["album"] as? String ?? "",
            duration: num("duration"),
            elapsed: num("elapsed"),
            timestamp: Date(timeIntervalSince1970: num("timestamp")),
            rate: num("rate"),
            playing: (o["playing"] as? Bool) ?? (num("rate") > 0),
            pid: Int32(num("pid"))
        )
        var art: NSImage?
        if let b64 = o["artwork"] as? String, let data = Data(base64Encoded: b64) { art = NSImage(data: data) }
        MediaHub.shared?.setSystem(np, artwork: art, artworkChanged: art != nil)
    }
}

// MARK: - Gộp nguồn nhạc

/// macOS chỉ chọn một app "Đang phát". Khi app đó đang dừng mà Apple Music / Spotify vẫn chạy,
/// RinNotch hiện và điều khiển Music / Spotify (hỏi trực tiếp qua AppleScript).
@MainActor
final class MediaHub {
    static var shared: MediaHub?
    private let m: NotchModel
    private var system: NowPlaying?
    private var systemArt: NSImage?
    private var app: NowPlaying?
    private var appArt: NSImage?
    private(set) var appBundle: String?
    private var usingApp = false

    init(model: NotchModel) { m = model }

    func setSystem(_ np: NowPlaying?, artwork: NSImage?, artworkChanged: Bool) {
        if let old = system, let np, old.title != np.title || old.artist != np.artist { systemArt = nil }
        if np == nil { systemArt = nil }
        if artworkChanged, let artwork { systemArt = artwork }
        let wasPlaying = systemIsPlaying
        system = np
        recompute()
        if wasPlaying != systemIsPlaying { AppMusicBridge.shared?.pollSoon() }
    }

    func setApp(_ np: NowPlaying?, bundle: String?, artwork: NSImage?) {
        if let old = app, let np, old.title != np.title || old.artist != np.artist { appArt = nil }
        if np == nil { appArt = nil }
        if let artwork { appArt = artwork }
        app = np
        appBundle = np == nil ? nil : bundle
        recompute()
    }

    func setAppArtwork(_ img: NSImage) {
        appArt = img
        recompute()
    }

    var systemIsPlaying: Bool { system?.playing == true }
    var systemPID: Int32? { system?.pid }
    var showingApp: Bool { usingApp }

    private func recompute() {
        let useApp: Bool
        if let a = app, a.playing, system?.playing != true { useApp = true }
        else if usingApp, let a = app, system?.playing != true, !a.title.isEmpty { useApp = true }
        else { useApp = false }
        usingApp = useApp
        let np = useApp ? app : system
        let art = useApp ? appArt : systemArt
        if m.nowPlaying != np { m.nowPlaying = np }
        if m.artwork !== art { m.artwork = art }
    }

    func command(_ cmd: String) {
        if usingApp, let b = appBundle {
            AppMusicBridge.shared?.command(cmd, bundle: b)
        } else {
            MediaWatcher.shared?.send(cmd)
        }
    }
}

/// Hỏi Apple Music và Spotify đang phát gì (chỉ khi app đó đang mở sẵn, không tự bật app).
@MainActor
final class AppMusicBridge {
    static var shared: AppMusicBridge?
    private var timer: Timer?
    private var busy = false
    private var denied: Set<String> = []
    private var lastKey: String?

    static let apps: [(bundle: String, name: String)] = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]

    private var soonWork: DispatchWorkItem?

    /// Music và Spotify tự báo (DistributedNotificationCenter) khi đổi bài, phát, dừng; mở / tắt app thì NSWorkspace báo.
    /// Có báo mới hỏi bằng AppleScript. Hỏi định kỳ chỉ để dự phòng: 5 giây khi đang hiện bài của app, 20 giây lúc rảnh
    /// (bản cũ chạy osascript mỗi 1,5 giây suốt lúc Music/Spotify mở mà đang dừng).
    init() {
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSoon() }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let bundle, Self.apps.contains(where: { $0.bundle == bundle }) else { return }
                    self?.pollSoon()
                }
            }
        }
        pollSoon()
    }

    func pollSoon() {
        soonWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        soonWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func scheduleFallback() {
        timer?.invalidate()
        let next: TimeInterval = MediaHub.shared?.showingApp == true ? 5 : 20
        let t = Timer(timeInterval: next, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = next * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func running(_ bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    private func poll() {
        scheduleFallback()
        guard !busy, let hub = MediaHub.shared else { return }
        // Chỉ cần hỏi khi app macOS chọn đang dừng, hoặc đang hiện Music/Spotify.
        guard !hub.systemIsPlaying || hub.showingApp else {
            if hub.showingApp == false { hub.setApp(nil, bundle: nil, artwork: nil) }
            return
        }
        let candidates = Self.apps.filter { running($0.bundle) != nil && !denied.contains($0.bundle) }
        // Nếu chính Music/Spotify là app macOS đang chọn thì không cần hỏi thêm.
        let filtered = candidates.filter { running($0.bundle)?.processIdentifier != hub.systemPID }
        guard !filtered.isEmpty else {
            hub.setApp(nil, bundle: nil, artwork: nil)
            return
        }
        busy = true
        query(filtered, index: 0, best: nil)
    }

    private func query(_ list: [(bundle: String, name: String)], index: Int, best: (NowPlaying, String)?) {
        guard index < list.count else {
            busy = false
            finish(best)
            return
        }
        let item = list[index]
        let isSpotify = item.bundle == "com.spotify.client"
        let script = [
            "tell application \"\(item.name)\"",
            "if player state is playing then",
            "set st to \"playing\"",
            "else if player state is paused then",
            "set st to \"paused\"",
            "else",
            "return \"stopped\"",
            "end if",
            "set t to current track",
            "return st & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position",
            "end tell",
        ]
        Self.osa(script) { [weak self] out, err in
            Task { @MainActor in
                guard let self else { return }
                if let err, err.contains("-1743") {
                    self.denied.insert(item.bundle)
                    Diag.log("Chưa có quyền điều khiển \(item.name) (Cài đặt → Quyền riêng tư & Bảo mật → Tự động hoá)")
                }
                var best = best
                if let out {
                    let f = out.components(separatedBy: "\t")
                    if f.count >= 6, f[0] == "playing" || f[0] == "paused" {
                        let numv: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
                        var dur = numv(f[4])
                        if isSpotify { dur /= 1000 }
                        let np = NowPlaying(
                            title: f[1], artist: f[2], album: f[3], duration: dur, elapsed: numv(f[5]),
                            timestamp: Date(), rate: f[0] == "playing" ? 1 : 0, playing: f[0] == "playing",
                            pid: self.running(item.bundle)?.processIdentifier ?? 0
                        )
                        if best == nil || (np.playing && best?.0.playing != true) { best = (np, item.bundle) }
                    }
                }
                self.query(list, index: index + 1, best: best)
            }
        }
    }

    private func finish(_ best: (NowPlaying, String)?) {
        guard let hub = MediaHub.shared else { return }
        guard let (np, bundle) = best else {
            hub.setApp(nil, bundle: nil, artwork: nil)
            return
        }
        let key = "\(bundle)|\(np.title)|\(np.artist)"
        hub.setApp(np, bundle: bundle, artwork: nil)
        if key != lastKey {
            lastKey = key
            fetchArtwork(bundle: bundle, key: key)
        }
    }

    /// Ảnh bìa: Music trả dữ liệu ảnh, Spotify trả đường link ảnh trên máy chủ của Spotify.
    private func fetchArtwork(bundle: String, key: String) {
        let apply: @Sendable (NSImage?) -> Void = { img in
            guard let img else { return }
            Task { @MainActor in
                if self.lastKey == key { MediaHub.shared?.setAppArtwork(img) }
            }
        }
        if bundle == "com.apple.Music" {
            Self.osa(["tell application \"Music\" to get data of artwork 1 of current track"]) { out, _ in
                apply(out.flatMap { Self.imageFromAppleScriptData($0) })
            }
        } else if bundle == "com.spotify.client" {
            Self.osa(["tell application \"Spotify\" to get artwork url of current track"]) { out, _ in
                // Chỉ tải ảnh bìa từ máy chủ ảnh của Spotify (đúng như README ghi).
                guard let out, let url = URL(string: out), url.scheme == "https",
                      let host = url.host?.lowercased(),
                      host == "scdn.co" || host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com") else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    apply(data.flatMap { NSImage(data: $0) })
                }.resume()
            }
        }
    }

    nonisolated static func imageFromAppleScriptData(_ s: String) -> NSImage? {
        // osascript in ra dạng «data XXXXhexhex…»
        guard let start = s.range(of: "«data "), let end = s.range(of: "»", options: .backwards) else { return nil }
        let body = s[start.upperBound..<end.lowerBound]
        guard body.count > 8 else { return nil }
        let hex = body.dropFirst(4)
        var data = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            data.append(byte)
        }
        return NSImage(data: data)
    }

    func command(_ cmd: String, bundle: String) {
        guard let app = Self.apps.first(where: { $0.bundle == bundle }) else { return }
        let action: String
        switch cmd {
        case "toggle": action = "playpause"
        case "next": action = "next track"
        case "prev": action = "previous track"
        case "play": action = "play"
        case "pause": action = "pause"
        default:
            if cmd.hasPrefix("seek "), let v = Double(cmd.dropFirst(5)) {
                action = "set player position to \(String(format: "%.1f", v))"
            } else { return }
        }
        Self.osa(["tell application \"\(app.name)\" to \(action)"]) { _, _ in
            Task { @MainActor in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated { self.poll() }
                }
            }
        }
    }

    nonisolated static func osa(_ lines: [String], completion: @escaping @Sendable (String?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = lines.flatMap { ["-e", $0] }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                completion(nil, error.localizedDescription)
                return
            }
            // Đọc hết trước khi chờ thoát, tránh kẹt khi kết quả lớn (ảnh bìa).
            let od = out.fileHandleForReading.readDataToEndOfFile()
            let ed = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let o = String(data: od, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let e = String(data: ed, encoding: .utf8)
            completion(o?.isEmpty == true ? nil : o, e?.isEmpty == true ? nil : e)
        }
    }
}

// MARK: - Nguồn điện

@MainActor
final class PowerWatcher {
    static var shared: PowerWatcher?
    private let m: NotchModel
    private var onAC: Bool?

    init(model: NotchModel) {
        m = model
        onAC = Self.read().ac
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerWatcher.shared?.update() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    static func read() -> (ac: Bool?, percent: Int) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, 0) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            return (state == kIOPSACPowerValue, pct)
        }
        return (nil, 0)
    }

    private var lastPercent: Int?

    func update() {
        let r = Self.read()
        guard let ac = r.ac else { return }
        defer { onAC = ac; lastPercent = r.percent }
        if let was = onAC, was != ac {
            guard Prefs.showCharging else { return }
            m.showTransient(ac ? .charging(percent: r.percent) : .unplugged(percent: r.percent), seconds: 3)
            return
        }
        if !ac, r.percent <= 10, KeepAwake.shared.active, Prefs.awakeStopLowBattery {
            KeepAwake.shared.stop(.lowBattery)
        }
        // Pin yếu: báo một lần khi xuống tới 20% và 10% lúc đang dùng pin.
        if !ac, Prefs.showLowBattery, let last = lastPercent {
            for mark in [20, 10] where last > mark && r.percent <= mark {
                m.showTransient(.lowBattery(percent: r.percent), seconds: 5)
                NSSound(named: NSSound.Name("Funk"))?.play()
                break
            }
        }
    }
}

// MARK: - Cửa sổ tai thỏ

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    static let expandedWidth: CGFloat = 640
    static let expandedHeight: CGFloat = 246
    let model: NotchModel
    let panel: NotchPanel
    private var geo = NotchGeometry.current()
    private var collapseWork: DispatchWorkItem?
    private var dragCountAtDown = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []
    private let panelSize = CGSize(width: 720, height: 320)
    /// Mở bằng phím tắt: không tự thu khi chuột chưa từng vào tai thỏ.
    private var keyboardOpen = false
    private var mouseVisited = false
    /// Màn hình tai thỏ đang nằm (nil = màn hình mặc định). Đổi khi chuột sang màn hình khác.
    private var activeFrame: CGRect?
    var geometry: NotchGeometry { geo }

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: IslandView(m: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCollapse(force: false) }
        }

        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseUp() }
            return e
        }) { monitors.append(l) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            let handled = MainActor.assumeIsolated { self?.keyDown(e) ?? false }
            return handled ? nil : e
        }) { monitors.append(l) }
    }

    func layout() {
        let screens = NSScreen.screens
        let target = activeFrame.flatMap { f in screens.first { $0.frame == f } }
        if target == nil { activeFrame = nil }
        geo = target.map { NotchGeometry.of($0) } ?? NotchGeometry.current()
        model.hasNotch = geo.hasNotch
        model.notchWidth = geo.width
        model.notchHeight = geo.height
        let f = geo.screenFrame
        panel.setFrame(
            CGRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height, width: panelSize.width, height: panelSize.height),
            display: true
        )
        CopyToast.shared.layout()
    }

    /// Có nhiều màn hình (màn hình rời, iPad làm màn hình phụ): tai thỏ / viên thuốc đi theo màn hình có chuột.
    private func followMouse(_ p: NSPoint) {
        guard Prefs.followMouseScreen, NSScreen.screens.count > 1, !model.expanded, model.transient == nil,
              model.keyboardLockUntil == nil, !geo.screenFrame.contains(p) else { return }
        let screens = NSScreen.screens
        guard let s = screens.first(where: { $0.frame.contains(p) })
                ?? screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(p) }),
              s.frame != geo.screenFrame else { return }
        activeFrame = s.frame
        layout()
    }

    private var notchRect: CGRect {
        let f = geo.screenFrame
        let h = geo.height + geo.topInset
        return CGRect(x: f.midX - geo.width / 2 - 8, y: f.maxY - h - 6, width: geo.width + 16, height: h + 6)
    }

    private var expandedRect: CGRect {
        let f = geo.screenFrame
        let w: CGFloat = NotchController.expandedWidth + 16 + 40
        let h = geo.height + geo.topInset + NotchController.expandedHeight + 30
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    /// Phím bấm khi tai thỏ đang được gõ: Esc thu lại, số 1–8 chuyển mục, ↑ ↓ ↩ chọn trong Bộ nhớ tạm.
    private func keyDown(_ e: NSEvent) -> Bool {
        guard model.expanded, e.window === panel else { return false }
        if e.keyCode == UInt16(kVK_Escape) {
            collapse()
            return true
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let typing = panel.firstResponder is NSTextView
        if mods == .command, e.charactersIgnoringModifiers == "a", model.tab == .shelf, !typing {
            model.shelfSelection = Set(model.visibleShelf)
            return true
        }
        guard mods.isEmpty else { return false }
        // Đang gõ chữ (ghi chú, ô tìm, ô dịch) thì số để tới ô chữ; riêng ô tìm của Bộ nhớ tạm vẫn dùng được ↑ ↓ ↩.
        if !typing, let ch = e.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= Tab.allCases.count {
            model.tab = Tab.allCases[n - 1]
            return true
        }
        if typing && model.tab != .clipboard { return false }
        if model.tab == .clipboard {
            let items = model.visibleClips
            guard !items.isEmpty else { return false }
            let i = items.firstIndex { $0.id == model.clipSelection }
            switch Int(e.keyCode) {
            case kVK_DownArrow, kVK_RightArrow:
                model.clipSelection = items[min((i ?? -1) + 1, items.count - 1)].id
                return true
            case kVK_UpArrow, kVK_LeftArrow:
                model.clipSelection = items[max((i ?? items.count) - 1, 0)].id
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                let item = i.map { items[$0] } ?? items[0]
                ClipboardWatcher.shared?.restore(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    MainActor.assumeIsolated { self?.collapse() }
                }
                return true
            default: break
            }
        }
        return false
    }

    private func mouseMoved() {
        CopyToast.shared.mouseMoved(NSEvent.mouseLocation)
        guard !model.hidden, model.keyboardLockUntil == nil else { return }
        let p = NSEvent.mouseLocation
        followMouse(p)
        if !model.expanded {
            guard notchRect.contains(p) else { return }
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            if pressed {
                // Đang kéo file từ nơi khác lên tai thỏ → mở kệ file (cách mở nào cũng được).
                if NSPasteboard(name: .drag).changeCount != dragCountAtDown {
                    expand(tab: .shelf)
                }
            } else if Prefs.openMode != .hotkey {
                expand(tab: nil)
            }
        } else if keyboardOpen {
            // Mở bằng phím: chuột vào rồi ra mới tự thu, chuột chưa vào thì giữ nguyên.
            if expandedRect.contains(p) {
                mouseVisited = true
                collapseWork?.cancel()
            } else if mouseVisited {
                scheduleCollapse(force: false)
            }
        } else {
            if expandedRect.contains(p) {
                collapseWork?.cancel()
            } else {
                scheduleCollapse(force: false)
            }
        }
    }

    private func mouseDown() {
        dragCountAtDown = NSPasteboard(name: .drag).changeCount
        if model.expanded && !expandedRect.contains(NSEvent.mouseLocation) {
            collapse()
        }
    }

    private func mouseUp() {
        // Phòng khi thao tác kéo khung bị huỷ mà SwiftUI không báo kết thúc.
        model.marqueeActive = false
        if model.draggingOut {
            model.draggingOut = false
            if !expandedRect.contains(NSEvent.mouseLocation) { scheduleCollapse(force: false) }
        }
    }

    func expand(tab: Tab?, byKeyboard: Bool = false) {
        guard model.keyboardLockUntil == nil else { return }
        collapseWork?.cancel()
        if let tab {
            model.tab = tab
        } else if !model.expanded && model.transient == nil && model.recording == nil {
            // Đang hiện dạng gọn của hẹn giờ hoặc nhạc thì mở thẳng mục đó, không thì theo Cài đặt.
            if model.timerCompact { model.tab = .timer }
            else if model.musicCompact { model.tab = .media }
            else if let t = Tab(rawValue: Prefs.defaultTab) { model.tab = t }
        }
        if byKeyboard {
            if !model.expanded || !keyboardOpen { mouseVisited = expandedRect.contains(NSEvent.mouseLocation) }
            keyboardOpen = true
            model.clipSelection = nil
            // Nhận phím ngay (gõ ghi chú, số chuyển mục) mà không giành focus của app đang dùng.
            panel.makeKey()
            // SwiftUI có thể tự đặt con trỏ vào ô chữ đầu tiên (ô tìm): bỏ ra để bấm số chuyển mục được.
            if model.tab != .notes {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.model.tab != .notes, self.panel.firstResponder is NSTextView else { return }
                        _ = self.panel.makeFirstResponder(nil)
                    }
                }
            }
        }
        guard !model.expanded else { return }
        CopyToast.shared.hide()
        model.expanded = true
        panel.ignoresMouseEvents = false
    }

    /// Tắt "đi theo chuột": đưa tai thỏ về màn hình mặc định.
    func resetScreen() {
        activeFrame = nil
        layout()
    }

    /// Khoá / mở khoá bàn phím: banner cần nhận chuột để bấm Mở khoá.
    func lockChanged() {
        panel.ignoresMouseEvents = !(model.expanded || model.keyboardLockUntil != nil)
    }

    func scheduleCollapse(force: Bool) {
        guard model.expanded else { return }
        if !force {
            if model.draggingOut || model.marqueeActive { return }
            // Đang gõ chữ thì không tự thu lại, bấm ra ngoài hoặc Esc mới thu.
            let typing = panel.isKeyWindow && panel.firstResponder is NSTextView
            if typing && expandedRect.contains(NSEvent.mouseLocation) { return }
            if panel.isKeyWindow && model.tab == .notes && !model.noteDraft.isEmpty { return }
        }
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !force && self.expandedRect.contains(NSEvent.mouseLocation) { return }
                self.collapse()
            }
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func collapse() {
        collapseWork?.cancel()
        keyboardOpen = false
        mouseVisited = false
        guard model.expanded else { return }
        model.expanded = false
        model.dropTargeted = false
        model.clipSelection = nil
        model.shelfSelection = []
        model.shelfAnchor = nil
        model.marqueeActive = false
        panel.ignoresMouseEvents = model.keyboardLockUntil == nil
        if panel.isKeyWindow {
            _ = panel.makeFirstResponder(nil)
            // Trả phím về app đang dùng: ẩn rồi hiện lại panel là cách chắc chắn để panel thôi nhận phím
            // (gọi activate() cho app đang đứng trước có thể bị macOS bỏ qua).
            panel.orderOut(nil)
            if !model.hidden { panel.orderFrontRegardless() }
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    func setHidden(_ hidden: Bool) {
        model.hidden = hidden
        if hidden {
            collapse()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
}

// MARK: - Ngôn ngữ (theo ngôn ngữ của máy)

func L(_ vi: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? vi : en
}

// MARK: - Cài đặt

enum UpdateFrequency: String, CaseIterable {
    case daily, weekly, off
    var title: String {
        switch self {
        case .daily: return L("Mỗi ngày", "Daily")
        case .weekly: return L("Mỗi tuần", "Weekly")
        case .off: return L("Tắt", "Off")
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .daily: return 20 * 3600
        case .weekly: return 6.5 * 24 * 3600
        case .off: return nil
        }
    }
}

enum UpdateMode: String, CaseIterable {
    case auto, ask, notify
    var shortTitle: String {
        switch self {
        case .auto: return L("Tự cập nhật", "Auto")
        case .ask: return L("Hỏi trước", "Ask")
        case .notify: return L("Chỉ báo", "Notify")
        }
    }
}

enum OpenMode: String, CaseIterable {
    case hover, hotkey, both
    var title: String {
        switch self {
        case .hover: return L("Rê chuột", "Hover")
        case .hotkey: return L("Phím tắt", "Shortcut")
        case .both: return L("Cả hai", "Both")
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    private static func bool(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }

    static var openMode: OpenMode { OpenMode(rawValue: d.string(forKey: "openMode") ?? "") ?? .both }
    static var showAwake: Bool { bool("showAwake") }
    static var showNetwork: Bool { bool("showNetwork") }
    static var showCopyToast: Bool { bool("showCopyToast") }
    static var showDownloads: Bool { bool("showDownloads") }
    static var stackDoubleControl: Bool { bool("stackDoubleControl") }
    static var showIdlePill: Bool { bool("showIdlePill") }
    static var followMouseScreen: Bool { bool("followMouseScreen") }
    static var awakeStopLowBattery: Bool { bool("awakeStopLowBattery") }
    static var awakeStopOnSleep: Bool { bool("awakeStopOnSleep") }
    static var clipLimit: Int { max(d.object(forKey: "clipLimit") as? Int ?? 50, 10) }
    /// Xem trước liên kết phải hỏi trang web: mặc định tắt, ai cần thì bật.
    static var linkPreview: Bool { d.object(forKey: "linkPreview") as? Bool ?? false }
    static var clipExcluded: [String] {
        get { d.stringArray(forKey: "clipExcluded") ?? [] }
        set { d.set(newValue, forKey: "clipExcluded") }
    }

    static var showMusic: Bool { bool("showMusic") }
    static var showTimer: Bool { bool("showTimer") }
    static var showRecording: Bool { bool("showRecording") }
    static var showHeadphones: Bool { bool("showHeadphones") }
    static var showCharging: Bool { bool("showCharging") }
    static var showLowBattery: Bool { bool("showLowBattery") }
    /// "last" = mục dùng gần nhất, hoặc tên một mục (Tab.rawValue).
    static var defaultTab: String { d.string(forKey: "defaultTab") ?? "last" }

    static var updateFrequency: UpdateFrequency {
        get { UpdateFrequency(rawValue: d.string(forKey: "updateFrequency") ?? "") ?? .daily }
        set { d.set(newValue.rawValue, forKey: "updateFrequency") }
    }
    static var updateMode: UpdateMode {
        get { UpdateMode(rawValue: d.string(forKey: "updateMode") ?? "") ?? .ask }
        set { d.set(newValue.rawValue, forKey: "updateMode") }
    }
    static var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }
    static var justUpdatedFrom: String? {
        get { d.string(forKey: "justUpdatedFrom") }
        set { d.set(newValue, forKey: "justUpdatedFrom") }
    }
}

// MARK: - Thông tin app

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static let repoURL = URL(string: "https://github.com/PhuocRin/RinNotch")!
    static let apiLatestRelease = URL(string: "https://api.github.com/repos/PhuocRin/RinNotch/releases/latest")!
    static let webURL = URL(string: "https://phuocrin.com/rinnotch/")!
    static let youtubeURL = URL(string: "https://youtube.com/@phuocrin")!
    static let tiktokURL = URL(string: "https://www.tiktok.com/@phuocrinrin")!
    static let facebookURL = URL(string: "https://www.facebook.com/phuocrinrin")!
    static let email = "phuocrinrin@gmail.com"

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func permission(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return L("có", "yes")
        case .denied, .restricted: return L("bị từ chối", "denied")
        default: return L("chưa hỏi", "not asked")
        }
    }

    /// Thông tin gửi kèm khi báo lỗi. Không có gì cá nhân.
    @MainActor
    static var diagnostics: String {
        "RinNotch \(version) (\(build)) · \(macOS) · \(chip)\n"
            + L("Quyền micro", "Microphone") + ": " + permission(AVCaptureDevice.authorizationStatus(for: .audio))
            + " · " + L("Ký bằng chứng chỉ", "Certificate signed") + ": " + (UpdateSecurity.currentIsAdHoc ? L("không", "no") : L("có", "yes"))
    }
}

// MARK: - Giao diện dùng chung (cửa sổ phụ)

extension View {
    func panelStyle(width: CGFloat = 340) -> some View {
        self.padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 26).frame(width: width)
    }

    func softCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }

    func noteText() -> some View {
        self.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GlassButton: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct AppIconView: View {
    var size: CGFloat = 88
    @ViewBuilder
    var body: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
                .shadow(color: Color.black.opacity(0.25), radius: 14, y: 6)
        }
    }
}

@MainActor
final class Panel {
    private var window: NSWindow?
    private var resignObserver: NSObjectProtocol?
    private let content: () -> AnyView

    init(_ content: @escaping () -> AnyView) { self.content = content }

    /// attention = app tự mở (có bản mới, vừa cập nhật, mẹo lần đầu): từ macOS 14, app trên thanh menu
    /// không được tự giành quyền lên trước nên cửa sổ dễ bị kẹt sau app đang dùng. Lúc đó cho cửa sổ nổi
    /// trên cùng ở đúng màn hình đang dùng, tới khi người dùng bấm vào rồi chuyển đi nơi khác.
    func show(attention: Bool = false) {
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = .preferredContentSize
        if let w = window {
            w.contentViewController = controller
        } else {
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.collectionBehavior.insert(.moveToActiveSpace)
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated { w?.level = .normal }
            }
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        w.level = attention ? .floating : .normal
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}

// MARK: - Cài đặt (cửa sổ)

struct SettingsView: View {
    @AppStorage("showMusic") private var showMusic = true
    @AppStorage("showTimer") private var showTimer = true
    @AppStorage("showRecording") private var showRecording = true
    @AppStorage("showAwake") private var showAwake = true
    @AppStorage("showHeadphones") private var showHeadphones = true
    @AppStorage("showCharging") private var showCharging = true
    @AppStorage("showLowBattery") private var showLowBattery = true
    @AppStorage("showNetwork") private var showNetwork = true
    @AppStorage("showCopyToast") private var showCopyToast = true
    @AppStorage("showDownloads") private var showDownloads = true
    @AppStorage("stackDoubleControl") private var stackDoubleControl = true
    @AppStorage("showIdlePill") private var showIdlePill = true
    @AppStorage("followMouseScreen") private var followMouseScreen = true
    @AppStorage("defaultTab") private var defaultTab = "last"
    @AppStorage("openMode") private var openMode = OpenMode.both.rawValue
    @AppStorage("clipLimit") private var clipLimit = 50
    @AppStorage("linkPreview") private var linkPreview = false
    @AppStorage("awakeStopLowBattery") private var awakeStopLowBattery = true
    @AppStorage("awakeStopOnSleep") private var awakeStopOnSleep = true
    @State private var excluded = Prefs.clipExcluded
    @State private var backupNote: String?
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                AppIconView(size: 64)
                Text(L("Cài đặt RinNotch", "RinNotch Settings"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                section(L("Cách mở tai thỏ", "How to open the notch")) {
                    Picker("", selection: $openMode) {
                        ForEach(OpenMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: openMode) { HotkeyCenter.registerAll() }
                    Text(openModeNote).noteText()
                    if openMode != OpenMode.hotkey.rawValue {
                        HStack {
                            Text(L("Rê chuột lên tai thỏ thì mở", "On hover, open")).font(.system(size: 13))
                            Spacer()
                            Picker("", selection: $defaultTab) {
                                Text(L("Mục dùng gần nhất", "Last used")).tag("last")
                                ForEach(Tab.allCases) { t in Text(t.title).tag(t.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }
                    }
                }

                section(L("Nhiều màn hình, màn hình không tai thỏ", "Displays without a notch")) {
                    Toggle(L("Đi theo màn hình có chuột (màn hình rời, iPad làm màn hình phụ)", "Follow the display with the pointer"), isOn: $followMouseScreen)
                        .onChange(of: followMouseScreen) { AppDelegate.shared?.controller.resetScreen() }
                    Toggle(L("Hiện viên thuốc nhỏ lúc rảnh trên màn hình không tai thỏ", "Show a small pill when idle on displays without a notch"), isOn: $showIdlePill)
                    Text(L("Màn hình không có tai thỏ thì RinNotch hiện dạng viên thuốc nổi giữa thanh menu: rê chuột vào để mở, đủ các mục như trên MacBook. Tắt viên thuốc lúc rảnh thì rê chuột lên giữa mép trên màn hình vẫn mở được.",
                           "On displays without a notch, RinNotch shows as a floating pill in the middle of the menu bar: hover to open, with every section. With the idle pill off, hovering the middle of the top edge still opens it."))
                        .noteText()
                }

                section(L("Phím tắt", "Shortcuts")) {
                    ForEach(HotAction.allCases) { a in
                        HStack(alignment: .top) {
                            Text(a.title).font(.system(size: 13)).padding(.top, 4)
                            Spacer()
                            KeyRecorder(action: a)
                        }
                    }
                    Text(L("Bấm vào ô rồi nhấn tổ hợp mới. ⌫ để tắt phím đó, Esc để huỷ. Tai thỏ đang mở thì bấm số 1–9 để chuyển mục, Esc để thu lại.",
                           "Click a box, then press the new keys. ⌫ turns it off, Esc cancels. While the notch is open, press 1–9 to switch sections and Esc to close."))
                        .noteText()
                }

                section(L("Hiện ở hai bên tai thỏ", "Show beside the notch")) {
                    Toggle(L("Nhạc / video đang phát", "Now playing"), isOn: $showMusic)
                    Toggle(L("Hẹn giờ đang chạy", "Running timer"), isOn: $showTimer)
                    Toggle(L("App đang ghi âm (sóng âm)", "Apps recording audio"), isOn: $showRecording)
                    Toggle(L("Đang giữ máy thức", "Keep awake"), isOn: $showAwake)
                    Toggle(L("Tiến trình tải về (Safari, Chrome, AirDrop…)", "Download progress (Safari, Chrome, AirDrop…)"), isOn: $showDownloads)
                        .onChange(of: showDownloads) { DownloadWatcher.shared.refresh() }
                }

                section(L("Thông báo thả xuống", "Drop-down alerts")) {
                    Toggle(L("Tai nghe kết nối", "Headphones connected"), isOn: $showHeadphones)
                    Toggle(L("Cắm và rút sạc", "Charger plugged / unplugged"), isOn: $showCharging)
                    Toggle(L("Pin yếu 20% và 10%", "Low battery 20% and 10%"), isOn: $showLowBattery)
                    Toggle(L("Mất mạng và có mạng lại", "Internet lost / back"), isOn: $showNetwork)
                    Toggle(L("\"Đã chép\" dưới tai thỏ mỗi lần copy", "\"Copied\" below the notch on every copy"), isOn: $showCopyToast)
                }

                section(L("Bộ nhớ tạm", "Clipboard")) {
                    Toggle(L("Nhấn ⌃ hai lần để bật / tắt Copy liên tục", "Press ⌃ twice to toggle Paste Stack"), isOn: $stackDoubleControl)
                        .onChange(of: stackDoubleControl) { PasteStack.shared.refresh() }
                    Text(L("Copy liên tục: copy nhiều thứ liên tiếp, rồi mỗi lần ⌘V dán lần lượt từng thứ theo đúng thứ tự. Dán hết là tự tắt. Cần quyền Trợ năng. Cũng bật được bằng nút chồng giấy trong mục Bộ nhớ tạm.",
                           "Paste Stack: copy several things, then each ⌘V pastes them one by one in order. It turns off after the last one. Needs Accessibility. Also available from the stack button in Clipboard."))
                        .noteText()
                    HStack {
                        Text(L("Giữ lại", "Keep")).font(.system(size: 13))
                        Spacer()
                        Picker("", selection: $clipLimit) {
                            ForEach([20, 50, 100, 200], id: \.self) { n in Text(L("\(n) mục gần nhất", "Last \(n) items")).tag(n) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    Toggle(L("Xem trước tên trang của liên kết", "Show link titles"), isOn: $linkPreview)
                    Text(L("Bật thì RinNotch mở trang của liên kết vừa chép để lấy tên trang. Link có mã riêng (đăng nhập, đặt lại mật khẩu, huỷ đăng ký…) được bỏ qua. Lịch sử chỉ nằm trong máy, thoát app là xoá; mục đã ghim thì được giữ lại.",
                           "When on, RinNotch loads copied links to read the page title. Links with tokens (login, password reset, unsubscribe…) are skipped. History stays on this Mac and clears when you quit; pinned items are kept."))
                        .noteText()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("Không ghi khi copy từ app", "Ignore copies from")).font(.system(size: 13))
                            Spacer()
                            Button(L("Thêm app…", "Add app…")) { addExcluded() }.glassButton()
                        }
                        if excluded.isEmpty {
                            Text(L("Chưa có app nào. Mật khẩu copy từ trình quản lý mật khẩu luôn được bỏ qua.",
                                   "None yet. Passwords copied from password managers are always ignored."))
                                .noteText()
                        }
                        ForEach(excluded, id: \.self) { id in
                            HStack(spacing: 8) {
                                if let icon = AppIcons.icon(id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                Text(appName(id)).font(.system(size: 12))
                                Spacer()
                                Button {
                                    excluded.removeAll { $0 == id }
                                    Prefs.clipExcluded = excluded
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        Button(L("Xuất bản sao lưu…", "Export backup…")) {
                            if let m = AppDelegate.shared?.model { ClipStore.exportBackup(m) }
                        }
                        .glassButton()
                        Button(L("Nhập…", "Import…")) {
                            if let m = AppDelegate.shared?.model {
                                if let n = ClipStore.importBackup(m) { backupNote = L("Đã thêm \(n) mục", "Added \(n) items") }
                                else { backupNote = nil }
                            }
                        }
                        .glassButton()
                        if let backupNote { Text(backupNote).font(.system(size: 11)).foregroundStyle(.green) }
                    }
                }

                section(L("Giữ máy thức", "Keep awake")) {
                    Toggle(L("Tự tắt khi pin dưới 10%", "Turn off below 10% battery"), isOn: $awakeStopLowBattery)
                    Toggle(L("Tự tắt khi máy ngủ hoặc gập máy", "Turn off when the Mac sleeps"), isOn: $awakeStopOnSleep)
                }

                section(L("Chung", "General")) {
                    Toggle(L("Mở cùng máy", "Open at login"), isOn: $login)
                        .onChange(of: login) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                login = SMAppService.mainApp.status == .enabled
                            }
                            AppDelegate.shared?.rebuildMenu()
                        }
                }
            }
            .panelStyle(width: 460)
        }
        .frame(width: 460, height: 640)
    }

    private var openModeNote: String {
        switch OpenMode(rawValue: openMode) ?? .both {
        case .hover: return L("Rê chuột lên tai thỏ là mở. Phím mở từng mục đang tắt (Ẩn / hiện và Dịch nhanh vẫn dùng được).",
                              "Hover opens the notch. Section shortcuts are off (Hide / show and Translate still work).")
        case .hotkey: return L("Rê chuột lên tai thỏ không mở nữa, chỉ mở bằng phím tắt. Kéo file thả lên tai thỏ vẫn mở Kệ file.",
                               "Hovering no longer opens the notch, only shortcuts do. Dropping a file still opens the shelf.")
        case .both: return L("Rê chuột hay bấm phím tắt đều mở được.", "Hover or shortcuts both open the notch.")
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .toggleStyle(.switch)
        .font(.system(size: 13))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(cornerRadius: 16)
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addExcluded() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            if let id = Bundle(url: u)?.bundleIdentifier, !excluded.contains(id) { excluded.append(id) }
        }
        Prefs.clipExcluded = excluded
    }
}

// MARK: - Ủng hộ tác giả

enum Support {
    static let paypalURL = URL(string: "https://paypal.me/phuocrin")!
    static var qrImage: NSImage? { Bundle.main.image(forResource: "donate-qr") }
}

struct SupportView: View {
    private let qr = Support.qrImage

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.pink)
            Text(L("Ủng hộ tác giả", "Support the author")).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(qr != nil
                 ? L("RinNotch miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin bằng 1 trong 2 cách bên dưới.",
                     "RinNotch is free. If it helps you, you can support Phước Rin in one of the two ways below.")
                 : L("RinNotch miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin qua PayPal.",
                     "RinNotch is free. If it helps you, you can support Phước Rin via PayPal."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qr {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Cách 1 · Chuyển khoản ngân hàng", "Option 1 · Bank transfer (Vietnam)"), systemImage: "building.columns.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Dành cho bạn ở Việt Nam. Mở app ngân hàng bất kỳ, quét mã này.",
                           "For users in Vietnam. Open any banking app and scan this code.")).noteText()
                    Image(nsImage: qr).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 176, height: 176).padding(10)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                    Text(L("App ngân hàng sẽ hiện tên chủ tài khoản, bạn kiểm tra đúng tên trước khi chuyển nha.",
                           "Your banking app will show the account holder's name. Please check it before sending.")).noteText()
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(qr != nil ? L("Cách 2 · PayPal", "Option 2 · PayPal") : "PayPal", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Dành cho bạn ở nước ngoài hoặc có tài khoản PayPal.",
                       "For users outside Vietnam, or anyone with a PayPal account.")).noteText()
                Button {
                    NSWorkspace.shared.open(Support.paypalURL)
                } label: {
                    Label(L("Ủng hộ qua PayPal", "Support via PayPal"), systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .glassButton(prominent: true).controlSize(.large)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()

            Text(L("Cảm ơn bạn đã dùng RinNotch 💙", "Thanks for using RinNotch 💙")).noteText()
        }
        .panelStyle(width: 360)
    }
}

// MARK: - Mẹo dùng

enum TipTopic: String, CaseIterable, Identifiable {
    case start, media, shelf, clipboard, notes, timer, system, tools, translate, windows, alerts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return L("Bắt đầu", "Basics")
        case .media: return L("Nhạc", "Music")
        case .shelf: return L("Kệ file", "File shelf")
        case .clipboard: return L("Bộ nhớ tạm", "Clipboard")
        case .notes: return L("Ghi chú", "Notes")
        case .timer: return L("Hẹn giờ", "Timer")
        case .system: return L("Hệ thống", "System")
        case .tools: return L("Công cụ", "Tools")
        case .translate: return L("Dịch", "Translate")
        case .windows: return L("Cửa sổ", "Windows")
        case .alerts: return L("Thông báo", "Alerts")
        }
    }

    var symbol: String {
        switch self {
        case .start: return "sparkles"
        case .media: return Tab.media.symbol
        case .shelf: return Tab.shelf.symbol
        case .clipboard: return Tab.clipboard.symbol
        case .notes: return Tab.notes.symbol
        case .timer: return Tab.timer.symbol
        case .system: return Tab.system.symbol
        case .tools: return Tab.tools.symbol
        case .translate: return Tab.translate.symbol
        case .windows: return Tab.windows.symbol
        case .alerts: return "bell.badge"
        }
    }

    init(tab: Tab) {
        switch tab {
        case .media: self = .media
        case .shelf: self = .shelf
        case .clipboard: self = .clipboard
        case .notes: self = .notes
        case .timer: self = .timer
        case .system: self = .system
        case .tools: self = .tools
        case .translate: self = .translate
        case .windows: self = .windows
        }
    }

    /// Mỗi mẹo: biểu tượng + một câu ngắn.
    var tips: [(String, String)] {
        switch self {
        case .start: return [
            ("cursorarrow.rays", L("Rê chuột lên tai thỏ để mở, rê ra ngoài là tự thu lại. Máy không có tai thỏ thì rê lên giữa cạnh trên màn hình.",
                                  "Hover over the notch to open it, move away to close. On Macs without a notch, hover the middle of the top edge.")),
            ("display.2", L("Màn hình không tai thỏ (màn hình rời, iPad làm màn hình phụ): RinNotch hiện viên thuốc giữa thanh menu, rê chuột vào để mở. Có nhiều màn hình thì nó đi theo màn hình có chuột.",
                           "Displays without a notch (external monitor, iPad as a display): RinNotch shows a pill in the middle of the menu bar; hover to open. With several displays it follows the pointer.")),
            ("tray.and.arrow.down", L("Kéo file thả lên tai thỏ là mở ngay Kệ file.",
                                     "Drop a file on the notch to open the file shelf.")),
            ("keyboard", L("⌃⇧1 → ⌃⇧9 mở thẳng từng mục (8 là Dịch nhanh, 9 là Cửa sổ), bấm lại đúng phím đó để đóng. Đang mở thì bấm số 1–9 để chuyển mục. ⌃⇧0 mở bảng lớn.",
                          "⌃⇧1 → ⌃⇧9 open each section (8 is Translate, 9 is Windows); press it again to close. While open, press 1–9 to switch. ⌃⇧0 opens the big board.")),
            ("hand.point.up.left", L("Cài đặt → Cách mở tai thỏ: Rê chuột, Phím tắt hoặc Cả hai. Đổi từng phím tắt cũng ở đó.",
                                    "Settings → How to open: Hover, Shortcut or Both. You can change each shortcut there too.")),
            ("eye.slash", L("⌥⌘N để ẩn / hiện RinNotch. Esc để thu tai thỏ lại.",
                           "⌥⌘N hides / shows RinNotch. Esc closes the notch.")),
            ("menubar.rectangle", L("Biểu tượng RinNotch trên thanh menu: Cài đặt, Mở mục, Kiểm tra cập nhật, Báo lỗi.",
                                   "The RinNotch menu bar icon has Settings, Open, Check for Updates and Report a Bug.")),
            ("questionmark.circle", L("Bánh răng trên tai thỏ mở Cài đặt. Nút ? mở mẹo của mục đang xem. Trái tim là Ủng hộ tác giả.",
                                     "The gear in the notch opens Settings. The ? button opens tips for the current section. The heart is Support the author.")),
        ]
        case .media: return [
            ("play.circle", L("Hiện bài hoặc video đang phát của app bất kỳ: Apple Music, Spotify, YouTube trên trình duyệt…",
                             "Shows what's playing in any app: Apple Music, Spotify, YouTube in a browser…")),
            ("forward.end", L("Bấm phát / dừng, bài trước / sau. Bấm vào thanh thời lượng để tua tới chỗ đó.",
                             "Play / pause, previous / next. Click the progress bar to jump to that point.")),
            ("rectangle.split.3x1", L("Đang phát thì tai thỏ hiện gọn hai bên, không cần mở ra. Tắt trong Cài đặt nếu không thích.",
                                     "While playing, the notch shows a compact view on both sides. Turn it off in Settings.")),
            ("arrow.triangle.2.circlepath", L("macOS chỉ chọn một app \"Đang phát\". App đó dừng mà Music hoặc Spotify đang phát thì RinNotch tự chuyển qua.",
                                             "macOS picks one \"Now Playing\" app. If it pauses while Music or Spotify plays, RinNotch switches over.")),
            ("lock.shield", L("Lần đầu macOS có thể hỏi quyền điều khiển Music / Spotify, bấm Cho phép.",
                             "macOS may ask to let RinNotch control Music / Spotify the first time. Click Allow.")),
        ]
        case .shelf: return [
            ("tray.and.arrow.down", L("Thả file lên tai thỏ để giữ tạm. App chỉ nhớ vị trí file, không sao chép thêm bản nào.",
                                     "Drop files on the notch to keep them handy. Only the location is saved, no extra copy is made.")),
            ("doc.on.doc", L("Kéo file ra = sao chép. Giữ ⌘ rồi mới kéo = chuyển file, chuyển xong file tự rời kệ.",
                            "Drag a file out to copy it. Hold ⌘ before dragging to move it; moved files leave the shelf.")),
            ("rectangle.dashed", L("Kéo chuột trên chỗ trống để chọn nhiều file, rồi kéo cả nhóm ra cùng lúc.",
                                  "Drag a box over empty space to select several files, then drag them out together.")),
            ("command", L("⌘ + bấm để chọn thêm hoặc bỏ một file, ⇧ + bấm để chọn liền một dãy. Bấm chỗ trống để bỏ chọn.",
                         "⌘-click adds or removes a file, ⇧-click selects a range. Click empty space to deselect.")),
            ("cursorarrow.click.2", L("Bấm đúp để mở. Chuột phải: Mở, AirDrop, Sao chép, Hiện trong Finder, Chọn tất cả, Bỏ khỏi kệ.",
                                     "Double-click to open. Right-click: Open, AirDrop, Copy, Show in Finder, Select All, Remove.")),
            ("square.and.arrow.up", L("Nút AirDrop, Sao chép, Xử lý làm trên file đang chọn, chưa chọn file nào thì làm cả kệ.",
                              "AirDrop, Copy and Process use the selection, or the whole shelf when nothing is selected.")),
            ("square.grid.2x2", L("File hiện thành thẻ có ảnh xem trước. Lọc theo Ảnh, Video, PDF, Tài liệu, Thư mục ở hàng trên. Nút ⤢ (hoặc ⌃⇧0) mở bảng lớn chứa hết.",
                                 "Files show as preview cards. Filter by Images, Videos, PDFs, Documents, Folders. The ⤢ button (or ⌃⇧0) opens the big board.")),
            ("pencil", L("Chuột phải một file → Đổi tên file… để đổi tên ngay (đổi luôn file gốc trong Finder).",
                        "Right-click a file → Rename File… (renames the original in Finder).")),
            ("wand.and.stars", L("Xử lý: đổi ảnh sang JPG / PNG / HEIC, nén ảnh, thu nhỏ, xoá nền, gộp PDF, nén ZIP. File mới nằm cạnh file gốc, file gốc giữ nguyên.",
                                "Process: convert images to JPG / PNG / HEIC, compress, resize, remove background, merge into a PDF, ZIP. New files sit next to the originals.")),
        ]
        case .clipboard: return [
            ("doc.on.clipboard", L("Thứ bạn copy hiện thành thẻ: ảnh, mã màu, code, link nhìn là biết. Bấm thẻ để chép lại. Mở bằng ⌃⇧3 thì dùng ← → và ↩.",
                                  "What you copy shows as cards: images, colors, code and links at a glance. Click a card to copy it again. Opened with ⌃⇧3, use ← → and ↩.")),
            ("checkmark.circle", L("Mỗi lần copy, viên \"Đã chép\" hiện dưới tai thỏ. Rê chuột vào để Ghim, Dịch hoặc Xoá ngay. Tắt trong Cài đặt nếu thấy rối.",
                                  "Each copy shows a \"Copied\" pill below the notch. Hover it to Pin, Translate or Delete. Turn it off in Settings.")),
            ("magnifyingglass", L("Gõ để tìm, không cần dấu. Hàng nút trên lọc theo loại (Link, Code, Ảnh, Màu…) và theo app đã copy (icon app). Gõ @safari cũng lọc theo app.",
                                 "Type to search. The chips filter by type (Link, Code, Image, Color…) and by the app you copied from. Typing @safari works too.")),
            ("arrow.up.left.and.arrow.down.right", L("Nút ⤢ hoặc ⌃⇧0 mở bảng lớn: một cửa sổ chứa hết Bộ nhớ tạm và Kệ file, chỉnh được cỡ.",
                                                    "The ⤢ button or ⌃⇧0 opens the big board: a resizable window with all your clipboard items and shelf files.")),
            ("tag", L("Chuột phải → Đặt tên để đặt tên cho một mục; tên hiện dưới thẻ và tìm được.",
                     "Right-click → Name to label an item; the name shows on the card and is searchable.")),
            ("pin", L("Bấm ghim để giữ lại lâu dài, xem ở Đã ghim. Mục đã ghim còn nguyên khi tắt app.",
                     "Pin items to keep them; see them under Pinned. Pinned items survive quitting.")),
            ("contextualmenu.and.cursorarrow", L("Chuột phải: sửa nhanh chữ (viết hoa, bỏ dấu, bỏ dòng trống…), chép mã màu dạng HEX / RGB / HSL, mở liên kết, dịch.",
                                                "Right-click: quick text fixes (case, remove accents, blank lines…), copy colors as HEX / RGB / HSL, open links, translate.")),
            ("square.stack.3d.up", L("Copy liên tục: nhấn ⌃ hai lần (hoặc nút chồng giấy), copy nhiều thứ, rồi mỗi lần ⌘V dán lần lượt từng thứ. Nhấn ⌃ hai lần nữa để tắt; dán hết là tự tắt.",
                                    "Paste Stack: press ⌃ twice (or the stack button), copy several things, then each ⌘V pastes the next one in order. Press ⌃ twice again to stop; it stops by itself after the last one.")),
            ("lock", L("Mật khẩu copy từ trình quản lý mật khẩu không được lưu. Thêm app không muốn ghi trong Cài đặt.",
                      "Passwords from password managers are never saved. Add apps to ignore in Settings.")),
        ]
        case .notes: return [
            ("return", L("Enter để xuống dòng như bình thường.", "Enter adds a new line.")),
            ("command", L("⌘ Enter hoặc nút Lưu vào Notes để lưu vào app Ghi chú, thư mục RinNotch.",
                         "⌘ Enter or Save to Notes saves it to the Notes app, in a RinNotch folder.")),
            ("lock.shield", L("Lần đầu macOS hỏi quyền cho RinNotch dùng Ghi chú, bấm Cho phép.",
                             "macOS asks to let RinNotch use Notes the first time. Click Allow.")),
            ("arrow.up.left.and.arrow.down.right", L("⌘C, ⌘V, ⌘A, ⌘Z dùng được trong ô gõ. Nút ⤢ mở ô ghi chú cỡ lớn trong bảng lớn.",
                                                    "⌘C, ⌘V, ⌘A, ⌘Z work while typing. The ⤢ button opens a big notes editor in the big board.")),
            ("pin", L("Đang gõ thì tai thỏ không tự thu lại. Bấm ra ngoài hoặc Esc để đóng.",
                     "The notch stays open while you type. Click outside or press Esc to close.")),
        ]
        case .timer: return [
            ("stopwatch", L("Bấm giờ chạy từ 00:00:00, hoặc Đếm ngược với các mốc có sẵn.",
                           "Stopwatch counts up from 00:00:00, or pick a countdown preset.")),
            ("rectangle.split.3x1", L("Đang chạy thì thời gian hiện gọn hai bên tai thỏ.",
                                     "While running, the time shows beside the notch.")),
            ("bell", L("Hết giờ đếm ngược thì có thông báo thả xuống kèm tiếng chuông.",
                      "When a countdown ends, an alert drops down with a chime.")),
        ]
        case .tools: return [
            ("eyedropper.halffull", L("Lấy mã màu: bấm rồi chọn điểm bất kỳ trên màn hình, mã HEX được chép ngay.",
                                     "Pick color: click, then choose any point on screen; the HEX code is copied.")),
            ("cup.and.saucer", L("Giữ máy thức 15 phút tới 4 giờ, hoặc tới khi tắt. Tự tắt khi pin dưới 10% hoặc khi gập máy (đổi trong Cài đặt).",
                                "Keep awake for 15 minutes to 4 hours, or until turned off. Stops below 10% battery or when the Mac sleeps.")),
            ("keyboard", L("Lau bàn phím: khoá mọi phím 2 phút. Bấm Esc 5 lần hoặc nút Mở khoá để mở sớm. Cần quyền Trợ năng.",
                          "Clean keyboard: locks all keys for 2 minutes. Press Esc 5 times or Unlock to end early. Needs Accessibility.")),
            ("exclamationmark.triangle", L("Nút nguồn / Touch ID không khoá được, đừng ấn mạnh vào đó khi lau.",
                                          "The power / Touch ID button can't be locked; go easy on it while cleaning.")),
        ]
        case .translate: return [
            ("character.cursor.ibeam", L("Bôi đen chữ ở app bất kỳ rồi bấm ⌃⇧8: tai thỏ hiện bản dịch. Chữ Việt dịch sang Anh, chữ khác dịch sang Việt.",
                                        "Select text in any app and press ⌃⇧8. Vietnamese goes to English, everything else to Vietnamese.")),
            ("arrow.left.arrow.right", L("Thay chỗ chọn: đưa bản dịch vào đúng chỗ vừa bôi đen. Sao chép: chép bản dịch.",
                                        "Replace: puts the translation where your selection was. Copy: copies it.")),
            ("hand.raised", L("Đọc chữ đang bôi đen cần quyền Trợ năng: Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → RinNotch.",
                             "Reading the selection needs Accessibility: System Settings → Privacy & Security → Accessibility → RinNotch.")),
            ("globe", L("Dịch bằng bộ dịch có sẵn của Mac, trên máy (macOS 15+). Lần đầu có thể cần tải gói ngôn ngữ ở Cài đặt → Chung → Ngôn ngữ & Vùng → Ngôn ngữ dịch.",
                       "Uses the Mac's built-in translator on-device (macOS 15+). You may need to download languages in Settings → General → Language & Region → Translation Languages.")),
        ]
        case .windows: return [
            ("macwindow", L("Mở bằng ⌃⇧9 (hoặc số 9 khi tai thỏ đang mở). Hàng trái chỉnh cửa sổ của app đang dùng: nửa, góc, ⅓, ⅔, phóng to, giữa, sang màn hình kế bên.",
                           "Open with ⌃⇧9 (or 9 while the notch is open). The left grid moves the current app's window: halves, corners, thirds, two-thirds, maximize, center, next display.")),
            ("square.grid.2x2", L("Hàng phải xếp nhiều app cùng lúc: 2 app cạnh nhau hoặc trên dưới, 3 app, 3 cột, 4 góc, hoặc Xếp hết mọi cửa sổ đang mở trên màn hình. App mở gần nhất nằm bên trái / trên.",
                                 "The right grid arranges several apps at once: 2 side by side or stacked, 3 apps, 3 columns, 4 corners, or tile every open window on the screen. The most recent app goes left / top.")),
            ("arrow.uturn.backward", L("Trả lại: đưa các cửa sổ vừa chỉnh về đúng chỗ cũ. Thu nhỏ: cất cửa sổ đang dùng xuống Dock.",
                                      "Restore puts the windows you just moved back. Minimize sends the current window to the Dock.")),
            ("hand.raised", L("Cần quyền Trợ năng. macOS 15 trở lên cũng có phím Fn + ⌃ + mũi tên để xếp cửa sổ, nên RinNotch không gán thêm phím riêng cho từng kiểu.",
                             "Needs Accessibility. macOS 15+ also has Fn + ⌃ + arrow keys for tiling, so RinNotch doesn't add its own shortcut per layout.")),
        ]
        case .system: return [
            ("gauge.with.dots.needle.33percent", L("Xem CPU, RAM, tốc độ mạng, mức nhiệt và pin.",
                                                  "Shows CPU, memory, network speed, thermal state and battery.")),
            ("leaf", L("Chỉ đo khi mục này đang mở, không chạy ngầm.",
                      "Only measures while this section is open.")),
        ]
        case .alerts: return [
            ("airpodspro", L("Kết nối tai nghe Bluetooth: hiện đúng mẫu tai nghe và % pin (AirPods có pin từng bên và hộp).",
                            "Bluetooth headphones: shows the model and battery (AirPods show each bud and the case).")),
            ("bolt.fill", L("Cắm và rút sạc, pin yếu 20% và 10% đều có thông báo thả xuống.",
                           "Plugging in, unplugging, and low battery at 20% and 10% all drop down an alert.")),
            ("wifi.slash", L("Mất mạng hơn vài giây thì báo, có mạng lại cũng báo. Wi-Fi chập chờn chốc lát thì không báo.",
                            "Losing the internet for more than a few seconds drops an alert, and so does getting it back.")),
            ("waveform", L("App đang ghi âm (Ghi âm, QuickTime…) thì tai thỏ hiện sóng âm và thời gian. Sóng âm cần quyền micro.",
                          "When an app records audio (Voice Memos, QuickTime…), the notch shows a waveform and time. The waveform needs mic access.")),
            ("arrow.down.circle", L("Đang tải file bằng Safari, Chrome hoặc nhận AirDrop vào thư mục Tải về: hai bên tai thỏ hiện % và tốc độ, xong thì báo. Tải lên (upload) thì macOS không cho app khác xem.",
                                   "Downloading with Safari, Chrome or receiving AirDrop into Downloads: the notch shows % and speed, then tells you when it's done. macOS doesn't expose uploads to other apps.")),
            ("switch.2", L("Bật / tắt từng loại trong Cài đặt.", "Turn each one on or off in Settings.")),
        ]
        }
    }
}

enum Tips {
    static var startTopic: TipTopic = .start
}

struct TipsView: View {
    @State private var topic: TipTopic = Tips.startTopic

    var body: some View {
        VStack(spacing: 14) {
            Text(L("Mẹo dùng RinNotch", "RinNotch Tips")).font(.system(size: 22, weight: .bold, design: .rounded))

            HStack(spacing: 6) {
                ForEach(TipTopic.allCases) { t in
                    Button {
                        topic = t
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 15, weight: .semibold))
                            Text(t.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(width: 56, height: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(topic == t ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                        .foregroundStyle(topic == t ? Color.accentColor : Color.primary.opacity(0.75))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(HoverPlain())
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(topic.tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tip.0)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        Text(tip.1)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .softCard()

            Text(L("Mở lại bất cứ lúc nào: biểu tượng RinNotch trên thanh menu → Mẹo dùng, hoặc nút ? trên tai thỏ.",
                   "Open again anytime: RinNotch menu bar icon → Tips, or the ? button in the notch."))
                .noteText().multilineTextAlignment(.center)
        }
        .panelStyle(width: 700)
    }
}

// MARK: - Giới thiệu

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppIconView(size: 96)
            Text("RinNotch").font(.system(size: 26, weight: .bold, design: .rounded))
            Text(L("Phiên bản", "Version") + " \(AppInfo.version)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(L("Biến tai thỏ MacBook thành khu tiện ích nhỏ: nhạc, kệ file, bộ nhớ tạm, ghi chú, hẹn giờ và thông báo thả xuống.",
                   "Turns your MacBook notch into a small hub: music, file shelf, clipboard, notes, timer and drop-down alerts."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Text(L("Làm bởi Phước Rin", "Made by Phước Rin")).font(.system(size: 13, weight: .semibold))
                GlassGroup(spacing: 10) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            link("YouTube", "play.rectangle.fill", AppInfo.youtubeURL)
                            link("Facebook", "f.square.fill", AppInfo.facebookURL)
                        }
                        GridRow {
                            link("TikTok", "music.note", AppInfo.tiktokURL)
                            link("GitHub", "chevron.left.forwardslash.chevron.right", AppInfo.repoURL)
                        }
                        GridRow {
                            link("phuocrin.com", "globe", AppInfo.webURL).gridCellColumns(2)
                        }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity).softCard().padding(.top, 6)

            Text(L("Miễn phí · Mã nguồn mở (MIT)", "Free · Open source (MIT)")).noteText().padding(.top, 2)
        }
        .panelStyle()
    }

    private func link(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
        }
        .glassButton().controlSize(.large)
    }
}

// MARK: - Báo lỗi

enum BugReport {
    @MainActor
    static var log: String { Diag.lines.isEmpty ? L("(chưa có nhật ký)", "(no log yet)") : Diag.lines.joined(separator: "\n") }

    @MainActor
    static var template: String {
        L("Mô tả lỗi:", "What happened:") + "\n\n\n"
            + L("Các bước để gặp lỗi:", "Steps to reproduce:") + "\n1. \n2. \n\n"
            + "---\n" + AppInfo.diagnostics + "\n\n" + L("Nhật ký:", "Log:") + "\n" + log
    }

    @MainActor
    static var emailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[RinNotch \(AppInfo.version)] " + L("Báo lỗi", "Bug report")),
            URLQueryItem(name: "body", value: template),
        ]
        return c.url
    }

    @MainActor
    static var githubURL: URL? {
        var c = URLComponents(string: "https://github.com/PhuocRin/RinNotch/issues/new")
        c?.queryItems = [
            URLQueryItem(name: "title", value: L("Báo lỗi: ", "Bug: ")),
            URLQueryItem(name: "body", value: template),
        ]
        return c?.url
    }
}

struct BugReportView: View {
    private let info = AppInfo.diagnostics
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "ladybug.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.orange)
            Text(L("Báo lỗi", "Report a bug")).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(L("Gặp lỗi hay có gì chưa ổn? Bạn mô tả giúp mình nha, mình sẽ sửa ở bản sau.",
                   "Found a bug or something off? Tell me what happened and I'll fix it in the next version."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Thông tin gửi kèm", "Info included")).font(.system(size: 11, weight: .semibold))
                Text(info).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(L("Gồm phiên bản app, macOS, loại chip, quyền micro và nhật ký chẩn đoán gần nhất (tên app đang phát nhạc hoặc ghi âm, tên tai nghe). Không có thông tin cá nhân nào khác.",
                       "App version, macOS, chip, microphone permission and the recent diagnostic log (names of apps playing or recording, headphone name). No other personal information."))
                    .noteText().padding(.top, 2)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).softCard(cornerRadius: 16)

            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        if let url = BugReport.emailURL { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(L("Gửi qua email", "Send by email"), systemImage: "envelope.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)

                    HStack(spacing: 10) {
                        Button {
                            if let url = BugReport.githubURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Text(L("Báo trên GitHub", "Report on GitHub")).frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(info + "\n\n" + BugReport.log, forType: .string)
                            ClipboardWatcher.shared?.ignore(pb.changeCount)
                            copied = true
                        } label: {
                            Text(copied ? L("Đã sao chép", "Copied") : L("Sao chép kèm nhật ký", "Copy with log")).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    .font(.system(size: 12)).controlSize(.large)
                }
            }
        }
        .panelStyle()
    }
}

// MARK: - Cập nhật

/// Kiểm tra gói cập nhật có đúng do Phước Rin phát hành không. Khoá bí mật tương ứng nằm trong secret RINNOTCH_SIGNING.
enum UpdateSecurity {
    static let publicKeyBase64 = "S3XMA/KizwoiAT7mflAuiYRpD1jWsP3wJRch5GWgxlA="

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    static func currentRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static var currentIsAdHoc: Bool {
        guard let req = currentRequirement() else { return true }
        var text: CFString?
        SecRequirementCopyString(req, [], &text)
        return (text as String?)?.contains("cdhash") ?? true
    }

    static let developerIDRequirement: SecRequirement? = {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
        return req
    }()

    static func newAppIsTrusted(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        if currentIsAdHoc { return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess }
        if let same = currentRequirement(), SecStaticCodeCheckValidity(code, flags, same) == errSecSuccess { return true }
        if let devID = developerIDRequirement, SecStaticCodeCheckValidity(code, flags, devID) == errSecSuccess { return true }
        return false
    }
}

enum UpdateError: Error {
    case missingPackage, badSignature, badApp, notWritable, failed(String)

    var message: String {
        switch self {
        case .missingPackage:
            return L("Bản này chưa có gói tự cập nhật. Bạn tải thủ công giúp mình nha.",
                     "This version has no auto-update package. Please download it manually.")
        case .badSignature:
            return L("Gói tải về không đúng chữ ký của Phước Rin nên RinNotch không cài.",
                     "The downloaded package isn't signed by Phước Rin, so RinNotch won't install it.")
        case .badApp:
            return L("App trong gói cập nhật không hợp lệ nên RinNotch không cài.",
                     "The app inside the update package isn't valid, so RinNotch won't install it.")
        case .notWritable:
            return L("RinNotch chỉ tự cập nhật được khi nằm trong thư mục Applications. Bạn kéo RinNotch vào Applications rồi thử lại nha.",
                     "RinNotch can only update itself from the Applications folder. Move it there and try again.")
        case .failed(let detail):
            return L("Có lỗi khi cập nhật: ", "Update failed: ") + detail
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: URL
    }

    struct Release: Decodable, Equatable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) }
        var notes: String { body ?? "" }
        var zipURL: URL? { assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url }
        var sigURL: URL? { assets.first { $0.name.hasSuffix(".zip.sig") }?.browser_download_url }
        var canAutoInstall: Bool { zipURL != nil && sigURL != nil }
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case installFailed(Release, String)
        case updated(from: String)
    }

    @Published private(set) var state: State = .idle
    var onChange: (@MainActor () -> Void)?
    var onFoundInBackground: (@MainActor (Release) -> Void)?
    var onInstallFailed: (@MainActor () -> Void)?

    var available: Release? {
        switch state {
        case let .available(r), let .installFailed(r, _): return r
        default: return nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func noteJustUpdated() -> Bool {
        guard let from = Prefs.justUpdatedFrom else { return false }
        Prefs.justUpdatedFrom = nil
        guard from != AppInfo.version else { return false }
        state = .updated(from: from)
        return true
    }

    func checkIfDue() {
        guard let interval = Prefs.updateFrequency.interval else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < interval { return }
        check(background: true)
    }

    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var retryVersion = ""
    /// Bản mới tìm thấy gần nhất: lần hỏi lại bị lỗi mạng thì vẫn giữ để người dùng cài được.
    private var lastFound: Release?

    /// Hỏi lại sau 3 phút khi bản mới chưa có đủ gói cài (tối đa 6 lần cho mỗi bản, khỏi tốn lượt hỏi GitHub).
    /// Trả về false khi đã hết lượt chờ.
    @discardableResult
    private func scheduleRetry(for version: String) -> Bool {
        if version != retryVersion { retryVersion = version; retryCount = 0 }
        guard retryCount < 6 else { return false }
        retryCount += 1
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check(background: true) }
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: w)
        return true
    }

    func check(background: Bool = false) {
        if isBusy { return }
        if !background { state = .checking }
        Task { await run(background: background) }
    }

    private func run(background: Bool) async {
        var req = URLRequest(url: AppInfo.apiLatestRelease, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RinNotch/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            if Updater.isNewer(rel.version, than: AppInfo.version) {
                // Vừa bấm phát hành thì GitHub đã coi là bản mới nhất nhưng gói cài phải ~5 phút sau mới gắn vào.
                // Lúc đó chưa báo (kiểm tra nền) và hẹn hỏi lại, để không kẹt ở nút tải thủ công.
                // Hết lượt chờ mà vẫn thiếu gói (bản phát hành lỗi) thì vẫn báo, người dùng tải thủ công.
                if !rel.canAutoInstall {
                    if scheduleRetry(for: rel.version), background { return }
                } else {
                    Prefs.lastUpdateCheck = Date()
                }
                lastFound = rel
                if background, let a = available, a.version == rel.version, a.canAutoInstall == rel.canAutoInstall { return }
                state = .available(rel)
                onChange?()
                if background { onFoundInBackground?(rel) }
                return
            }
            Prefs.lastUpdateCheck = Date()
            lastFound = nil
            if !background { state = .upToDate }
        } catch {
            if !background {
                // Đã biết có bản mới mà lần hỏi lại lỗi (mạng, giới hạn GitHub) thì giữ bản đó, không xoá dấu báo.
                if let r = lastFound { state = .available(r) } else { state = .failed }
            }
        }
        onChange?()
    }

    func install(_ rel: Release) {
        switch state {
        case .downloading, .installing: return
        default: break
        }
        Task { await performInstall(rel) }
    }

    private func performInstall(_ rel: Release) async {
        do {
            guard let zipURL = rel.zipURL, let sigURL = rel.sigURL else { throw UpdateError.missingPackage }
            state = .downloading(rel)
            onChange?()
            let (zipData, zipResp) = try await URLSession.shared.data(from: zipURL)
            let (sigData, sigResp) = try await URLSession.shared.data(from: sigURL)
            guard (zipResp as? HTTPURLResponse)?.statusCode == 200,
                  (sigResp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let sigText = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let signature = Data(base64Encoded: sigText),
                  UpdateSecurity.verify(zipData, signature: signature) else { throw UpdateError.badSignature }
            state = .installing(rel)
            let newApp = try await Task.detached { () throws -> URL in try Installer.unpack(zipData) }.value
            guard Installer.bundleID(of: newApp) == Bundle.main.bundleIdentifier,
                  UpdateSecurity.newAppIsTrusted(newApp) else { throw UpdateError.badApp }
            try Installer.replaceAndRelaunch(with: newApp)
        } catch let e as UpdateError {
            state = .installFailed(rel, e.message)
        } catch {
            state = .installFailed(rel, UpdateError.failed(error.localizedDescription).message)
        }
        onChange?()
        onInstallFailed?()
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum Installer {
    static func unpack(_ zipData: Data) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RinNotchUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try zipData.write(to: zip)
        let out = dir.appendingPathComponent("unpacked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.failed("ditto \(p.terminationStatus)") }
        let app = out.appendingPathComponent("RinNotch.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.badApp }
        return app
    }

    static func bundleID(of app: URL) -> String? { Bundle(url: app)?.bundleIdentifier }

    @MainActor
    static func replaceAndRelaunch(with newApp: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard !current.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: current.path) else { throw UpdateError.notWritable }
        Prefs.justUpdatedFrom = AppInfo.version
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$1.old"
        if /bin/mv "$1" "$1.old"; then
          if /bin/mv "$2" "$1"; then /bin/rm -rf "$1.old"; else /bin/mv "$1.old" "$1"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rinnotch-update", current.path, newApp.path]
        do {
            try p.run()
        } catch {
            Prefs.justUpdatedFrom = nil
            throw UpdateError.failed(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    @AppStorage("updateFrequency") private var frequency: UpdateFrequency = .daily
    @AppStorage("updateMode") private var mode: UpdateMode = .ask

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 76)
            switch updater.state {
            case .idle:
                title(L("Kiểm tra cập nhật", "Check for updates"))
                Text("RinNotch \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L("Kiểm tra ngay", "Check now")) { updater.check() }.glassButton(prominent: true)
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Đang kiểm tra bản mới…", "Checking for updates…")).font(.system(size: 13)).foregroundStyle(.secondary)
            case .upToDate:
                title(L("Bạn đang dùng bản mới nhất", "You're on the latest version"))
                Text("RinNotch \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(.secondary)
            case .failed:
                title(L("Chưa kiểm tra được", "Couldn't check"))
                Text(L("Bạn kiểm tra kết nối mạng rồi thử lại nha.", "Check your internet connection and try again."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L("Thử lại", "Try again")) { updater.check() }.glassButton().controlSize(.large)
            case let .available(rel):
                title(L("Có bản mới RinNotch \(rel.version)", "RinNotch \(rel.version) is available"))
                Text(L("Bạn đang dùng bản \(AppInfo.version)", "You're on version \(AppInfo.version)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                notesBox(rel.notes)
                actions(for: rel)
            case let .downloading(rel):
                ProgressView().controlSize(.small)
                title(L("Đang tải RinNotch \(rel.version)…", "Downloading RinNotch \(rel.version)…"))
            case let .installing(rel):
                ProgressView().controlSize(.small)
                title(L("Đang cài RinNotch \(rel.version)…", "Installing RinNotch \(rel.version)…"))
                Text(L("RinNotch sẽ tự đóng và mở lại trong vài giây.", "RinNotch will quit and reopen in a few seconds."))
                    .noteText().multilineTextAlignment(.center)
            case let .installFailed(rel, reason):
                title(L("Chưa cập nhật được", "Couldn't update"))
                Text(reason).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions(for: rel)
            case let .updated(from):
                Image(systemName: "checkmark.seal.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.green)
                title(L("Đã cập nhật lên RinNotch \(AppInfo.version)", "Updated to RinNotch \(AppInfo.version)"))
                Text(L("Từ bản \(from)", "From version \(from)")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            settings
        }
        .panelStyle(width: 360)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 19, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func notesBox(_ notes: String) -> some View {
        if !notes.isEmpty {
            ScrollView {
                Text(notes).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 140).padding(14).softCard(cornerRadius: 16)
        }
    }

    @ViewBuilder
    private func actions(for rel: Updater.Release) -> some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                if rel.canAutoInstall {
                    Button {
                        updater.install(rel)
                    } label: {
                        Label(L("Cập nhật ngay", "Update now"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Text(L("Tải thủ công", "Download manually")).font(.system(size: 12)).frame(maxWidth: .infinity)
                    }
                    .glassButton().controlSize(.large)
                } else {
                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Label(L("Tải bản mới", "Download update"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                }
            }
        }
        if UpdateSecurity.currentIsAdHoc && rel.canAutoInstall {
            Text(L("Lần cập nhật này macOS có thể hỏi lại quyền micro, Notes, Music một lần. Từ bản sau thì không cần nữa.",
                   "After this update macOS may ask again for microphone, Notes and Music access once. Future updates won't."))
                .noteText().multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Text(L("Tự kiểm tra cập nhật", "Check for updates")).font(.system(size: 12, weight: .semibold))
                Picker("", selection: $frequency) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: frequency) { updater.checkIfDue() }
            }
            VStack(spacing: 6) {
                Text(L("Khi có bản mới", "When an update is available")).font(.system(size: 12, weight: .semibold))
                Picker("", selection: $mode) {
                    ForEach(UpdateMode.allCases, id: \.self) { m in Text(m.shortTitle).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(frequency == .off)
            }
            Text(L("Chỉ hỏi GitHub có bản mới không, không gửi thông tin gì của bạn.",
                   "It only asks GitHub for new versions; nothing about you is sent."))
                .noteText().multilineTextAlignment(.center)
        }
        .padding(14).frame(maxWidth: .infinity).softCard(cornerRadius: 16).padding(.top, 4)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let model = NotchModel()
    let updater = Updater()
    var controller: NotchController!
    var statusItem: NSStatusItem!
    var headphones: HeadphoneWatcher?
    var recording: RecordingWatcher?
    private var updateTimer: Timer?

    lazy var settingsPanel = Panel { AnyView(SettingsView()) }
    lazy var aboutPanel = Panel { AnyView(AboutView()) }
    lazy var supportPanel = Panel { AnyView(SupportView()) }
    lazy var tipsPanel = Panel { AnyView(TipsView()) }
    lazy var bugPanel = Panel { AnyView(BugReportView()) }
    lazy var updatePanel = Panel { [unowned self] in AnyView(UpdateView(updater: self.updater)) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ghi lệnh vào trình đọc nhạc đúng lúc nó vừa thoát sẽ gây SIGPIPE và làm sập app: bỏ qua tín hiệu này.
        signal(SIGPIPE, SIG_IGN)
        AppDelegate.shared = self
        controller = NotchController(model: model)
        ClipboardWatcher.shared = ClipboardWatcher(model: model)
        PowerWatcher.shared = PowerWatcher(model: model)
        headphones = HeadphoneWatcher(model: model)
        recording = RecordingWatcher(model: model)
        TimerEngine.shared = TimerEngine(model: model)
        MediaHub.shared = MediaHub(model: model)
        MediaWatcher.shared = MediaWatcher(model: model)
        AppMusicBridge.shared = AppMusicBridge()
        NetworkWatcher.shared = NetworkWatcher(model: model)
        KeepAwake.shared.setup(model: model)
        KeyboardLock.shared.model = model
        CopyToast.shared.setup()
        PasteStack.shared.setup(model: model)
        DownloadWatcher.shared.setup(model: model)
        EditMenu.install()
        NotificationCenter.default.addObserver(forName: .rinHotkeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
        setupStatusItem()
        HotkeyCenter.registerAll()
        setupUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaWatcher.shared?.stop()
        KeyboardLock.shared.unlock()
        PasteStack.shared.stop(.quit)
        KeepAwake.shared.stop(.quit, silent: true)
    }

    /// Phím tắt toàn hệ thống vừa được bấm.
    func perform(_ a: HotAction) {
        switch a {
        case .toggleHidden:
            toggleHidden()
        case .translate:
            TranslateModel.shared.startFromHotkey()
        case .library:
            if LibraryWindow.shared.isFrontmost { LibraryWindow.shared.close() } else { showLibrary(model.libraryTab) }
        default:
            guard let t = a.tab else { return }
            if model.hidden { toggleHidden() }
            if model.expanded && model.tab == t {
                controller.collapse()
            } else {
                controller.expand(tab: t, byKeyboard: true)
            }
        }
    }

    // MARK: Cập nhật

    private func setupUpdater() {
        updater.onChange = { [weak self] in self?.rebuildMenu() }
        updater.onFoundInBackground = { [weak self] rel in
            guard let self else { return }
            switch Prefs.updateMode {
            case .auto: self.updater.install(rel)
            case .ask: self.updatePanel.show(attention: true)
            case .notify: self.rebuildMenu()
            }
        }
        updater.onInstallFailed = { [weak self] in self?.updatePanel.show(attention: true) }
        let justUpdated = updater.noteJustUpdated()
        // Mẹo dùng tự mở một lần (cài mới hoặc vừa lên bản có Mẹo dùng); lúc đó không mở thêm cửa sổ Cập nhật.
        if !UserDefaults.standard.bool(forKey: "tipsShown") {
            UserDefaults.standard.set(true, forKey: "tipsShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.showTips(.start, attention: true) }
            }
        } else if justUpdated {
            updatePanel.show(attention: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.updater.checkIfDue() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updater.checkIfDue() }
        }
        updateTimer?.tolerance = 600
    }

    // MARK: Thanh menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
    }

    private func menuIcon() -> NSImage? {
        let name = updater.available != nil ? "MenuBarIconUpdate" : "MenuBarIcon"
        let img = NSImage(named: name) ?? NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "RinNotch")
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        return img
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func rebuildMenu() {
        statusItem.button?.image = menuIcon()
        let menu = NSMenu()
        if let rel = updater.available {
            let u = item(L("⬆︎ Có bản mới RinNotch \(rel.version)…", "⬆︎ RinNotch \(rel.version) available…"), #selector(showUpdate))
            menu.addItem(u)
            menu.addItem(.separator())
        }
        let hide = item(model.hidden ? L("Hiện RinNotch", "Show RinNotch") : L("Ẩn RinNotch", "Hide RinNotch"),
                        #selector(toggleHiddenAction))
        showKey(hide, .toggleHidden)
        menu.addItem(hide)

        let open = NSMenuItem(title: L("Mở mục", "Open"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in Tab.allCases {
            let i = item(t.title, #selector(openTab(_:)))
            i.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            i.representedObject = t.rawValue
            if let a = HotAction(rawValue: t.rawValue) { showKey(i, a) }
            sub.addItem(i)
        }
        open.submenu = sub
        menu.addItem(open)
        let lib = item(L("Mở bảng lớn…", "Open Big Board…"), #selector(showLibraryAction))
        showKey(lib, .library)
        menu.addItem(lib)
        menu.addItem(.separator())

        menu.addItem(item(L("Cài đặt…", "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(L("Kiểm tra cập nhật…", "Check for Updates…"), #selector(showUpdate)))
        menu.addItem(.separator())
        menu.addItem(item(L("Mẹo dùng", "Tips"), #selector(showTipsAction)))
        menu.addItem(item(L("Giới thiệu RinNotch", "About RinNotch"), #selector(showAbout)))
        menu.addItem(item(L("Báo lỗi…", "Report a Bug…"), #selector(showBug)))
        menu.addItem(item(L("Sao chép nhật ký chẩn đoán", "Copy Diagnostic Log"), #selector(copyDiag)))
        menu.addItem(item(L("♥ Ủng hộ tác giả…", "♥ Support the Author…"), #selector(showSupport)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Thoát RinNotch", "Quit RinNotch"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// Hiện phím tắt cạnh dòng menu (phím thật do hệ thống bắt).
    private func showKey(_ i: NSMenuItem, _ a: HotAction) {
        guard let (key, mods) = HotkeyCenter.menuKey(a) else { return }
        i.keyEquivalent = key
        i.keyEquivalentModifierMask = mods
    }

    func toggleHidden() {
        controller.setHidden(!model.hidden)
        rebuildMenu()
    }

    @objc func toggleHiddenAction() { toggleHidden() }

    @objc func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = Tab(rawValue: raw) else { return }
        if model.hidden { toggleHidden() }
        controller.expand(tab: t)
    }

    @objc func showSettings() { settingsPanel.show(attention: true) }

    /// Bảng lớn: cửa sổ chứa hết Bộ nhớ tạm và Kệ file.
    func showLibrary(_ tab: LibraryTab) {
        controller.collapse()
        model.libraryTab = tab
        LibraryWindow.shared.show(model)
    }
    @objc func showLibraryAction() { showLibrary(model.libraryTab) }
    @objc func showAbout() { aboutPanel.show() }
    @objc func showSupport() { supportPanel.show() }
    @objc func showTipsAction() { showTips(.start) }
    func showTips(_ topic: TipTopic, attention: Bool = false) {
        Tips.startTopic = topic
        tipsPanel.show(attention: attention)
    }
    @objc func showBug() { bugPanel.show() }
    @objc func showUpdate() {
        // Luôn hỏi lại GitHub: bản tìm thấy lần trước có thể đã cũ (vd thấy 1.2 rồi Phước ra tiếp 1.2.1).
        if !updater.isBusy { updater.check() }
        updatePanel.show()
    }

    @objc func copyDiag() {
        let text = AppInfo.diagnostics + "\n\n" + BugReport.log
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardWatcher.shared?.ignore(pb.changeCount)
    }
}

@main
struct RinNotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
