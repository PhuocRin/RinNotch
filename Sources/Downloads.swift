// RinNotch — tiến trình tải về hai bên tai thỏ.
//
// macOS không có API cho app khác xem tiến trình tải lên / tải về của từng app. Cái có sẵn là "tiến trình
// file" mà Finder dùng để vẽ thanh tiến trình trên icon file đang tải: Safari, Chrome (và trình duyệt nhân
// Chromium), AirDrop công bố tiến trình cho file đang ghi trong thư mục Tải về. RinNotch đăng ký nghe
// thư mục đó (NSProgress.addSubscriber), không đọc nội dung file, không cần quyền gì thêm.
// Tải lên (upload) thì không có nguồn chung nào như vậy nên không làm.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Một file đang tải, hiện thành thẻ ở đầu Kệ file.
struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    var name: String
    var fraction: Double?
    var bytesPerSecond: Double
    /// Giây còn lại (ước theo tốc độ), nil = chưa biết.
    var remaining: Double?
    var cancellable: Bool
    var pausable: Bool
    var paused: Bool
    var copying: Bool
    var receiving: Bool
    var source: DownloadWatcher.Source?
}

struct DownloadSummary: Equatable {
    var count: Int
    /// 0…1; nil = app tải không cho biết tổng dung lượng.
    var fraction: Double?
    var name: String
    var bytesPerSecond: Double
    var copying: Bool
}

@MainActor
final class DownloadWatcher {
    static let shared = DownloadWatcher()
    weak var model: NotchModel?
    private var subscriber: Any?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var sampler: Timer?
    private var samplerFast = false
    /// Đứng yên quá chừng này giây (tạm dừng) thì ẩn khỏi tai thỏ và hỏi thưa lại.
    private static let staleAfter: TimeInterval = 60

    /// App đang tải (đoán theo đuôi file tạm: .download Safari, .crdownload nhân Chromium, .part Firefox).
    struct Source: Equatable {
        let name: String
        let bundleID: String
    }

    final class Entry {
        let id = UUID()
        let progress: Progress
        let started = ProcessInfo.processInfo.systemUptime
        var lastBytes: Int64
        var lastAt: TimeInterval
        var speed: Double = 0
        /// Lần cuối số byte thay đổi: đứng yên lâu (tạm dừng tải) thì thôi hiện.
        var lastChange: TimeInterval
        /// Đường dẫn file nhớ lại từ lúc đang tải: lúc trình duyệt báo xong, tiến trình có khi đã mất đường dẫn.
        var knownURL: URL?
        init(_ p: Progress) {
            progress = p
            lastBytes = p.completedUnitCount
            lastAt = ProcessInfo.processInfo.systemUptime
            lastChange = lastAt
            knownURL = p.fileURL
        }
        var url: URL? { progress.fileURL ?? knownURL }
        var operation: Progress.FileOperationKind? { progress.fileOperationKind }
        var isCopy: Bool { operation == .copying || operation == .duplicating }
        var name: String { DownloadWatcher.displayName(url) }
        lazy var source: Source? = DownloadWatcher.source(for: url)
    }

    func setup(model: NotchModel) {
        self.model = model
        refresh()
    }

    func refresh() {
        if Prefs.showDownloads { start() } else { stop() }
    }

    private func start() {
        guard subscriber == nil,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        // Apple: khối này được gọi trên luồng chính. Vẫn phòng hờ nếu không phải.
        subscriber = Progress.addSubscriber(forFileURL: dir) { progress in
            let box = ProgressBox(progress)
            onMain { DownloadWatcher.shared.began(box.p) }
            return {
                onMain { DownloadWatcher.shared.ended(box.p) }
            }
        }
        Diag.log("Tiến trình tải về: bắt đầu nghe thư mục Tải về")
    }

    private func stop() {
        if let s = subscriber { Progress.removeSubscriber(s) }
        subscriber = nil
        entries.removeAll()
        setSampler(fast: nil)
        model?.downloads = nil
        model?.downloadItems = []
    }

    private func began(_ p: Progress) {
        guard p.kind == nil || p.kind == .file else { return }
        entries[ObjectIdentifier(p)] = Entry(p)
        setSampler(fast: true)
        sample()
    }

    /// Chỉ chạy khi đang có file tải: 0,5 giây khi đang chạy, 5 giây khi mọi file đều đang tạm dừng; hết file là dừng.
    private func setSampler(fast: Bool?) {
        guard let fast else {
            sampler?.invalidate()
            sampler = nil
            return
        }
        if sampler != nil && samplerFast == fast { return }
        sampler?.invalidate()
        let t = Timer(timeInterval: fast ? 0.5 : 5, repeats: true) { _ in
            MainActor.assumeIsolated { DownloadWatcher.shared.sample() }
        }
        t.tolerance = fast ? 0.15 : 1.5
        RunLoop.main.add(t, forMode: .common)
        sampler = t
        samplerFast = fast
    }

    private func ended(_ p: Progress) {
        guard let e = entries.removeValue(forKey: ObjectIdentifier(p)) else { return }
        let done = !p.isCancelled && (p.isFinished || p.fractionCompleted >= 0.995)
        let url = e.url
        Diag.log("Tải về \(done ? "xong" : "dừng"): \(e.name) · \(url?.lastPathComponent ?? "không có đường dẫn")")
        if done, !e.isCopy {
            let title = e.operation == .receiving ? "Đã nhận qua AirDrop" : "Đã tải xong"
            if Prefs.downloadsToShelf {
                // Chỉ báo "đã nằm trên Kệ" khi thật sự thêm được.
                addFinished(url, startedAt: e.started, name: e.name, title: title)
            } else {
                announce(title, e.name)
            }
        }
        if entries.isEmpty {
            setSampler(fast: nil)
            model?.downloads = nil
            model?.downloadItems = []
        } else {
            sample()
        }
    }

    private func sample() {
        guard let m = model else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var done: Int64 = 0, total: Int64 = 0, speed = 0.0
        var known = false
        for e in entries.values {
            let p = e.progress
            if let u = p.fileURL { e.knownURL = u }
            let c = p.completedUnitCount
            let dt = now - e.lastAt
            if c != e.lastBytes { e.lastChange = now }
            // Tạm dừng lâu: không tính vào phần hiện trên tai thỏ.
            if now - e.lastChange > Self.staleAfter { continue }
            if dt >= 0.4 {
                let inst = Double(max(c - e.lastBytes, 0)) / dt
                e.speed = e.speed == 0 ? inst : e.speed * 0.6 + inst * 0.4
                e.lastBytes = c
                e.lastAt = now
            }
            speed += e.speed
            if p.totalUnitCount > 0 {
                known = true
                done += min(c, p.totalUnitCount)
                total += p.totalUnitCount
            }
        }
        let live = entries.values.filter { now - $0.lastChange <= Self.staleAfter }
        // Thẻ ở Kệ file: hiện cả file đang tạm dừng (để bấm Tiếp tục / Huỷ), chỉ ẩn khỏi dạng gọn.
        let items = entries.values.sorted { $0.started < $1.started }.map { e -> DownloadItem in
            let p = e.progress
            let frac: Double? = p.totalUnitCount > 0 ? min(Double(p.completedUnitCount) / Double(p.totalUnitCount), 1) : nil
            var remain: Double?
            if p.totalUnitCount > 0, e.speed > 1_000 {
                let r = Double(p.totalUnitCount - p.completedUnitCount) / e.speed
                remain = (r / 5).rounded(.up) * 5
            }
            return DownloadItem(id: e.id, name: e.name, fraction: frac.map { ($0 * 100).rounded() / 100 },
                                bytesPerSecond: (e.speed / 10_000).rounded() * 10_000, remaining: remain,
                                cancellable: p.isCancellable, pausable: p.isPausable, paused: p.isPaused,
                                copying: e.isCopy, receiving: e.operation == .receiving, source: e.source)
        }
        if m.downloadItems != items { m.downloadItems = items }
        guard let first = live.min(by: { $0.started < $1.started }) else {
            m.downloads = nil
            setSampler(fast: entries.isEmpty ? nil : false)
            return
        }
        setSampler(fast: true)
        let fraction: Double? = known && total > 0 ? Double(done) / Double(total) : nil
        let s = DownloadSummary(count: live.count,
                                fraction: fraction.map { ($0 * 100).rounded() / 100 },
                                name: first.name,
                                bytesPerSecond: (speed / 10_000).rounded() * 10_000,
                                copying: live.allSatisfy(\.isCopy))
        if m.downloads != s { m.downloads = s }
    }

    // MARK: Thao tác trên thẻ

    private func entry(_ id: UUID) -> Entry? { entries.values.first { $0.id == id } }

    /// Huỷ tải: gửi yêu cầu huỷ cho app đang tải (Chrome, Safari cho phép; app nào không cho thì nút không hiện).
    func cancel(_ id: UUID) {
        guard let e = entry(id), e.progress.isCancellable else { return }
        e.progress.cancel()
        Diag.log("Tải về: huỷ \(e.name)")
    }

    func togglePause(_ id: UUID) {
        guard let e = entry(id), e.progress.isPausable else { return }
        if e.progress.isPaused { e.progress.resume() } else { e.progress.pause() }
        sample()
    }

    /// Mở app đang tải (đưa lên trước).
    func openSource(_ id: UUID) {
        guard let s = entry(id)?.source else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func reveal(_ id: UUID) {
        guard let u = entry(id)?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    /// Đoán app đang tải theo đuôi file tạm.
    nonisolated static func source(for url: URL?) -> Source? {
        guard let name = url?.lastPathComponent.lowercased() else { return nil }
        func running(_ ids: [(String, String)]) -> Source? {
            for (bid, title) in ids where !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                return Source(name: title, bundleID: bid)
            }
            return nil
        }
        if name.hasSuffix(".download") {
            return running([("com.apple.SafariTechnologyPreview", "Safari Technology Preview")])
                ?? Source(name: "Safari", bundleID: "com.apple.Safari")
        }
        if name.hasSuffix(".crdownload") {
            return running([("com.google.Chrome", "Chrome"), ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"),
                            ("company.thebrowser.Browser", "Arc"), ("com.vivaldi.Vivaldi", "Vivaldi"),
                            ("com.operasoftware.Opera", "Opera"), ("org.chromium.Chromium", "Chromium"),
                            ("com.google.Chrome.canary", "Chrome Canary")])
                ?? Source(name: "Chrome", bundleID: "com.google.Chrome")
        }
        if name.hasSuffix(".part") {
            return Source(name: "Firefox", bundleID: "org.mozilla.firefox")
        }
        return nil
    }

    // MARK: Tải xong → lên Kệ file

    /// Tìm file thật sau khi tải xong (trình duyệt đổi tên file tạm thành tên thật) rồi thêm vào Kệ.
    /// Trình duyệt đổi tên có khi trễ một chút nên thử lại vài lần.
    private func announce(_ title: String, _ detail: String) {
        guard let m = model, !m.expanded, m.keyboardLockUntil == nil else { return }
        m.showTransient(.message(symbol: "arrow.down.circle.fill", title: title, detail: detail), seconds: 3)
    }

    private func addFinished(_ url: URL?, startedAt: TimeInterval, name: String, title: String, attempt: Int = 0) {
        guard let m = model else { return }
        let since = Date().addingTimeInterval(-(ProcessInfo.processInfo.systemUptime - startedAt) - 5)
        if let f = Self.finalFile(for: url, since: since) {
            m.addToShelf([f])
            m.trimShelfAfterDownload()
            Diag.log("Tải về: đã thêm \(f.lastPathComponent) vào Kệ")
            announce(title, "\(f.lastPathComponent) · đã nằm trên Kệ file")
            return
        }
        guard attempt < 4 else {
            // Không tìm ra file: thường là RinNotch chưa có quyền vào thư mục Tải về.
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            let readable = dir.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil } ?? false
            Diag.log("Tải về: không tìm được file để thêm vào Kệ (đọc thư mục Tải về: \(readable ? "được" : "không được"))")
            announce(title, readable ? name : "\(name) · cho RinNotch quyền thư mục Tải về để tự thêm vào Kệ")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + [0.4, 1.0, 2.0, 4.0][attempt]) {
            MainActor.assumeIsolated {
                DownloadWatcher.shared.addFinished(url, startedAt: startedAt, name: name, title: title, attempt: attempt + 1)
            }
        }
    }

    private static let tempExts = [".download", ".crdownload", ".part"]

    private static func finalFile(for url: URL?, since: Date) -> URL? {
        let fm = FileManager.default
        if let url {
            let name = url.lastPathComponent
            let dir = url.deletingLastPathComponent()
            for ext in tempExts where name.lowercased().hasSuffix(ext) {
                let cand = dir.appendingPathComponent(String(name.dropLast(ext.count)))
                if fm.fileExists(atPath: cand.path) { return cand }
            }
            if !tempExts.contains(where: { name.lowercased().hasSuffix($0) }), fm.fileExists(atPath: url.path) { return url }
        }
        // Không rõ tên (Chrome "Unconfirmed 12345.crdownload", hoặc trình duyệt bỏ đường dẫn khi xong):
        // lấy file vừa xuất hiện mới nhất trong thư mục (ngày thêm vào thư mục, không dựa ngày sửa của máy chủ).
        guard let dir = url?.deletingLastPathComponent()
                ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        func stamp(_ f: URL) -> Date {
            let v = try? f.resourceValues(forKeys: Set(keys))
            return [v?.addedToDirectoryDate, v?.creationDate, v?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let fresh = files.filter { f in
            !tempExts.contains(where: { f.lastPathComponent.lowercased().hasSuffix($0) }) && stamp(f) >= since
        }
        return fresh.max { stamp($0) < stamp($1) }
    }

    static func remainingText(_ s: Double) -> String {
        if s < 60 { return "còn \(Int(s)) giây" }
        if s < 3600 { return "còn \(Int((s / 60).rounded(.up))) phút" }
        let h = Int(s / 3600), mm = Int((s.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        return mm > 0 ? "còn \(h) giờ \(mm) phút" : "còn \(h) giờ"
    }

    /// Tên file bỏ đuôi tạm của trình duyệt (.download của Safari, .crdownload của Chrome, .part).
    nonisolated static func displayName(_ url: URL?) -> String {
        guard let url else { return "File" }
        var name = url.lastPathComponent
        for ext in [".download", ".crdownload", ".part"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name.isEmpty ? "File" : name
    }

    static func speedText(_ bps: Double) -> String {
        guard bps > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(bps)) + "/s"
    }
}

private final class ProgressBox: @unchecked Sendable {
    let p: Progress
    init(_ p: Progress) { self.p = p }
}

private func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

/// Vòng tiến trình nhỏ cho dạng gọn.
struct ProgressRing: View {
    let fraction: Double?
    var tint: Color = .blue
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(max(f, 0.02)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.45), value: f)
            } else {
                // Không biết tổng dung lượng: một cung nhỏ quay vòng.
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .frame(width: 16, height: 16)
    }
}


// MARK: - Thẻ đang tải ở Kệ file

struct DownloadCard: View {
    let item: DownloadItem
    var w: CGFloat = ShelfItem.width
    var h: CGFloat = ShelfItem.height
    @State private var hovered = false

    private var icon: NSImage {
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private var detail: String {
        var parts: [String] = []
        if let f = item.fraction { parts.append("\(Int(f * 100))%") }
        if item.paused { parts.append("Tạm dừng") }
        else {
            if item.bytesPerSecond > 0 { parts.append(DownloadWatcher.speedText(item.bytesPerSecond)) }
            if let r = item.remaining { parts.append(DownloadWatcher.remainingText(r)) }
        }
        return parts.isEmpty ? (item.copying ? "Đang chép" : "Đang tải") : parts.joined(separator: " · ")
    }

    private var title: String {
        if item.receiving { return "AirDrop" }
        if item.copying { return "Đang chép" }
        return item.source.map { "Tải bằng \($0.name)" } ?? "Đang tải"
    }

    var body: some View {
        Button { DownloadWatcher.shared.openSource(item.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.blue.opacity(0.95))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(item.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                DownloadBar(fraction: item.fraction, paused: item.paused)
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(10)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.blue.opacity(hovered ? 0.2 : 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.blue.opacity(hovered ? 0.6 : 0.35), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if hovered {
                    HStack(spacing: 4) {
                        if item.pausable {
                            cardButton(item.paused ? "play.fill" : "pause.fill", help: item.paused ? "Tiếp tục" : "Tạm dừng") {
                                DownloadWatcher.shared.togglePause(item.id)
                            }
                        }
                        if item.cancellable {
                            cardButton("xmark", help: "Huỷ tải") { DownloadWatcher.shared.cancel(item.id) }
                        }
                    }
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topTrailing)))
                }
            }
            .scaleEffect(hovered ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .help(item.source.map { "Bấm để mở \($0.name)" } ?? item.name)
        .contextMenu {
            if let s = item.source { Button("Mở \(s.name)") { DownloadWatcher.shared.openSource(item.id) } }
            Button("Hiện trong Finder") { DownloadWatcher.shared.reveal(item.id) }
            if item.pausable {
                Button(item.paused ? "Tiếp tục tải" : "Tạm dừng") { DownloadWatcher.shared.togglePause(item.id) }
            }
            if item.cancellable {
                Divider()
                Button("Huỷ tải") { DownloadWatcher.shared.cancel(item.id) }
            }
        }
        .onHover { inside in withAnimation(HoverAnim.bounce) { hovered = inside } }
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(HoverPlain(scale: 1.18))
        .help(help)
    }
}

/// Thanh tiến trình: biết tổng thì chạy theo %, không biết thì một vệt sáng chạy qua lại.
struct DownloadBar: View {
    let fraction: Double?
    var paused = false
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                if let f = fraction {
                    Capsule()
                        .fill(LinearGradient(colors: paused ? [.gray, .gray.opacity(0.7)] : [Color.blue, Color.cyan],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(g.size.width * CGFloat(f), 5))
                        .animation(.easeOut(duration: 0.45), value: f)
                } else {
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: g.size.width * 0.3)
                        .offset(x: sweep ? g.size.width * 0.7 : 0)
                        .animation(paused ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: 5)
    }
}
