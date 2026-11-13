// RinNotch — Bộ nhớ tạm riêng tư: kéo thẻ vào chip "Riêng tư" (hoặc chuột phải → Chuyển vào Riêng tư) để cất.
// Chưa mở khoá thì mục Riêng tư chỉ hiện các thẻ mờ + nút "Mở khoá bằng vân tay" (Touch ID; máy không có
// Touch ID thì dùng mật khẩu máy). Mở xong tự khoá lại sau 3 phút, khi máy ngủ / khoá màn hình, hoặc bấm Khoá.
//
// Dữ liệu: mã hoá AES-GCM (CryptoKit) trong ~/Library/Application Support/RinNotch/Clipboard/private.vault.
// Khoá mã hoá (32 byte ngẫu nhiên) nằm trong Keychain của máy, chỉ thiết bị này, chỉ khi máy đang mở khoá.
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
    private var observers: [NSObjectProtocol] = []

    static let autoLockMinutes: Double = 3
    private static let service = "com.phuocrin.rinnotch.private"
    private static let account = "vault-key"
    private static var file: URL { ClipStore.dir.appendingPathComponent("private.vault") }

    func setup(model: NotchModel) {
        self.model = model
        model.privateCount = UserDefaults.standard.integer(forKey: "privateCount")
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
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            m.privateStatus = "Máy chưa đặt mật khẩu đăng nhập nên không khoá được"
            return
        }
        m.privateStatus = nil
        // Có Touch ID thì hỏi vân tay, không có (hoặc không đọc được) thì macOS cho nhập mật khẩu máy.
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "mở Bộ nhớ tạm riêng tư") { ok, error in
            let cancelled = (error as? LAError).map { $0.code == .userCancel || $0.code == .appCancel || $0.code == .systemCancel } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { PrivateVault.shared.didUnlock() }
                    else if !cancelled { PrivateVault.shared.model?.privateStatus = "Chưa mở được, thử lại nha" }
                }
            }
        }
    }

    private func didUnlock() {
        guard let m = model else { return }
        guard let list = load() else {
            m.privateStatus = "Không đọc được dữ liệu riêng tư (khoá trong Keychain không khớp)"
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            m.privateClips = list
            m.privateUnlocked = true
        }
        setCount(list.count)
        scheduleLock()
        Diag.log("Riêng tư: mở khoá")
    }

    func lock() {
        lockWork?.cancel()
        guard let m = model, m.privateUnlocked else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            m.privateUnlocked = false
            m.privateClips = []
        }
        if m.clipFilter == .vault { m.clipSelection = nil }
    }

    /// Đang dùng (chép, cất thêm) thì dời giờ tự khoá.
    private func scheduleLock() {
        lockWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { PrivateVault.shared.lock() } }
        lockWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoLockMinutes * 60, execute: w)
    }

    // MARK: Cất / lấy ra

    /// Cất một mục vào Riêng tư (không cần mở khoá: giống bỏ thư vào hộp có khoá). Mục rời lịch sử và ghim.
    func add(_ item: ClipItem) {
        guard let m = model else { return }
        guard var list = m.privateUnlocked ? m.privateClips : load() else {
            m.privateStatus = "Không cất được: dữ liệu riêng tư đọc không được"
            return
        }
        list.removeAll { $0.id == item.id || $0.sameContent(item) }
        list.insert(item, at: 0)
        guard save(list) else {
            m.privateStatus = "Không cất được vào Riêng tư"
            return
        }
        ClipboardWatcher.shared?.remove(item)
        if m.privateUnlocked {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips = list }
            scheduleLock()
        }
        setCount(list.count)
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
        var list = m.privateClips
        list.removeAll { $0.id == item.id }
        guard save(list) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips = list }
        setCount(list.count)
        ClipboardWatcher.shared?.reinsert(item)
        scheduleLock()
    }

    func delete(_ item: ClipItem) {
        guard let m = model, m.privateUnlocked else { return }
        var list = m.privateClips
        list.removeAll { $0.id == item.id }
        guard save(list) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { m.privateClips = list }
        setCount(list.count)
        scheduleLock()
    }

    /// Chép mục riêng tư: gắn cờ "bí mật" để không app nào (kể cả RinNotch) ghi vào lịch sử.
    func copy(_ item: ClipItem) {
        guard let m = model, m.privateUnlocked else { return }
        ClipboardWatcher.shared?.writeQuietly(item, concealed: true)
        m.clipFlash = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                if PrivateVault.shared.model?.clipFlash == item.id { PrivateVault.shared.model?.clipFlash = nil }
            }
        }
        scheduleLock()
    }

    private func setCount(_ n: Int) {
        model?.privateCount = n
        UserDefaults.standard.set(n, forKey: "privateCount")
    }

    // MARK: Lưu trữ mã hoá

    /// nil = có file mà đọc / giải mã không được (không được ghi đè).
    private func load() -> [ClipItem]? {
        guard let sealed = try? Data(contentsOf: Self.file) else { return [] }
        guard let key = Self.key(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let list = try? JSONDecoder().decode([StoredClip].self, from: plain) else { return nil }
        return list.compactMap { ClipStore.decode($0) }
    }

    private func save(_ list: [ClipItem]) -> Bool {
        guard let key = Self.key(create: true) else { return false }
        let stored = list.compactMap { ClipStore.encode($0, inlineImage: true) }
        guard let plain = try? JSONEncoder().encode(stored),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return false }
        try? FileManager.default.createDirectory(at: ClipStore.dir, withIntermediateDirectories: true)
        guard (try? sealed.write(to: Self.file, options: .atomic)) != nil else { return false }
        // Chỉ chủ máy đọc được file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        return true
    }

    private static func key(create: Bool) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            return SymmetricKey(data: d)
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "RinNotch – Bộ nhớ tạm riêng tư",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecDuplicateItem { return nil }   // có khoá nhưng đọc không được: không tạo khoá mới đè dữ liệu cũ
        return st == errSecSuccess ? SymmetricKey(data: data) : nil
    }
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
