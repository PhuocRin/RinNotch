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

// MARK: - Hình học tai thỏ

struct NotchGeometry {
    let screenFrame: CGRect
    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first
        guard let s = screen else {
            return NotchGeometry(screenFrame: .zero, hasNotch: false, width: 190, height: 32)
        }
        let top = s.safeAreaInsets.top
        if top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let w = s.frame.width - l.width - r.width
            return NotchGeometry(screenFrame: s.frame, hasNotch: true, width: max(w, 120), height: top)
        }
        let menuH = s.frame.maxY - s.visibleFrame.maxY
        return NotchGeometry(screenFrame: s.frame, hasNotch: false, width: 190, height: max(menuH, 24))
    }
}

// MARK: - Dữ liệu

enum Tab: String, CaseIterable, Identifiable {
    case media, shelf, clipboard, notes, timer, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: return "Nhạc"
        case .shelf: return "Kệ file"
        case .clipboard: return "Bộ nhớ tạm"
        case .notes: return "Ghi chú"
        case .timer: return "Hẹn giờ"
        case .system: return "Hệ thống"
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

enum ClipKind {
    case text(String)
    case files([URL])
    case image(NSImage)
}

struct ClipItem: Identifiable {
    let id = UUID()
    let kind: ClipKind
    let date = Date()

    var preview: String {
        switch kind {
        case .text(let s):
            return s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file: \(urls[0].lastPathComponent)…"
        case .image:
            return "Hình ảnh"
        }
    }
    var symbol: String {
        switch kind {
        case .text(let s): return (s.hasPrefix("http://") || s.hasPrefix("https://")) ? "link" : "text.alignleft"
        case .files: return "doc"
        case .image: return "photo"
        }
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
    @Published var clips: [ClipItem] = []
    @Published var notes: [NoteItem] = []
    @Published var noteDraft = ""
    @Published var noteStatus: String?
    @Published var dropTargeted = false
    @Published var micDenied = false
    @Published var nowPlaying: NowPlaying?
    @Published var artwork: NSImage?
    @Published var timer = TimerState()

    var musicCompact: Bool { nowPlaying?.playing == true && !(nowPlaying?.title.isEmpty ?? true) }
    var timerCompact: Bool { timer.running }

    var draggingOut = false
    private var transientTimer: Timer?

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
    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
        saveShelf()
    }
    func clearShelf() {
        shelf.removeAll()
        saveShelf()
    }
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

// MARK: - Giao diện

struct PillButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(configuration.isPressed ? 0.24 : 0.12))
            )
            .foregroundStyle(.white)
            .contentShape(Capsule())
    }
}

struct IslandView: View {
    @ObservedObject var m: NotchModel

    enum Phase: Equatable { case idle, compact, banner, expanded }

    var phase: Phase {
        if m.expanded { return .expanded }
        if m.transient != nil { return .banner }
        if m.recording != nil || m.timerCompact || m.musicCompact { return .compact }
        return .idle
    }

    var size: CGSize {
        switch phase {
        case .idle: return CGSize(width: m.notchWidth, height: m.notchHeight)
        case .compact: return CGSize(width: m.notchWidth + (m.recording == nil && !m.timerCompact ? 130 : 210), height: m.notchHeight)
        case .banner: return CGSize(width: max(m.notchWidth + 170, 400), height: m.notchHeight + 78)
        case .expanded: return CGSize(width: NotchController.expandedWidth, height: m.notchHeight + 214)
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .idle: return 9
        case .compact: return 14
        case .banner: return 26
        case .expanded: return 28
        }
    }

    var topRadius: CGFloat { phase == .idle ? 0 : 8 }

    var body: some View {
        let s = size
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: bottomRadius, topRadius: topRadius).fill(Color.black)
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
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        }
        .frame(width: s.width + 2 * topRadius, height: s.height)
        .clipShape(NotchShape(bottomRadius: bottomRadius, topRadius: topRadius))
        .shadow(color: .black.opacity(phase == .idle ? 0 : 0.45), radius: 18, x: 0, y: 8)
        .opacity((m.hidden || (phase == .idle && !m.hasNotch)) ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: phase)
        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: m.transient)
        .animation(.easeOut(duration: 0.2), value: m.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Dạng gọn (ôm hai bên tai thỏ)

struct CompactView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: m.notchWidth)
            trailing
        }
        .padding(.horizontal, 14)
        .foregroundStyle(.white)
    }

    @ViewBuilder var leading: some View {
        if let r = m.recording {
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
        } else if m.musicCompact {
            ArtworkView(image: m.artwork, size: 20, radius: 5)
        }
    }

    @ViewBuilder var trailing: some View {
        if m.recording != nil {
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
        } else if m.musicCompact {
            MusicBars()
        }
    }
}

struct MusicBars: View {
    @State private var phase = false
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: phase ? [14, 8, 16, 10][i] : [6, 14, 7, 13][i])
                    .animation(.easeInOut(duration: [0.45, 0.38, 0.5, 0.42][i]).repeatForever(autoreverses: true), value: phase)
            }
        }
        .frame(height: 18)
        .onAppear { phase = true }
    }
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
            switch m.transient {
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
        .foregroundStyle(.white)
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

struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    @State private var fill: CGFloat = 0

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.3)
                    .frame(width: 25, height: 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(charging ? Color.green : Color.white.opacity(0.85))
                    .frame(width: max(2, 21 * fill), height: 8)
                    .padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.55)).frame(width: 2, height: 5)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.2)) {
                fill = CGFloat(min(max(percent, 0), 100)) / 100
            }
        }
    }
}

// MARK: Dạng bung

struct ExpandedView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: max(m.notchHeight - 4, 0))
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { t in
                    Button {
                        m.tab = t
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.symbol)
                            if m.tab == t { Text(t.title) }
                        }
                            .font(.system(size: 11, weight: .semibold))
                            .frame(minWidth: 18)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(m.tab == t ? 0.2 : 0.06)))
                            .foregroundStyle(.white.opacity(m.tab == t ? 1 : 0.75))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
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
            }
            Group {
                switch m.tab {
                case .media: MediaView(m: m)
                case .shelf: ShelfView(m: m)
                case .clipboard: ClipboardView(m: m)
                case .notes: NotesView(m: m)
                case .timer: TimerView(m: m)
                case .system: SystemView()
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
        .buttonStyle(.plain)
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
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    Text(formatClock(m.timer.display(at: ctx.date), alwaysHours: true))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(m.timer.running ? Color.orange : Color.white)
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
                            .buttonStyle(.plain)
                            .disabled(m.timer.running)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bấm giờ chạy từ 00:00:00").font(.system(size: 12, weight: .semibold))
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
        .buttonStyle(.plain)
        .disabled(m.timer.running)
    }
}

@MainActor
final class TimerEngine {
    static var shared: TimerEngine?
    private let m: NotchModel
    private var tick: Timer?

    init(model: NotchModel) {
        m = model
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
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
    }

    func reset() {
        var t = m.timer
        t.running = false
        t.startedAt = nil
        t.accumulated = 0
        m.timer = t
    }

    func setMode(_ mode: TimerMode) {
        guard !m.timer.running else { return }
        var t = m.timer
        t.mode = mode
        t.accumulated = 0
        t.startedAt = nil
        m.timer = t
    }

    func setCountdown(minutes: Int) {
        guard !m.timer.running else { return }
        var t = m.timer
        t.countdownTotal = TimeInterval(minutes * 60)
        t.accumulated = 0
        m.timer = t
    }

    private func check() {
        let t = m.timer
        guard t.running, t.mode == .countdown, t.elapsed(at: Date()) >= t.countdownTotal else { return }
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
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
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
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c)
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
            tile("CPU", String(format: "%.0f%%", mon.cpu)) {
                Sparkline(values: mon.cpuHistory, maxValue: 100).stroke(Color.cyan, lineWidth: 1.5).frame(height: 30)
            }
            tile("RAM", "\(SystemMonitor.gb(mon.ramUsed)) GB") {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.purple).frame(width: g.size.width * CGFloat(min(mon.ramUsed / max(mon.ramTotal, 1), 1)))
                        }
                    }
                    .frame(height: 6)
                    Text("trên \(SystemMonitor.gb(mon.ramTotal)) GB").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
            tile("Mạng", nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(SystemMonitor.speed(mon.down), systemImage: "arrow.down").foregroundStyle(Color.green)
                    Label(SystemMonitor.speed(mon.up), systemImage: "arrow.up").foregroundStyle(Color.blue)
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            }
            tile("Nhiệt", thermalText.0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule().fill(i <= levelIndex ? thermalText.1 : Color.white.opacity(0.15)).frame(height: 6)
                        }
                    }
                    Text(mon.battery.map { "Pin \($0)%" } ?? "Mức nhiệt do macOS báo")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
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

    func tile<C: View>(_ title: String, _ value: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            if let value {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
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
                        Text("File nằm chờ ở đây, kéo ra chỗ khác để sao chép")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(m.shelf, id: \.self) { url in
                            ShelfItem(url: url, m: m)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Kéo ra = sao chép · giữ ⌘ = chuyển · chuột phải: thêm")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button("AirDrop") { Actions.airDrop(m.shelf) }.buttonStyle(PillButton(prominent: true))
                    Button("Sao chép") { Actions.copyFiles(m.shelf) }.buttonStyle(PillButton())
                    Button("Xoá kệ") { m.clearShelf() }.buttonStyle(PillButton())
                }
            }
        }
    }
}

struct ShelfItem: View {
    let url: URL
    @ObservedObject var m: NotchModel

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        VStack(spacing: 5) {
            FileThumb(url: url)
                .frame(width: 64, height: 50)
            Text(exists ? url.lastPathComponent : "File không còn")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 78)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .opacity(exists ? 1 : 0.45)
        .overlay(FileDragArea(url: url, m: m))
        .help(url.path)
    }
}

/// Vùng kéo file ra khỏi kệ: kéo thường = sao chép, giữ ⌘ khi kéo = chuyển file.
/// Bấm đúp để mở, chuột phải để xem thêm.
struct FileDragArea: NSViewRepresentable {
    let url: URL
    let m: NotchModel

    func makeNSView(context: Context) -> FileDragNSView {
        let v = FileDragNSView()
        update(v)
        return v
    }

    func updateNSView(_ v: FileDragNSView, context: Context) { update(v) }

    private func update(_ v: FileDragNSView) {
        v.url = url
        let model = m
        let u = url
        v.onStart = { model.draggingOut = true }
        v.onEnd = { moved in
            model.draggingOut = false
            if moved {
                model.removeFromShelf(u)
                Diag.log("Đã chuyển \(u.lastPathComponent) ra khỏi kệ")
            }
        }
        v.onRemove = { model.removeFromShelf(u) }
    }
}

final class FileDragNSView: NSView, NSDraggingSource {
    var url = URL(fileURLWithPath: "/")
    var onStart: (() -> Void)?
    var onEnd: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    private var downEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            downEvent = nil
            return
        }
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) { downEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, FileManager.default.fileExists(atPath: url.path) else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 56, height: 56)
        let p = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56), contents: icon)
        onStart?()
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return [] }
        // Mặc định sao chép; giữ ⌘ thì cho phép chuyển (Finder sẽ dời file đi).
        return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let moved = operation.contains(.move) || operation.contains(.generic)
        // Chỉ coi là đã chuyển khi file gốc thật sự không còn ở chỗ cũ.
        let gone = !FileManager.default.fileExists(atPath: url.path)
        onEnd?(moved && gone)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let u = url
        menu.addItem(ClosureMenuItem("Mở") { NSWorkspace.shared.open(u) })
        menu.addItem(ClosureMenuItem("Gửi AirDrop") { Actions.airDrop([u]) })
        menu.addItem(ClosureMenuItem("Sao chép") { Actions.copyFiles([u]) })
        menu.addItem(ClosureMenuItem("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        menu.addItem(.separator())
        let remove = onRemove
        menu.addItem(ClosureMenuItem("Bỏ khỏi kệ") { remove?() })
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

// MARK: Bộ nhớ tạm

struct ClipboardView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        if m.clips.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 22))
                Text("Copy gì đó, nó sẽ hiện ở đây").font(.system(size: 12, weight: .semibold))
                Text("Mật khẩu copy từ trình quản lý mật khẩu sẽ không được lưu")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(m.clips) { item in
                            Button {
                                ClipboardWatcher.shared?.restore(item)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 11))
                                        .frame(width: 16)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text(item.preview)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 6)
                                    Text(item.date, style: .relative)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Bấm để copy lại")
                        }
                    }
                }
                HStack {
                    Text("Bấm một dòng để copy lại").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button("Xoá hết") { m.clips.removeAll() }.buttonStyle(PillButton())
                }
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
        var item = NoteItem(text: text, date: Date(), savedToNotes: false)
        m.notes.insert(item, at: 0)
        m.noteDraft = ""
        m.noteStatus = "Đang lưu vào Notes…"
        m.saveNotes()

        let html = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let script = [
            "on run argv",
            "set t to item 1 of argv",
            "tell application \"Notes\"",
            "if not (exists folder \"RinNotch\") then make new folder with properties {name:\"RinNotch\"}",
            "make new note at folder \"RinNotch\" with properties {body:t}",
            "end tell",
            "end run",
        ]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = script.flatMap { ["-e", $0] } + [html]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        let id = item.id
        p.terminationHandler = { proc in
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
            item.savedToNotes = false
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

// MARK: - Theo dõi bộ nhớ tạm

@MainActor
final class ClipboardWatcher {
    static var shared: ClipboardWatcher?
    private let m: NotchModel
    private var last = NSPasteboard.general.changeCount
    private var ignored = -1
    private var timer: Timer?

    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    init(model: NotchModel) {
        m = model
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func ignore(_ count: Int) {
        ignored = count
        last = count
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        if pb.changeCount == ignored { return }
        let types = (pb.types ?? []).map(\.rawValue)
        if types.contains(where: { Self.skipTypes.contains($0) }) { return }

        var item: ClipItem?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            item = ClipItem(kind: .files(urls))
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item = ClipItem(kind: .text(String(s.prefix(20000))))
        } else if let img = NSImage(pasteboard: pb) {
            item = ClipItem(kind: .image(img))
        }
        guard let item else { return }
        if case .text(let s) = item.kind {
            m.clips.removeAll { if case .text(let o) = $0.kind { return o == s }; return false }
        }
        m.clips.insert(item, at: 0)
        if m.clips.count > 20 { m.clips.removeLast(m.clips.count - 20) }
    }

    func restore(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .files(let urls): pb.writeObjects(urls as [NSURL])
        case .image(let img): pb.writeObjects([img])
        }
        ignore(pb.changeCount)
        m.clips.removeAll { $0.id == item.id }
        m.clips.insert(item, at: 0)
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

    nonisolated static func readBattery(name: String) -> (left: Int?, right: Int?, caseLevel: Int?, main: Int?)? {
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
                             caseLevel: num(d["device_batteryLevelCase"]), main: num(d["device_batteryLevelMain"]))
                    if r.left != nil || r.right != nil || r.caseLevel != nil || r.main != nil { return r }
                }
            }
        }
        return nil
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
    private var lastPush = Date.distantPast
    private var requesting = false
    private var peakSinceLog: CGFloat = 0
    private var lastLog = Date.distantPast

    init(model: NotchModel) {
        m = model
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Phiên ghi âm giữ lại tối đa 15 phút sau khi tạm dừng để ghi tiếp thì cộng dồn thời gian.
    private var session: RecordingInfo?
    private let pausedVisible: TimeInterval = 8
    private let sessionKeep: TimeInterval = 15 * 60

    private func check() {
        let now = Date()
        let apps = CA.micUsers()
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
            startMeter()
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
        if let s = session, !s.paused || now.timeIntervalSince(s.pausedAt ?? now) < pausedVisible {
            visible = s
        }
        if m.recording != visible { m.recording = visible }
    }

    private func startMeter() {
        guard engine == nil, !requesting else { return }
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
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt, block: RecordingWatcher.makeTap(self))
        do {
            try e.start()
            engine = e
            Diag.log("Bắt đầu đo sóng âm")
        } catch {
            input.removeTap(onBus: 0)
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
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.receive(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
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
        input = nil
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
        if o["ready"] != nil { restarts = 0; return }
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
        system = np
        recompute()
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

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func running(_ bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    private func poll() {
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
                guard let out, let url = URL(string: out), url.scheme == "https" else { return }
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
            m.showTransient(ac ? .charging(percent: r.percent) : .unplugged(percent: r.percent), seconds: 3)
            return
        }
        // Pin yếu: báo một lần khi xuống tới 20% và 10% lúc đang dùng pin.
        if !ac, let last = lastPercent {
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
    let model: NotchModel
    let panel: NotchPanel
    private var geo = NotchGeometry.current()
    private var collapseWork: DispatchWorkItem?
    private var dragCountAtDown = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []
    private let panelSize = CGSize(width: 720, height: 320)

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
            if e.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { self?.collapse() }
                return nil
            }
            return e
        }) { monitors.append(l) }
    }

    func layout() {
        geo = NotchGeometry.current()
        model.hasNotch = geo.hasNotch
        model.notchWidth = geo.width
        model.notchHeight = geo.height
        let f = geo.screenFrame
        panel.setFrame(
            CGRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height, width: panelSize.width, height: panelSize.height),
            display: true
        )
    }

    private var notchRect: CGRect {
        let f = geo.screenFrame
        return CGRect(x: f.midX - geo.width / 2 - 8, y: f.maxY - geo.height - 6, width: geo.width + 16, height: geo.height + 6)
    }

    private var expandedRect: CGRect {
        let f = geo.screenFrame
        let w: CGFloat = NotchController.expandedWidth + 16 + 40
        let h = geo.height + 214 + 30
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func mouseMoved() {
        guard !model.hidden else { return }
        let p = NSEvent.mouseLocation
        if !model.expanded {
            guard notchRect.contains(p) else { return }
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            if pressed {
                // Đang kéo file từ nơi khác lên tai thỏ → mở kệ file.
                if NSPasteboard(name: .drag).changeCount != dragCountAtDown {
                    expand(tab: .shelf)
                }
            } else {
                expand(tab: nil)
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
        if model.draggingOut {
            model.draggingOut = false
            if !expandedRect.contains(NSEvent.mouseLocation) { scheduleCollapse(force: false) }
        }
    }

    func expand(tab: Tab?) {
        collapseWork?.cancel()
        if let tab {
            model.tab = tab
        } else if !model.expanded && model.transient == nil && model.recording == nil {
            // Đang hiện dạng gọn của hẹn giờ hoặc nhạc thì mở thẳng mục đó.
            if model.timerCompact { model.tab = .timer } else if model.musicCompact { model.tab = .media }
        }
        guard !model.expanded else { return }
        model.expanded = true
        panel.ignoresMouseEvents = false
    }

    func scheduleCollapse(force: Bool) {
        guard model.expanded else { return }
        if !force {
            if model.draggingOut { return }
            // Đang gõ ghi chú thì không tự thu lại, bấm ra ngoài hoặc Esc mới thu.
            if panel.isKeyWindow && model.tab == .notes && expandedRect.contains(NSEvent.mouseLocation) { return }
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
        guard model.expanded else { return }
        model.expanded = false
        model.dropTargeted = false
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow {
            _ = panel.makeFirstResponder(nil)
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

// MARK: - Phím tắt ⌥⌘N

enum HotKey {
    static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppDelegate.shared?.toggleHidden() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x524E_4348), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let model = NotchModel()
    var controller: NotchController!
    var statusItem: NSStatusItem!
    var headphones: HeadphoneWatcher?
    var recording: RecordingWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        HotKey.register()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaWatcher.shared?.stop()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let img = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "RinNotch")
            img?.isTemplate = true
            img?.size = NSSize(width: 18, height: 18)
            b.image = img
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let hide = NSMenuItem(title: model.hidden ? "Hiện RinNotch" : "Ẩn RinNotch", action: #selector(toggleHiddenAction), keyEquivalent: "n")
        hide.keyEquivalentModifierMask = [.command, .option]
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        for t in Tab.allCases {
            let item = NSMenuItem(title: "Mở \(t.title)", action: #selector(openTab(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Mở cùng máy", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let about = NSMenuItem(title: "RinNotch \(ver) (\(build)) · Phước Rin", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let diag = NSMenuItem(title: "Sao chép nhật ký chẩn đoán", action: #selector(copyDiag), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Thoát RinNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
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

    @objc func copyDiag() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        var text = "RinNotch \(ver) (\(build)) · macOS \(os) · quyền micro: \(mic)\n"
        text += Diag.lines.isEmpty ? "(chưa có nhật ký)" : Diag.lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardWatcher.shared?.ignore(pb.changeCount)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        rebuildMenu()
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
