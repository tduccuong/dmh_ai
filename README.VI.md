# DMH-AI

Giao diện chat nhẹ, tự host cho Ollama chạy trên máy tính cá nhân. Chạy hoàn toàn trong Docker — không cần Node.js, không cần cài thêm thư viện Python.

## Ảnh chụp màn hình

![Phân tích hình ảnh](image-analysis.png)
![Tìm kiếm web](web-search.png)

## Tính năng

- **Tìm kiếm web tích hợp** — tương tự Perplexity, nhưng tự host và riêng tư. DMH-AI tự động phát hiện khi câu hỏi của bạn cần thông tin mới nhất, tìm kiếm web qua SearXNG tích hợp, và tổng hợp kết quả thành câu trả lời mạch lạc, có nguồn. Hoạt động với mọi ngôn ngữ.
- **Quản lý người dùng** — hỗ trợ đa người dùng đầy đủ tuy đơn giản. Mỗi người dùng có đăng nhập riêng, phiên chat riêng và lưu trữ tệp riêng. Tài khoản admin được tạo tự động khi khởi chạy lần đầu; admin có thể thêm và xóa người dùng ngay trong giao diện.
- **Đính kèm đa phương tiện** — đính kèm tài liệu (PDF, DOCX, XLSX), hình ảnh và video từ thiết bị. Trên điện thoại, chụp ảnh hoặc quay video trực tiếp và đính kèm vào chat — không cần lưu vào thư viện trước.
- Chat với mọi mô hình Ollama — cloud hoặc local — qua giao diện web gọn gàng
- Lưu phiên chat vào SQLite
- Tự động tóm tắt ngữ cảnh cuốn — chat mãi không lo vượt giới hạn token
- Hiển thị Markdown cho câu trả lời
- Giao diện đa ngôn ngữ: Tiếng Anh, Tiếng Việt, Tiếng Đức, Tiếng Tây Ban Nha, Tiếng Pháp
- Truy cập từ mọi thiết bị trong mạng nội bộ

## Yêu cầu

- [Docker](https://docs.docker.com/get-docker/) với plugin Compose
- [Ollama](https://ollama.com/download) chạy trên cổng 11434

### Cài đặt Ollama

**Linux:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**Windows:**
Tải và chạy trình cài đặt từ [ollama.com/download](https://ollama.com/download)

Kiểm tra cài đặt:
```bash
ollama --version
```

## Bước 1 — Chọn mô hình

DMH-AI hoạt động với cả **mô hình cloud** (khuyên dùng cho đa số người dùng) và **mô hình local** (khi bảo mật là ưu tiên hàng đầu). Bạn có thể kết hợp cả hai — chuyển đổi tự do trong giao diện.

---

### Lựa chọn A: Mô hình Cloud (khuyên dùng)

**Phù hợp nhất cho đa số người dùng.** Mô hình cloud của Ollama nhanh, mạnh, và miễn phí với hạn mức rộng rãi cho tài khoản miễn phí. Suy luận chạy trên máy chủ của Ollama và truyền qua Ollama trên máy bạn — không cần GPU, không cần thay đổi cấu hình DMH-AI.

**Khuyên dùng nhất:**

| Mô hình | Lý do |
|---|---|
| `mistral-large-3:675b-cloud` | Toàn diện nhất — nhanh, hỗ trợ hình ảnh, xuất sắc trong chat đa năng, lập trình, suy luận và đa ngôn ngữ |
| `ministral-3:14b-cloud` | Kích thước trung bình, đa năng — cực nhanh và cũng hỗ trợ hình ảnh |

Các mô hình cloud khác đáng thử:

| Mô hình | Ghi chú |
|---|---|
| `qwen3.5:cloud` | Mạnh về đa ngôn ngữ và suy luận |
| `gemini-3-flash-preview:cloud` | Mô hình hàng đầu của Google, suy luận sâu và rất nhanh |

**Cách thiết lập:**

1. **Tạo tài khoản Ollama miễn phí** tại [ollama.com](https://ollama.com) — nhấn **Sign Up**.

2. **Kết nối Ollama trên máy với tài khoản:**
   ```bash
   ollama login
   ```
   Trình duyệt sẽ mở để xác thực. Sau khi đăng nhập, Ollama trên máy bạn được liên kết với tài khoản.

3. **Tải mô hình cloud:**
   ```bash
   ollama pull mistral-large-3:675b-cloud
   ```

Vậy là xong. Mô hình xuất hiện ngay trong danh sách của DMH-AI — chọn và bắt đầu chat.

Mô hình cloud có thẻ `:cloud`. Cần kết nối internet nhưng không tốn tài nguyên máy tính của bạn.

---

### Lựa chọn B: Mô hình Local (hoàn toàn offline, bảo mật tối đa)

**Phù hợp khi bảo mật là ưu tiên hàng đầu.** Mọi dữ liệu ở trên máy bạn — không gì rời khỏi mạng nội bộ. Cần đủ RAM/VRAM để chạy mô hình.

**Văn bản và tài liệu (nhanh, ít bộ nhớ):**

| Mô hình | Dung lượng | Ghi chú |
|---|---|---|
| `gemma3n:e2b` | ~5.6 GB | Mô hình nhỏ đa ngôn ngữ tốt nhất |
| `phi4-mini:3.8b` | ~2.5 GB | Mô hình nhỏ đa năng tốt |
| `granite4:3b` | ~2.1 GB | Suy luận mạnh và nhanh |

**Hình ảnh:**

| Mô hình | Dung lượng | Ghi chú |
|---|---|---|
| `ministral-3:3b` | ~3 GB | Hỗ trợ hình ảnh, đa năng và nhanh |

**Tải mô hình local:**
```bash
ollama pull mistral-3:3b
```

Trên Linux, khởi động Ollama nếu chưa chạy:
```bash
ollama serve
```
Trên Windows, Ollama tự động khởi động — không cần chạy `ollama serve`.

## Bước 2 — Cài đặt Docker

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**Windows:** Tải và chạy **Docker Desktop** từ [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). Sau khi cài, mở Docker Desktop và đợi cho đến khi biểu tượng cá voi trên thanh tác vụ ngừng chuyển động.

## Bước 3 — Chạy DMH-AI

**Linux:**
```bash
./build.sh && ./dist/run.sh
```

**Windows** — trong Command Prompt:
```
build.bat && dist\run.bat
```

Mở [http://localhost:8080](http://localhost:8080) trong trình duyệt. Các thiết bị khác trong mạng có thể truy cập tại `http://<địa-chỉ-IP-máy-bạn>:8080`.

Để dùng **nhập liệu bằng giọng nói**, dùng cổng HTTPS `https://localhost:8443` (hoặc `https://<địa-chỉ-IP-máy-bạn>:8443`). Chấp nhận cảnh báo chứng chỉ tự ký một lần. Trên iOS, nhấn vào liên kết cảnh báo chứng chỉ để tải về và cài đặt qua Cài đặt.

### Đăng nhập lần đầu

Khi khởi chạy lần đầu, DMH-AI tạo tài khoản admin mặc định:

| Tên đăng nhập | Mật khẩu |
|---|---|
| `admin` | `dmhai` |

Đăng nhập xong, vào biểu tượng người dùng → **Đổi mật khẩu** để đặt mật khẩu mới. Để thêm người dùng khác, vào biểu tượng người dùng → **Quản lý người dùng**.

Phiên chat và tệp tải lên của mỗi người dùng được lưu trữ hoàn toàn riêng biệt.

Dữ liệu được lưu trong:
- `dist/db/` — Cơ sở dữ liệu SQLite
- `dist/user_assets/` — Tệp đã tải lên, theo phiên
- `dist/system_logs/system.log` — Nhật ký hệ thống và tìm kiếm web

Để chuyển sang máy khác, sao chép toàn bộ thư mục `dist/` — mọi dữ liệu đi theo.

## Tìm kiếm Web — Perplexity tự host của riêng bạn

DMH-AI tích hợp quy trình tìm kiếm web tương tự Perplexity, ChatGPT Search, và Google Gemini — nhưng hoàn toàn tự host và riêng tư.

**Cách hoạt động:**

1. Bạn đặt câu hỏi bằng bất kỳ ngôn ngữ nào
2. Mô hình AI tự đánh giá câu hỏi có cần dữ liệu web mới nhất không (không dùng từ khóa cứng — nó hiểu ý định)
3. Nếu cần, DMH-AI trích xuất từ khóa, truy vấn SearXNG tích hợp, và lấy kết quả hàng đầu
4. Mô hình AI tổng hợp kết quả thành câu trả lời mạch lạc, có cấu trúc, dựa trên thông tin mới nhất

Tất cả diễn ra tự động và minh bạch — bạn chỉ cần hỏi và nhận câu trả lời cập nhật. Không cần API key, không cần đăng ký dịch vụ, không có dữ liệu rời khỏi mạng của bạn (truy vấn tìm kiếm đi qua SearXNG tự host).

## Kiến trúc

```
Trình duyệt
  ├── nginx :8080 (HTTP)
  └── nginx :8443 (HTTPS, dành cho nhập giọng nói)
        ├── /          → index.html (SPA)
        ├── /api       → Ollama :11434
        ├── /sessions  → Python backend :3000
        ├── /assets    → Python backend :3000
        ├── /search    → Python backend :3000 → SearXNG :8888
        └── /log       → Python backend :3000
```

Toàn bộ frontend là một tệp `code/index.html` duy nhất — vanilla JS, không framework, không cần build. Backend là `code/backend/server.py` chỉ dùng thư viện chuẩn Python.

## Cấu trúc dự án

```
code/
  index.html              # toàn bộ frontend (HTML + CSS + JS)
  backend/server.py       # API phiên, tải tệp, proxy tìm kiếm, ghi log
  nginx.conf              # cấu hình reverse proxy
  Dockerfile              # nginx:alpine + python3
  start.sh                # entrypoint: khởi động python backend rồi nginx
  docker-compose.yml      # tệp compose gốc
  searxng-settings.yml    # cấu hình SearXNG (bật JSON API trên cổng 8888)
  run.sh                  # script chạy Linux (copy vào dist/ bởi build.sh)
  run.bat                 # script chạy Windows (copy vào dist/ bởi build.bat)
build.sh                  # Linux: build image và tạo dist/
build.bat                 # Windows: build image và tạo dist/
dist/                     # tạo bởi build.sh / build.bat — không chỉnh sửa thủ công
```
