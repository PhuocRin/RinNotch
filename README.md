# RinNotch

Biến tai thỏ MacBook thành khu tiện ích nhỏ, bung ra mượt khi rê chuột lên hoặc bấm phím tắt.

Trang tải và hướng dẫn cài có hình: https://phuocrin.com/rinnotch/

## Tính năng

- **Nhạc / video**: ảnh bìa, tên bài, thanh thời lượng (bấm để tua), lùi / phát / tới. Đang phát thì hai bên tai thỏ hiện ảnh bìa và cột nhạc. App "Đang phát" của macOS bị dừng mà Apple Music hay Spotify vẫn chạy thì tự chuyển qua bài đó.
- **Kệ file**: kéo file thả lên tai thỏ để giữ tạm, có ảnh xem trước. Kéo chuột trên chỗ trống để chọn nhiều file, ⌘/⇧ + bấm để chọn thêm, rồi kéo cả nhóm ra cùng lúc. Kéo ra = sao chép, giữ ⌘ khi kéo = chuyển file. Chuột phải: Mở, AirDrop, Sao chép, Hiện trong Finder, Chọn tất cả.
- Bộ nhớ tạm và Kệ file hiện dạng thẻ có ảnh xem trước, lọc theo loại (Bộ nhớ tạm lọc được cả theo app đã copy), nút ⤢ mở bảng lớn. Mỗi lần copy có viên "Đã chép" hiện dưới tai thỏ, rê chuột vào để Ghim, Dịch, Xoá.
- **Xử lý file trên kệ**: đổi ảnh sang JPG / PNG / HEIC, nén ảnh, thu nhỏ (3840, 1920, 1280 px hoặc một nửa), xoá nền ra PNG trong suốt, gộp ảnh và PDF thành một file PDF, nén ZIP. File mới nằm cạnh file gốc, file gốc giữ nguyên.
- **Bộ nhớ tạm**: giữ 20 tới 200 mục gần nhất kèm app đã copy, bấm để chép lại. Tìm không cần dấu, lọc bằng @link @image @color @code @file hoặc @tên-app. Ghim để giữ lâu dài (còn sau khi thoát app). Nhận ra mã màu (hiện ô màu, chép dạng HEX / RGB / HSL), link, code (tô màu). Chuột phải để sửa nhanh chữ: viết hoa, bỏ dấu tiếng Việt, bỏ khoảng trắng / dòng trống, nối dòng, sắp xếp, xoá dòng trùng. Sao lưu và nhập trong Cài đặt. Bỏ qua mật khẩu và các app bạn chọn.
- **Công cụ**: lấy mã màu ở bất kỳ điểm nào trên màn hình; giữ máy thức 15 phút tới 4 giờ hoặc tới khi tắt (tự tắt khi pin dưới 10% hay gập máy); khoá bàn phím 2 phút để lau (Esc 5 lần để mở sớm).
- **Dịch nhanh**: bôi đen chữ ở app bất kỳ rồi bấm ⌃⌘8, tai thỏ hiện bản dịch (Việt ⇄ Anh hoặc 10 ngôn ngữ khác), chép hoặc thay luôn chỗ vừa chọn. Dịch trên máy bằng bộ dịch của macOS 15+; macOS 14 có nút mở Google Dịch.
- **Ghi chú nhanh**: Enter xuống dòng, ⌘ Enter lưu vào app Notes (thư mục RinNotch).
- **Hẹn giờ**: bấm giờ từ 00:00:00 hoặc đếm ngược 1 phút tới 1 giờ, hết giờ có chuông.
- **Hệ thống**: CPU, RAM, tốc độ mạng, mức nhiệt (chỉ đo khi mở mục này).
- **Thông báo thả xuống**: tai nghe kết nối (kèm % pin AirPods, icon đúng mẫu), cắm / rút sạc, pin yếu 20% và 10%, mất mạng và có mạng lại.
- **Ghi âm**: app nào đang dùng micro thì hiện icon app, thời gian cộng dồn qua các lần tạm dừng và sóng âm.
- **Phím tắt**: ⌃⌘1 → ⌃⌘8 mở thẳng Nhạc, Kệ file, Bộ nhớ tạm, Ghi chú, Hẹn giờ, Hệ thống, Công cụ, Dịch nhanh (bấm lại để đóng). Tai thỏ đang mở thì bấm số 1–8 để chuyển mục. ⌃⌘0 mở bảng lớn chứa hết Bộ nhớ tạm và Kệ file. ⌥⌘N ẩn / hiện, Esc thu lại. Đổi hoặc tắt từng phím trong Cài đặt. Bộ ⌃⌘ + số được chọn vì không trùng phím của Final Cut Pro và phím mặc định của macOS.
- **Cài đặt**: cách mở tai thỏ (rê chuột, phím tắt hoặc cả hai), bật / tắt từng loại hiển thị, chọn mục mở khi rê chuột, mở cùng máy.
- **Mẹo dùng**: tự mở một lần khi cài, mở lại từ thanh menu → Mẹo dùng hoặc nút ? trên tai thỏ (mở đúng mục đang xem).
- Tự cập nhật (gói cập nhật được ký số, kiểm tra trước khi cài), Báo lỗi kèm nhật ký, Ủng hộ tác giả.

Cần macOS 14 trở lên, Mac chip Apple và Intel. Máy không có tai thỏ vẫn dùng được: rê chuột lên giữa cạnh trên màn hình.

## Cài đặt

1. Tải `RinNotch.dmg` ở [Releases](https://github.com/PhuocRin/RinNotch/releases/latest), mở ra, kéo RinNotch vào Applications.
2. Lần đầu mở bị chặn (app chưa được Apple công chứng): bấm **Xong** (đừng bấm Chuyển vào Thùng rác) → Cài đặt → Quyền riêng tư & Bảo mật → kéo xuống phần **Bảo mật** → **Vẫn mở** → xác nhận.
3. macOS chỉ hỏi quyền khi bạn dùng tới: Micro (sóng âm), Notes (ghi chú), Music / Spotify (nhạc), Bluetooth (pin AirPods), Trợ năng (Dịch nhanh đọc chữ đang bôi đen, khoá bàn phím để lau).

## RinNotch có an toàn không?

- Không chụp màn hình, không ghi bàn phím: phím tắt đăng ký với macOS nên app chỉ biết khi đúng phím tắt đó được bấm.
- Quyền Trợ năng (nếu bạn cấp) chỉ dùng vào hai lúc: bấm phím Dịch nhanh thì đọc chữ đang bôi đen (app nào không cho đọc thì bấm ⌘C giúp rồi trả bộ nhớ tạm như cũ); lúc khoá bàn phím để lau thì chặn mọi phím trong 2 phút và chỉ đếm phím Esc để mở khoá.
- Bộ nhớ tạm và mục ghim nằm trên máy (`~/Library/Application Support/RinNotch`), không gửi đi đâu. Dịch nhanh dùng bộ dịch trên máy của macOS.
- Micro chỉ dùng để vẽ sóng âm khi app khác đang ghi âm; không lưu, không gửi âm thanh.
- Kết nối mạng: hỏi GitHub có bản mới và tải bản mới; tải ảnh bìa từ máy chủ ảnh của Spotify khi nghe Spotify; chỉ khi bạn bật Xem trước liên kết thì mở trang của link vừa chép để lấy tên trang; nút Mở Google Dịch (macOS 14) mở trình duyệt với đoạn chữ đó.
- Phần đọc bài đang phát chạy qua `/usr/bin/perl` của macOS (`Helper/rinmedia.m`). Đây là cách cộng đồng tìm ra sau khi macOS 15.4 chặn app bên thứ ba đọc thẳng; RinNotch tự viết phần này. Apple có thể chặn cách này ở bản macOS sau.

## Tác giả

Làm bởi Phước Rin: [YouTube](https://youtube.com/@phuocrin) · [TikTok](https://www.tiktok.com/@phuocrinrin) · [Facebook](https://www.facebook.com/phuocrinrin) · [phuocrin.com](https://phuocrin.com)

Miễn phí, mã nguồn mở (MIT).

---

## English

RinNotch turns the MacBook notch into a small hub that expands on hover or with shortcuts (⌃⌘1–8, changeable in Settings): now playing (with Apple Music / Spotify fallback), a file shelf (multi-select, ⌘-drag to move, plus convert / compress / resize / remove background / merge to PDF / ZIP), clipboard history with search, pins, colors, code highlighting and quick text fixes, quick notes saved to Notes, timer / stopwatch, system stats, tools (color picker, keep awake, keyboard cleaning lock), quick translate of selected text (on-device, macOS 15+), a built-in tips window, and drop-down alerts for headphones (with AirPods battery), charging, low battery and lost internet. macOS 14+, Apple silicon and Intel. Free and open source (MIT).

Install: download `RinNotch.dmg` from Releases, drag to Applications. First launch is blocked because the app isn't notarized: click **Done** (not Move to Trash) → System Settings → Privacy & Security → Security → **Open Anyway**.

Privacy: no screen capture, no keylogging (shortcuts are registered with macOS); Accessibility, if granted, is used only to read the selection when you press Translate and to block keys during the 2-minute cleaning lock; the microphone is used only to draw the waveform while another app records and is never saved or sent. Network: GitHub update checks, and Spotify artwork. Now Playing is read through macOS's `/usr/bin/perl` (a community-found workaround since macOS 15.4); Apple may block it in a future release.
