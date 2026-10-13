## Navig – chia sẻ vị trí thời gian thực với nhóm bạn bè

### Tải về
| Nền tảng | Tệp | Cách cài |
|---|---|---|
| Android | `Navig-*-android.apk` | Tải về máy → mở tệp → cho phép "Cài ứng dụng không rõ nguồn gốc" |
| Android (Google Play) | `Navig-*-android.aab` | Tải lên Google Play Console |
| iOS | `Navig-*-ios.ipa` | Bản đã ký (khi repo có secrets ký iOS) – cài qua TestFlight / Apple Configurator / MDM |
| iOS | `Navig-*-ios-unsigned.ipa` | Bản chưa ký – cài bằng Sideloadly / AltStore (ký bằng Apple ID của bạn) |

### Lần đầu sử dụng
1. Dựng máy chủ Navig (xem README – Docker một lệnh).
2. Mở app → nhập tên, chọn biểu tượng → nhập địa chỉ máy chủ (nếu bản build chưa gắn sẵn).
3. Tạo nhóm → gửi **mã mời 6 ký tự** cho bạn bè → bạn bè chọn "Nhập mã mời".
4. Cho phép quyền vị trí. Android: tắt tối ưu hoá pin cho Navig; iOS: chọn "Luôn luôn" để chia sẻ khi chạy nền.
