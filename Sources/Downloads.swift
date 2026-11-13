// RinNotch — tiến trình tải về hai bên tai thỏ.
//
// macOS không có API cho app khác xem tiến trình tải lên / tải về của từng app. Cái có sẵn là "tiến trình
// file" mà Finder dùng để vẽ thanh tiến trình trên icon file đang tải: Safari, Chrome (và trình duyệt nhân
// Chromium), AirDrop công bố tiến trình cho file đang ghi trong thư mục Tải về. RinNotch đăng ký nghe
// thư mục đó (NSProgress.addSubscriber), không đọc nội dung file, không cần quyền gì thêm.
// Tải lên (upload) thì không có nguồn chung nào như vậy nên không làm.

import AppKit
import SwiftUI

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

    final class Entry {
        let progress: Progress
        let started = ProcessInfo.processInfo.systemUptime
        var lastBytes: Int64
        var lastAt: TimeInterval
        var speed: Double = 0
        /// Lần cuối số byte thay đổi: đứng yên lâu (tạm dừng tải) thì thôi hiện.
        var lastChange: TimeInterval
        init(_ p: Progress) {
            progress = p
            lastBytes = p.completedUnitCount
            lastAt = ProcessInfo.processInfo.systemUptime
            lastChange = lastAt
        }
        var url: URL? { progress.fileURL }
        var operation: Progress.FileOperationKind? { progress.fileOperationKind }
        var isCopy: Bool { operation == .copying || operation == .duplicating }
        var name: String { DownloadWatcher.displayName(url) }
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
        Diag.log("Tải về \(done ? "xong" : "dừng"): \(e.name)")
        if done, !e.isCopy, let m = model, !m.expanded, m.keyboardLockUntil == nil {
            let title = e.operation == .receiving ? "Đã nhận qua AirDrop" : "Đã tải xong"
            m.showTransient(.message(symbol: "arrow.down.circle.fill", title: title, detail: e.name), seconds: 3)
        }
        if entries.isEmpty {
            setSampler(fast: nil)
            model?.downloads = nil
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
