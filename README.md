# Navig – Chia sẻ vị trí theo thời gian thực với nhóm bạn bè

Ứng dụng di động (Android + iOS) lấy cảm hứng từ tính năng chia sẻ vị trí của **Love8**,
mở rộng từ "cặp đôi" thành **nhóm bạn bè**: mọi thành viên thấy nhau trên bản đồ theo thời gian thực.

## Tính năng

| Tính năng | Mô tả |
|---|---|
| Bản đồ thời gian thực | Avatar của từng thành viên trên bản đồ OpenStreetMap, cập nhật tức thì qua WebSocket |
| Pin & sạc | Mức pin, trạng thái đang sạc, cảnh báo pin yếu (≤ 20%) |
| Tốc độ | "Đang di chuyển · 35 km/h" khi đang đi, huy hiệu tốc độ trên bản đồ |
| Thời gian ở lại | "Ở đây 2 giờ 5 phút" – tự tính khi thành viên đứng yên trong bán kính 100 m |
| Khoảng cách | Khoảng cách từ bạn tới từng người, địa chỉ (reverse geocoding) |
| Cập nhật lần cuối | "Vừa xong", "5 phút trước", trạng thái online/offline |
| Lộ trình 24h | Vẽ đường đi của một thành viên trong 24 giờ qua |
| Chỉ đường | Mở Google Maps / Apple Maps dẫn đường tới bạn bè |
| Chạm (nudge) | Gửi lời nhắn nhanh: "Bạn đang ở đâu?", "Về tới chưa?"… kèm rung |
| Nhóm & mã mời | Tạo nhiều nhóm, mời bằng mã 6 ký tự, đổi mã, trưởng nhóm xoá thành viên, rời nhóm |
| Chế độ ẩn | Tạm dừng chia sẻ vị trí bất cứ lúc nào |
| Chạy nền | Android: foreground service; iOS: background location updates |
| Ngoại tuyến | Điểm vị trí được xếp hàng khi mất mạng và gửi lại khi có kết nối |
| Quyền riêng tư | Chỉ thành viên cùng nhóm thấy vị trí; xoá tài khoản xoá toàn bộ dữ liệu |

## Cấu trúc

```
app/      Ứng dụng Flutter (Android + iOS)
server/   Máy chủ Node.js: REST API + WebSocket, lưu dữ liệu vào file JSON
.github/workflows/build.yml   CI: test, build APK/AAB/IPA, Docker image, GitHub Release
```

## 1. Dựng máy chủ

Cả nhóm dùng chung một máy chủ. Chọn một cách:

**Docker (VPS bất kỳ)**
```bash
docker run -d --name navig -p 8080:8080 -v navig-data:/data --restart unless-stopped \
  ghcr.io/lupin2498/navig-server:latest
# hoặc từ mã nguồn:  docker compose up -d
```

**Node.js trực tiếp**
```bash
cd server && npm ci && npm start   # PORT=8080, DATA_DIR=./data
```

**Render.com**: New → Blueprint → chọn repo này (dùng `render.yaml`, gói có ổ đĩa để giữ dữ liệu).

Nên đặt máy chủ sau HTTPS (Caddy/Nginx/Cloudflare Tunnel). Kiểm tra: `curl https://your-server/health`.

| Biến môi trường | Mặc định | Ý nghĩa |
|---|---|---|
| `PORT` | `8080` | Cổng HTTP/WebSocket |
| `DATA_DIR` | `./data` | Thư mục lưu `db.json` |
| `HISTORY_HOURS` | `24` | Số giờ lưu lịch sử lộ trình |

## 2. Bộ cài Android & iOS

Bộ cài được build tự động bởi GitHub Actions (**Actions → Build Android & iOS**) và đăng lên
**Releases**: mỗi lần push cập nhật bản `latest-build` (bản build mới nhất), đẩy tag `v*` tạo bản
phát hành chính thức:

- `Navig-x.y.z-android.apk` – cài trực tiếp trên Android 7+.
- `Navig-x.y.z-android.aab` – để đăng Google Play.
- `Navig-x.y.z-ios-unsigned.ipa` – iOS chưa ký, cài bằng Sideloadly/AltStore.
- `Navig-x.y.z-ios.ipa` – iOS đã ký (khi cấu hình secrets bên dưới).

### Gắn sẵn địa chỉ máy chủ vào app
Đặt biến repo **Settings → Secrets and variables → Actions → Variables → `SERVER_URL`**
(vd `https://navig.example.com`), hoặc nhập khi chạy workflow thủ công. Khi đó người dùng không cần
gõ địa chỉ máy chủ.

### Ký bản phát hành (tuỳ chọn)
| Secret / Variable | Dùng cho |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Ký APK/AAB bằng khoá riêng (mặc định dùng keystore chung trong repo) |
| `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD` | Chứng chỉ Apple Distribution/Development (.p12) |
| `IOS_PROVISIONING_PROFILE_BASE64` | Provisioning profile (.mobileprovision) |
| biến `IOS_EXPORT_METHOD` | `ad-hoc` (mặc định), `development`, `app-store`, `enterprise` |
| biến `IOS_BUNDLE_ID` | Bundle ID trong profile (mặc định `com.navig.navig`) |

### Build thủ công
```bash
cd app
flutter pub get
flutter build apk --release --dart-define=SERVER_URL=https://navig.example.com
flutter build ipa --release --dart-define=SERVER_URL=https://navig.example.com   # cần macOS + Xcode
```

## 3. Phát triển & kiểm thử

```bash
cd server && npm test                 # test API + WebSocket
cd app && flutter analyze && flutter test   # gồm test end-to-end app ↔ máy chủ thật
```

Bản đồ dùng tile OpenStreetMap (không cần API key); đổi nguồn tile bằng `--dart-define=TILE_URL=...`.

## API máy chủ (tóm tắt)

| Method | Đường dẫn | Mô tả |
|---|---|---|
| POST | `/api/register` | Tạo hồ sơ `{name,color,emoji}` → `{token,user}` |
| GET/PATCH/DELETE | `/api/me` | Hồ sơ + nhóm / sửa hồ sơ, bật-tắt chia sẻ / xoá tài khoản |
| POST | `/api/groups`, `/api/groups/join` | Tạo nhóm / tham gia bằng mã |
| PATCH | `/api/groups/:id` | Đổi tên, tạo mã mới |
| POST | `/api/groups/:id/leave` | Rời nhóm |
| DELETE | `/api/groups/:id/members/:uid` | Trưởng nhóm xoá thành viên |
| POST | `/api/location` | Gửi một điểm hoặc `{points:[...]}` |
| GET | `/api/users/:id/history` | Lộ trình 24h |
| POST | `/api/users/:id/nudge` | Gửi "chạm" |
| WS | `/ws?token=` | Sự kiện `hello`, `location`, `group`, `profile`, `presence`, `nudge` |
