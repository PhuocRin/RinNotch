// RinNotch — Bộ nhớ tạm riêng tư: kéo thẻ vào chip "Riêng tư" (hoặc chuột phải → Chuyển vào Riêng tư) để cất.
// Chưa mở khoá thì mục Riêng tư chỉ hiện các thẻ mờ + nút "Mở khoá bằng vân tay" (Touch ID; máy không có
// Touch ID thì dùng mật khẩu máy). Mở xong tự khoá lại sau 3 phút, khi máy ngủ / khoá màn hình, hoặc bấm Khoá.
//
// Dữ liệu: mỗi mục một file mã hoá AES-GCM trong ~/Library/Application Support/RinNotch/Clipboard/private/,
// khoá đọc nằm trong chip bảo mật (Secure Enclave) của Mac, chỉ dùng được sau vân tay / mật khẩu máy (xem phần Lưu trữ).
// Mục riêng tư không nằm trong lịch sử, ô tìm "Tất cả", sao lưu, viên "Đã chép"; chép ra thì gắn cờ
// ConcealedType để trình quản lý bộ nhớ tạm khác (và chính RinNotch) không ghi lại.

import AppKit
import SwiftUI
import LocalAuthentication
import CryptoKit
import Security
import UniformTypeIdentifiers

extension UTType {
    /// Kéo thẻ Bộ nhớ tạm trong RinNotch (khai báo trong Info.plist).
    static let rinClip = UTType(exportedAs: "com.phuocrin.rinnotch.clip")
}

@MainActor
final class PrivateVault {
    static let shared = PrivateVault()
    weak var model: NotchModel?
    private var lockWork: DispatchWorkItem?
    private var statusWork: DispatchWorkItem?
    /// Số đếm bộ nhớ tạm lúc vừa chép một mục riêng tư: khoá lại mà bộ nhớ tạm vẫn là mục đó thì xoá đi.
    private var copiedChangeCount: Int?
    private var observers: [NSObjectProtocol] = []

    static let autoLockMinutes: Double = 3

    func setup(model: NotchModel) {
        self.model = model
        // Bản thử 41–42 cất trong Keychain (bị hỏi mật khẩu chuỗi khoá): để riêng file cũ, không đọc nữa.
        let old = ClipStore.dir.appendingPathComponent("private.vault")
        if FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: ClipStore.dir.appendingPathComponent("private-old-keychain.vault"))
        }
        refreshCount()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PrivateVault.shared.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PrivateVault.shared.lock() }
        })
    }

    // MARK: Mở / khoá

    func unlock() {
        guard let m = model, !m.privateUnlocked else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Dùng mật khẩu máy"
        // Vân tay vừa quét xong thì dùng luôn cho khoá trong chip bảo mật, không hỏi lần hai.
        ctx.touchIDAuthenticationAllowableReuseDuration = 30
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            setStatus("Máy chưa đặt mật khẩu đăng nhập nên không khoá được")
            return
        }
        m.privateStatus = nil
        // Chỉ một bước: vân tay (Touch ID), không có hoặc không đọc được thì mật khẩu máy. Không đụng tới Keychain.
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "mở Bộ nhớ tạm riêng tư") { ok, error in
            let cancelled = (error as? LAError).map { $0.code == .userCancel || $0.code == .appCancel || $0.code == .systemCancel } ?? false
            let box = ContextBox(ctx)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { PrivateVault.shared.didUnlock(box.ctx) }
                    else if !cancelled { PrivateVault.shared.setStatus("Chưa mở được, thử lại nha") }
                }
            }
        }
    }

    /// Dòng báo dưới ổ khoá, tự tắt sau vài giây.
    func setStatus(_ text: String) {
        model?.privateStatus = text
        statusWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { PrivateVault.shared.model?.privateStatus = nil } }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    private func didUnlock(_ ctx: LAContext) {
        // Giải mã ở luồng nền (mỗi mục một phép tính trong chip bảo mật), xong mới đưa lên giao diện.
        let meta = Self.meta()
        let files = Self.itemFiles()
        let box = ContextBox(ctx)
        DispatchQueue.global(qos: .userInitiated).async {
            let (plains, failed) = PrivateVault.decryptAll(box.ctx, meta: meta, files: files)
            let out = PlainBox(plains)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PrivateVault.shared.finishUnlock(out.v, failed: failed) }
            }
        }
    }

    private func finishUnlock(_ plains: [Data], failed: Int) {
        guard let m = model else { return }
        var bad = failed
        var list: [ClipItem] = []
        for d in plains {
            if let stored = try? JSONDecoder().decode(StoredClip.self, from: d), let item = ClipStore.decode(stored) {
                list.append(item)
            } else {
                bad += 1
            }
        }
        list.sort { $0.date > $1.date }
        // Lúc đang khoá không đọc được bên trong nên cất trùng thì thành 2 bản: mở khoá thì gộp lại, giữ bản mới nhất.
        var kept: [ClipItem] = []
        for item in list {
            if kept.contains(where: { $0.sameContent(item) }) { Self.removeFile(item.id) } else { kept.append(item) }
        }
        list = kept
        if bad > 0 { setStatus("Có \(bad) mục không giải mã được") }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            m.privateClips = list
            m.privateUnlocked = true
        }
        refreshCount()
        scheduleLock()
        Diag.log("Riêng tư: mở khoá (\(Self.meta()?.mode ?? "chưa có"))")
    }

    func lock() {
        lockWork?.cancel()
        guard let m = model, m.privateUnlocked else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            m.privateUnlocked = false
            m.privateClips = []
        }
        if m.clipFilter == .vault { m.clipSelection = nil }
        m.privateStatus = nil
        // Mục riêng tư vừa chép mà vẫn nằm trong bộ nhớ tạm thì xoá đi, khoá rồi không dán ra được nữa.
        let pb = NSPasteboard.general
        if let c = copiedChangeCount, pb.changeCount == c {
            pb.clearContents()
            ClipboardWatcher.shared?.ignore(pb.changeCount)
        }
        copiedChangeCount = nil
    }

    /// Đang dùng (chép, cất thêm) thì dời giờ tự khoá.
    private func scheduleLock() {
        lockWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { PrivateVault.shared.lock() } }
        lockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoLockMinutes * 60, execute: w)
    }

    // MARK: Cất / lấy ra

    /// Cất một mục vào Riêng tư (không cần mở khoá: mã hoá bằng khoá công khai, giống bỏ thư vào hộp có khoá).
    /// Mục rời lịch sử và ghim.
    func add(_ item: ClipItem) {
        guard let m = model else { return }
        if m.privateUnlocked, let dup = m.privateClips.first(where: { $0.sameContent(item) }) {
            Self.removeFile(dup.id)
            m.privateClips.removeAll { $0.id == dup.id }
        }
        guard Self.write(item) else {
            setStatus("Không cất được vào Riêng tư")
            return
        }
        // Xoá mọi bản cùng nội dung ở lịch sử và Ghim (ghim lưu ra ổ dạng chữ thường), kể cả bản có mã khác.
        ClipboardWatcher.shared?.purge(item)
        CopyToast.shared.hide()
        if m.privateUnlocked {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips.insert(item, at: 0) }
            scheduleLock()
        }
        refreshCount()
        m.privateFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { PrivateVault.shared.model?.privateFlash = false }
        }
        Diag.log("Riêng tư: cất 1 mục")
    }

    func add(id: UUID) {
        guard let m = model, let item = (m.clips + m.pins).first(where: { $0.id == id }) else { return }
        add(item)
    }

    /// Đưa ra lại Bộ nhớ tạm thường.
    func moveOut(_ item: ClipItem) {
        guard let m = model, m.privateUnlocked else { return }
        Self.removeFile(item.id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips.removeAll { $0.id == item.id } }
        refreshCount()
        ClipboardWatcher.shared?.reinsert(item)
        scheduleLock()
    }

    func delete(_ item: ClipItem) {
        guard let m = model, m.privateUnlocked else { return }
        Self.removeFile(item.id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips.removeAll { $0.id == item.id } }
        refreshCount()
        scheduleLock()
    }

    /// Chép một mục dựng tạm từ các mục riêng tư (chép gộp): vẫn gắn cờ "bí mật", không ghi vào lịch sử.
    func copyRaw(_ item: ClipItem) {
        guard model?.privateUnlocked == true else { return }
        ClipboardWatcher.shared?.writeQuietly(item, concealed: true)
        copiedChangeCount = NSPasteboard.general.changeCount
        scheduleLock()
    }

    /// Chép mục riêng tư: gắn cờ "bí mật" để không app nào (kể cả RinNotch) ghi vào lịch sử.
    func copy(_ item: ClipItem) {
        guard let m = model, m.privateUnlocked else { return }
        ClipboardWatcher.shared?.writeQuietly(item, concealed: true)
        copiedChangeCount = NSPasteboard.general.changeCount
        m.clipFlash = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                if PrivateVault.shared.model?.clipFlash == item.id { PrivateVault.shared.model?.clipFlash = nil }
            }
        }
        scheduleLock()
    }

    private func refreshCount() {
        model?.privateCount = Self.itemFiles().count
    }

    // MARK: Lưu trữ mã hoá
    //
    // Thư mục ~/Library/Application Support/RinNotch/Clipboard/private/:
    //   vault.json  : cách khoá. "se" = khoá riêng nằm trong chip bảo mật Secure Enclave của Mac (Apple silicon, Mac có
    //                 T2), chỉ dùng được sau khi quét vân tay / nhập mật khẩu máy; file chỉ giữ bản bọc của khoá + khoá
    //                 công khai. "file" = Mac không có chip bảo mật: khoá ngẫu nhiên nằm trong file (chỉ chủ máy đọc).
    //   items/<id>.box : mỗi mục một file, mã hoá AES-GCM. Kiểu "se": khoá của từng mục sinh từ khoá công khai (ECIES),
    //                 nên cất thêm lúc đang khoá không cần mở; đọc ra mới cần khoá riêng trong chip.
    // Không dùng Keychain: bản build mới bị macOS coi là app khác nên đòi mật khẩu chuỗi khoá (Phước báo 13/11).

    private struct Meta: Codable {
        var mode: String
        var seKey: Data?
        var publicKey: Data?
        var fileKey: Data?
    }

    private struct Record: Codable {
        var epk: Data?
        var box: Data
    }

    private static var dir: URL { ClipStore.dir.appendingPathComponent("private", isDirectory: true) }
    private static var itemsDir: URL { dir.appendingPathComponent("items", isDirectory: true) }
    private static var metaFile: URL { dir.appendingPathComponent("vault.json") }
    nonisolated private static let info = Data("RinNotch private clipboard".utf8)

    private static func meta() -> Meta? {
        guard let d = try? Data(contentsOf: metaFile) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    private static func secure(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Tạo két lần đầu: ưu tiên chip bảo mật, không có thì khoá trong file.
    private static func ensureMeta() -> Meta? {
        if let m = meta() { return m }
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var m: Meta?
        if SecureEnclave.isAvailable,
           let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) {
            do {
                let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false, accessControl: ac)
                m = Meta(mode: "se", seKey: k.dataRepresentation, publicKey: k.publicKey.x963Representation)
            } catch {
                Diag.log("Riêng tư: không tạo được khoá trong chip bảo mật (\(error)), dùng khoá trong file")
            }
        }
        if m == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            m = Meta(mode: "file", fileKey: Data(bytes))
        }
        guard let m, let d = try? JSONEncoder().encode(m), (try? d.write(to: metaFile, options: .atomic)) != nil else { return nil }
        secure(metaFile)
        if m.mode == "file" {
            // Kiểu "file" thì khoá nằm trong vault.json: không cho Time Machine sao lưu kèm dữ liệu.
            var url = metaFile
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? url.setResourceValues(v)
        }
        return m
    }

    private static func itemFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "box" }
    }

    private static func removeFile(_ id: UUID) {
        try? FileManager.default.removeItem(at: itemsDir.appendingPathComponent(id.uuidString + ".box"))
    }

    private static func write(_ item: ClipItem) -> Bool {
        guard let m = ensureMeta(), let stored = ClipStore.encode(item, inlineImage: true),
              let plain = try? JSONEncoder().encode(stored) else { return false }
        var rec: Record
        do {
            if m.mode == "se" {
                guard let pubData = m.publicKey else { return false }
                let pub = try P256.KeyAgreement.PublicKey(x963Representation: pubData)
                let eph = P256.KeyAgreement.PrivateKey()
                let shared = try eph.sharedSecretFromKeyAgreement(with: pub)
                let epk = eph.publicKey.x963Representation
                let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk, sharedInfo: info, outputByteCount: 32)
                guard let box = try AES.GCM.seal(plain, using: key).combined else { return false }
                rec = Record(epk: epk, box: box)
            } else {
                guard let fk = m.fileKey, let box = try AES.GCM.seal(plain, using: SymmetricKey(data: fk)).combined else { return false }
                rec = Record(epk: nil, box: box)
            }
        } catch {
            Diag.log("Riêng tư: mã hoá lỗi \(error)")
            return false
        }
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        let url = itemsDir.appendingPathComponent(item.id.uuidString + ".box")
        guard let d = try? JSONEncoder().encode(rec), (try? d.write(to: url, options: .atomic)) != nil else { return false }
        secure(url)
        return true
    }

    /// Giải mã mọi mục bằng phiên vân tay vừa xác thực (chạy ở luồng nền). Trả về dữ liệu đã giải mã + số mục hỏng.
    nonisolated private static func decryptAll(_ ctx: LAContext, meta: Meta?, files: [URL]) -> ([Data], Int) {
        guard let m = meta else { return ([], 0) }
        var sePriv: SecureEnclave.P256.KeyAgreement.PrivateKey?
        if m.mode == "se" {
            guard let kd = m.seKey,
                  let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: kd, authenticationContext: ctx) else {
                return ([], files.count)
            }
            sePriv = k
        }
        var out: [Data] = []
        var failed = 0
        for url in files {
            guard let d = try? Data(contentsOf: url), let rec = try? JSONDecoder().decode(Record.self, from: d) else { failed += 1; continue }
            var key: SymmetricKey?
            if let sePriv, let epk = rec.epk,
               let pub = try? P256.KeyAgreement.PublicKey(x963Representation: epk),
               let shared = try? sePriv.sharedSecretFromKeyAgreement(with: pub) {
                key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk, sharedInfo: info, outputByteCount: 32)
            } else if let fk = m.fileKey {
                key = SymmetricKey(data: fk)
            }
            guard let key, let box = try? AES.GCM.SealedBox(combined: rec.box), let plain = try? AES.GCM.open(box, using: key) else {
                failed += 1
                continue
            }
            out.append(plain)
        }
        return (out, failed)
    }
}

private final class PlainBox: @unchecked Sendable {
    let v: [Data]
    init(_ v: [Data]) { self.v = v }
}

private final class ContextBox: @unchecked Sendable {
    let ctx: LAContext
    init(_ c: LAContext) { ctx = c }
}

// MARK: - Giao diện

/// Mục Riêng tư khi đang khoá: các thẻ mờ phía sau + ổ khoá và nút mở bằng vân tay.
struct VaultLockedView: View {
    @ObservedObject var m: NotchModel
    var cardW: CGFloat = ClipCard.width
    var cardH: CGFloat = ClipCard.height
    var large = false
    @State private var shimmer = false

    var body: some View {
        ZStack {
            // Thẻ giả, làm mờ: chỉ để nhìn ra "có đồ bên trong", không vẽ nội dung thật nào.
            HStack(spacing: 10) {
                ForEach(0..<(large ? 6 : 4), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [Self.palette[i % Self.palette.count].opacity(0.55), Color.white.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(0..<3, id: \.self) { l in
                                    Capsule().fill(Color.white.opacity(0.35)).frame(width: cardW * (l == 2 ? 0.35 : 0.65), height: 7)
                                }
                            }
                            .padding(12)
                        }
                        .frame(width: cardW, height: cardH)
                }
            }
            .blur(radius: 9)
            .opacity(m.privateCount == 0 ? 0.35 : 0.8)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: large ? 26 : 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(shimmer ? 1.06 : 1)
                Text(m.privateCount == 0 ? "Riêng tư đang trống" : "\(m.privateCount) mục riêng tư đang khoá")
                    .font(.system(size: 12.5, weight: .semibold))
                if let s = m.privateStatus {
                    Text(s).font(.system(size: 10.5)).foregroundStyle(Color.orange).lineLimit(2).multilineTextAlignment(.center)
                } else if m.privateCount == 0 {
                    Text("Kéo thẻ thả vào nút Riêng tư, hoặc chuột phải thẻ → Chuyển vào Riêng tư")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                }
                if m.privateCount > 0 {
                    Button { PrivateVault.shared.unlock() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid").font(.system(size: 14, weight: .semibold))
                            Text("Mở khoá bằng vân tay")
                        }
                    }
                    .buttonStyle(PillButton(prominent: true))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .environment(\.colorScheme, .dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatCount(2, autoreverses: true)) { shimmer = true }
        }
    }

    private static let palette: [Color] = [.blue, .pink, .orange, .green, .purple, .teal]
}

/// Nút khoá lại ngay (hiện khi Riêng tư đang mở).
struct VaultLockButton: View {
    var body: some View {
        Button { PrivateVault.shared.lock() } label: {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                Text("Khoá").font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverPlain())
        .help("Khoá Riêng tư ngay (tự khoá sau \(Int(PrivateVault.autoLockMinutes)) phút)")
    }
}

extension View {
    /// Cho kéo thẻ Bộ nhớ tạm: trong RinNotch mang mã thẻ (thả vào Riêng tư), ra app khác thì mang chữ.
    func clipDrag(_ item: ClipItem) -> some View {
        onDrag {
            let p = NSItemProvider()
            let id = item.id.uuidString
            p.registerDataRepresentation(forTypeIdentifier: UTType.rinClip.identifier, visibility: .ownProcess) { done in
                done(id.data(using: .utf8), nil)
                return nil
            }
            if let t = item.text { p.registerObject(t as NSString, visibility: .all) }
            return p
        }
    }
}
