# RinNotch

Biến tai thỏ MacBook thành khu tiện ích nhỏ, bung ra mượt như Dynamic Island.

Bản thử 0.4 (đang làm):

- Rê chuột lên tai thỏ để mở: Nhạc, Kệ file, Bộ nhớ tạm, Ghi chú nhanh, Hẹn giờ, Hệ thống
- Kéo file thả lên tai thỏ để giữ tạm, kéo ra chỗ khác để sao chép, gửi AirDrop
- Bộ nhớ tạm 20 mục gần nhất (chỉ lưu trong máy, bỏ qua mật khẩu)
- Ghi chú nhanh, lưu vào app Notes (thư mục RinNotch)
- Báo tai nghe kết nối, báo cắm và ngắt sạc
- Có app đang ghi âm thì tai thỏ hiện thời gian (cộng dồn qua các lần tạm dừng) và sóng âm
- ⌥⌘N để ẩn hoặc hiện RinNotch

Cần macOS 14 trở lên.

Làm bởi Phước Rin: YouTube · TikTok · Facebook (facebook.com/phuocrinrin) · phuocrin.com

Phần Nhạc đọc thông tin bài đang phát bằng cách chạy qua `/usr/bin/perl` của macOS. Đây là cách cộng đồng tìm ra sau khi macOS 15.4 chặn app bên thứ ba đọc thẳng; RinNotch tự viết phần này (Helper/rinmedia.m), Apple có thể chặn cách này trong bản macOS sau.
