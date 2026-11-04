# RinNotch

Biến tai thỏ MacBook thành khu tiện ích nhỏ, bung ra mượt khi rê chuột lên.

Trang tải và hướng dẫn cài có hình: https://phuocrin.com/rinnotch/

## Tính năng

- **Nhạc / video**: ảnh bìa, tên bài, thanh thời lượng (bấm để tua), lùi / phát / tới. Đang phát thì hai bên tai thỏ hiện ảnh bìa và cột nhạc. App "Đang phát" của macOS bị dừng mà Apple Music hay Spotify vẫn chạy thì tự chuyển qua bài đó.
- **Kệ file**: kéo file thả lên tai thỏ để giữ tạm, có ảnh xem trước. Kéo chuột trên chỗ trống để chọn nhiều file, ⌘/⇧ + bấm để chọn thêm, rồi kéo cả nhóm ra cùng lúc. Kéo ra = sao chép, giữ ⌘ khi kéo = chuyển file. Chuột phải: Mở, AirDrop, Sao chép, Hiện trong Finder, Chọn tất cả.
- **Bộ nhớ tạm**: 20 mục gần nhất, bấm để copy lại. Chỉ giữ trong máy, bỏ qua mật khẩu.
- **Ghi chú nhanh**: Enter xuống dòng, ⌘ Enter lưu vào app Notes (thư mục RinNotch).
- **Hẹn giờ**: bấm giờ từ 00:00:00 hoặc đếm ngược 1 phút tới 1 giờ, hết giờ có chuông.
- **Hệ thống**: CPU, RAM, tốc độ mạng, mức nhiệt (chỉ đo khi mở mục này).
- **Thông báo thả xuống**: tai nghe kết nối (kèm % pin AirPods, icon đúng mẫu), cắm / rút sạc, pin yếu 20% và 10%.
- **Ghi âm**: app nào đang dùng micro thì hiện icon app, thời gian cộng dồn qua các lần tạm dừng và sóng âm.
- **Cài đặt**: bật / tắt từng loại hiển thị, chọn mục mở khi rê chuột, mở cùng máy. ⌥⌘N ẩn / hiện, Esc thu lại.
- **Mẹo dùng**: tự mở một lần khi cài, mở lại từ thanh menu → Mẹo dùng hoặc nút ? trên tai thỏ (mở đúng mục đang xem).
- Tự cập nhật (gói cập nhật được ký số, kiểm tra trước khi cài), Báo lỗi kèm nhật ký, Ủng hộ tác giả.

Cần macOS 14 trở lên, Mac chip Apple và Intel. Máy không có tai thỏ vẫn dùng được: rê chuột lên giữa cạnh trên màn hình.

## Cài đặt

1. Tải `RinNotch.dmg` ở [Releases](https://github.com/PhuocRin/RinNotch/releases/latest), mở ra, kéo RinNotch vào Applications.
2. Lần đầu mở bị chặn (app chưa được Apple công chứng): bấm **Xong** (đừng bấm Chuyển vào Thùng rác) → Cài đặt → Quyền riêng tư & Bảo mật → kéo xuống phần **Bảo mật** → **Vẫn mở** → xác nhận.
3. macOS chỉ hỏi quyền khi bạn dùng tới: Micro (sóng âm), Notes (ghi chú), Music / Spotify (nhạc), Bluetooth (pin AirPods).

## RinNotch có an toàn không?

- Không chụp màn hình, không ghi bàn phím (chỉ nghe đúng phím tắt ⌥⌘N).
- Micro chỉ dùng để vẽ sóng âm khi app khác đang ghi âm; không lưu, không gửi âm thanh.
- Kết nối mạng: hỏi GitHub có bản mới và tải bản mới; tải ảnh bìa từ máy chủ ảnh của Spotify khi nghe Spotify.
- Phần đọc bài đang phát chạy qua `/usr/bin/perl` của macOS (`Helper/rinmedia.m`). Đây là cách cộng đồng tìm ra sau khi macOS 15.4 chặn app bên thứ ba đọc thẳng; RinNotch tự viết phần này. Apple có thể chặn cách này ở bản macOS sau.

## Tác giả

Làm bởi Phước Rin: [YouTube](https://youtube.com/@phuocrin) · [TikTok](https://www.tiktok.com/@phuocrinrin) · [Facebook](https://www.facebook.com/phuocrinrin) · [phuocrin.com](https://phuocrin.com)

Miễn phí, mã nguồn mở (MIT).

---

## English

RinNotch turns the MacBook notch into a small hub that expands on hover: now playing (with Apple Music / Spotify fallback), a file shelf (drag a box to select several files, ⌘-drag to move), clipboard history, quick notes saved to Notes, timer / stopwatch, system stats, a built-in tips window (menu bar → Tips, or the ? button), and drop-down alerts for headphones (with AirPods battery), charging and low battery. macOS 14+, Apple silicon and Intel. Free and open source (MIT).

Install: download `RinNotch.dmg` from Releases, drag to Applications. First launch is blocked because the app isn't notarized: click **Done** (not Move to Trash) → System Settings → Privacy & Security → Security → **Open Anyway**.

Privacy: no screen capture, no keylogging (only the ⌥⌘N hotkey); the microphone is used only to draw the waveform while another app records and is never saved or sent. Network: GitHub update checks, and Spotify artwork. Now Playing is read through macOS's `/usr/bin/perl` (a community-found workaround since macOS 15.4); Apple may block it in a future release.
