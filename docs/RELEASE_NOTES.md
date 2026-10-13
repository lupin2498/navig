## Navig – chia sẻ vị trí thời gian thực với nhóm bạn bè

### Tải về
| Nền tảng | Tệp | Cách cài |
|---|---|---|
| Android | `Navig-*-android.apk` | Tải về máy → mở tệp → cho phép "Cài ứng dụng không rõ nguồn gốc" |
| Android (Google Play) | `Navig-*-android.aab` | Tải lên Google Play Console |
| iOS | `Navig-*-ios.ipa` | Bản đã ký (khi repo có secrets ký iOS) – cài qua TestFlight / Apple Configurator / MDM |
| iOS | `Navig-*-ios-unsigned.ipa` | Bản chưa ký – cài bằng Sideloadly / AltStore (ký bằng Apple ID của bạn) |

### Lần đầu sử dụng
1. Mở app → nhập tên, chọn biểu tượng → **Bắt đầu**. Mặc định dùng máy chủ miễn phí **ntfy.sh**
   (không cần dựng máy chủ; vị trí được mã hoá đầu-cuối). Có thể đổi sang ntfy tự dựng hoặc máy chủ
   Navig trong mục "Nâng cao".
2. Tạo nhóm → bấm **Mời bạn** để gửi mã mời (ntfy: 16 ký tự, vd `7K2M-QX9D-0RTB-4HVA`) → bạn bè
   chọn "Nhập mã mời". Cả nhóm phải dùng cùng một máy chủ.
3. Cho phép quyền vị trí. Android: tắt tối ưu hoá pin cho Navig; iOS: chọn "Luôn luôn" để chia sẻ khi chạy nền.

Trên ntfy.sh miễn phí: cập nhật ~1 phút/lần khi di chuyển, 15 phút/lần khi đứng yên
(hạn mức 250 tin/ngày cho mỗi địa chỉ IP).
