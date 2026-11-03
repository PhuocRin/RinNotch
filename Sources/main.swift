// RinNotch — biến tai thỏ MacBook thành khu tiện ích nhỏ.
// Bản 1: hiệu ứng bung từ tai thỏ, kệ file, bộ nhớ tạm, ghi chú nhanh (lưu vào Apple Notes),
// gương camera, báo tai nghe kết nối, báo cắm sạc, sóng âm khi có app đang ghi âm, phím tắt ẩn ⌥⌘N.

import AppKit
import SwiftUI
import Combine
import AVFoundation
import CoreAudio
import IOKit.ps
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

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
    case shelf, clipboard, notes, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: return "Kệ file"
        case .clipboard: return "Bộ nhớ tạm"
        case .notes: return "Ghi chú"
        case .mirror: return "Gương"
        }
    }
    var symbol: String {
        switch self {
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "square.and.pencil"
        case .mirror: return "camera"
        }
    }
}

enum Transient: Equatable {
    case headphones(name: String, symbol: String)
    case charging(percent: Int)
    case unplugged(percent: Int)
}

struct RecordingInfo: Equatable {
    var appName: String
    var bundleID: String?
    var pid: pid_t
    var start: Date
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
    @Published var cameraDenied = false

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

    enum Phase: Equatable { case idle, compact, expanded }

    var phase: Phase {
        if m.expanded { return .expanded }
        if m.transient != nil || m.recording != nil { return .compact }
        return .idle
    }

    var compactExtra: CGFloat {
        if case .headphones = m.transient { return 300 }
        return 210
    }

    var size: CGSize {
        switch phase {
        case .idle: return CGSize(width: m.notchWidth, height: m.notchHeight)
        case .compact: return CGSize(width: m.notchWidth + compactExtra, height: m.notchHeight)
        case .expanded: return CGSize(width: 600, height: m.notchHeight + 200)
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .idle: return 9
        case .compact: return 14
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
        if let t = m.transient {
            switch t {
            case .headphones(_, let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
            case .charging:
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").foregroundStyle(Color.green)
                    Text("Đang sạc").foregroundStyle(Color.green)
                }
                .font(.system(size: 12, weight: .semibold))
            case .unplugged:
                HStack(spacing: 5) {
                    Image(systemName: "powerplug").foregroundStyle(.white.opacity(0.7))
                    Text("Đã ngắt sạc")
                }
                .font(.system(size: 12, weight: .semibold))
            }
        } else if let r = m.recording {
            RecordingBadge(info: r)
        }
    }

    @ViewBuilder var trailing: some View {
        if let t = m.transient {
            switch t {
            case .headphones(let name, _):
                HStack(spacing: 5) {
                    Text(name).lineLimit(1).truncationMode(.tail)
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: 120, alignment: .trailing)
            case .charging(let p), .unplugged(let p):
                HStack(spacing: 6) {
                    Text("\(p)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    BatteryGlyph(percent: p, charging: { if case .charging = t { return true }; return false }())
                }
            }
        } else if m.recording != nil {
            Waveform(levels: m.levels)
        }
    }
}

struct RecordingBadge: View {
    let info: RecordingInfo
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            TimelineView(.periodic(from: info.start, by: 1)) { ctx in
                Text(Self.format(ctx.date.timeIntervalSince(info.start)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
            }
        }
        .help("\(info.appName) đang ghi âm")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                        Label(t.title, systemImage: t.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(m.tab == t ? 0.2 : 0.06)))
                            .foregroundStyle(.white.opacity(m.tab == t ? 1 : 0.75))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let r = m.recording {
                    HStack(spacing: 6) {
                        RecordingBadge(info: r)
                        Waveform(levels: m.levels).scaleEffect(0.8)
                    }
                }
            }
            Group {
                switch m.tab {
                case .shelf: ShelfView(m: m)
                case .clipboard: ClipboardView(m: m)
                case .notes: NotesView(m: m)
                case .mirror: MirrorView(m: m)
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
                    Text("Kéo ra để sao chép · chuột phải để xem thêm")
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(exists ? url.lastPathComponent : "File không còn")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 78)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .opacity(exists ? 1 : 0.45)
        .help(url.path)
        .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(url) } }
        .onDrag {
            m.draggingOut = true
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Gửi AirDrop") { Actions.airDrop([url]) }
            Button("Sao chép") { Actions.copyFiles([url]) }
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Bỏ khỏi kệ") { m.removeFromShelf(url) }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Gõ ý tưởng rồi nhấn Enter…", text: $m.noteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.09)))
                    .onSubmit { NotesSaver.save(m) }
                Button("Lưu") { NotesSaver.save(m) }
                    .buttonStyle(PillButton(prominent: true))
                    .disabled(m.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let st = m.noteStatus {
                Text(st).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(m.notes.prefix(10)) { n in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: n.savedToNotes ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size: 10))
                                .foregroundStyle(n.savedToNotes ? Color.green : Color.white.opacity(0.4))
                                .padding(.top, 2)
                            Text(n.text).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
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

// MARK: Gương

final class CameraController: @unchecked Sendable {
    static let shared = CameraController()
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rinnotch.camera")
    private var configured = false

    func start() {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                if let dev = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: dev),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

final class PreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(session: CameraController.shared.session) }
    func updateNSView(_ nsView: PreviewNSView, context: Context) { nsView.needsLayout = true }
}

struct MirrorView: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06))
                if m.cameraDenied {
                    Text("Chưa có quyền camera.\nCài đặt → Quyền riêng tư & Bảo mật → Camera → bật RinNotch")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(10)
                } else {
                    CameraPreview()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .frame(width: 260)
            VStack(alignment: .leading, spacing: 10) {
                Text("Soi gương trước khi gọi hoặc live")
                    .font(.system(size: 13, weight: .semibold))
                Text("Camera chỉ bật khi đang mở mục này và tắt ngay khi tai thỏ thu lại.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Mở FaceTime") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .buttonStyle(PillButton(prominent: true))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
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
        m.showTransient(.headphones(name: name.isEmpty ? "Tai nghe" : name, symbol: Self.symbol(for: name)), seconds: 3.5)
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

    init(model: NotchModel) {
        m = model
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let apps = CA.micUsers()
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { $0.activationPolicy == .regular }
        if let app = apps.first {
            if m.recording?.pid != app.processIdentifier {
                m.recording = RecordingInfo(
                    appName: app.localizedName ?? "Ứng dụng",
                    bundleID: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    start: Date()
                )
            }
            startMeter()
        } else if m.recording != nil {
            m.recording = nil
            stopMeter()
        }
    }

    private func startMeter() {
        guard engine == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            return
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let db = 20 * log10(max(rms, 0.000_01))
            let level = CGFloat(min(max((db + 55) / 45, 0.05), 1))
            Task { @MainActor in self?.push(level) }
        }
        do {
            try e.start()
            engine = e
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func push(_ v: CGFloat) {
        let now = Date()
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

    func update() {
        let r = Self.read()
        guard let ac = r.ac else { return }
        defer { onAC = ac }
        guard let was = onAC, was != ac else { return }
        m.showTransient(ac ? .charging(percent: r.percent) : .unplugged(percent: r.percent), seconds: 3)
    }
}

// MARK: - Cửa sổ tai thỏ

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
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
        let w: CGFloat = 600 + 16 + 40
        let h = geo.height + 200 + 30
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
        if let tab { model.tab = tab }
        guard !model.expanded else { return }
        model.expanded = true
        panel.ignoresMouseEvents = false
        if model.tab == .mirror { startCamera() }
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
        CameraController.shared.stop()
        if panel.isKeyWindow {
            _ = panel.makeFirstResponder(nil)
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    func tabChanged() {
        if model.expanded && model.tab == .mirror { startCamera() } else { CameraController.shared.stop() }
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            model.cameraDenied = false
            CameraController.shared.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    self.model.cameraDenied = !ok
                    if ok && self.model.expanded && self.model.tab == .mirror { CameraController.shared.start() }
                }
            }
        default:
            model.cameraDenied = true
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
    private var tabObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        controller = NotchController(model: model)
        ClipboardWatcher.shared = ClipboardWatcher(model: model)
        PowerWatcher.shared = PowerWatcher(model: model)
        headphones = HeadphoneWatcher(model: model)
        recording = RecordingWatcher(model: model)
        HotKey.register()
        tabObserver = model.$tab.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.controller.tabChanged() } }
        }
        setupStatusItem()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "RinNotch")
            b.image?.isTemplate = true
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
        controller.tabChanged()
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
