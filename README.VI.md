# DMH-AI

Ứng dụng chat AI tự host chạy trên máy tính của bạn — giống ChatGPT, nhưng riêng tư, miễn phí và hoàn toàn thuộc về bạn.

Vì DMH-AI chạy trên máy của bạn, **bạn hoàn toàn kiểm soát dữ liệu của mình**. Mọi cuộc trò chuyện, bộ nhớ đồng hành, ghi chú riêng tư, tệp đính kèm — tất cả đều lưu trên phần cứng của bạn, trong không gian của bạn. Không bên thứ ba nào có thể truy cập, phân tích hay khai thác. Khi dùng các mô hình AI cloud, chỉ có nội dung văn bản của mỗi yêu cầu được gửi đi xử lý — không có gì khác rời khỏi máy của bạn.

## Ảnh chụp màn hình

![Tự động tìm kiếm web](auto_web_search.png)
*Hỏi về bất kỳ thông tin nào cần cập nhật, DMH-AI tự động tìm kiếm web, lấy dữ liệu thực và trả lời có nguồn dẫn.*

---

![Xem hình ảnh](see_images.png)
*Thả ảnh hoặc video bất kỳ vào và đặt câu hỏi.*

---

## Hai chế độ: Bạn Tâm Sự và Trợ Lý

DMH-AI cung cấp hai loại phiên AI, có thể chuyển đổi từ thanh trên cùng.

### Bạn Tâm Sự (Confidant) — người bạn đồng hành AI riêng tư của bạn

Theo phong cách hội thoại, giống ChatGPT. Bạn nhắn, câu trả lời được phát trực tiếp về. Dùng cho các câu hỏi hàng ngày, hỗ trợ viết lách, phân tích hình ảnh và brainstorming — bất cứ khi nào bạn muốn có câu trả lời ngay lập tức.

Điều khiến Bạn Tâm Sự không chỉ là một công cụ chat:

- **Thả vào tệp bất kỳ.** PDF, tài liệu Word, bảng tính, ảnh, video. Hỏi trực tiếp về chúng. Trên điện thoại, có thể chụp ảnh hoặc quay video thẳng vào chat.
- **Tự động tìm kiếm web.** Bạn Tâm Sự tự quyết định xem câu hỏi của bạn có cần thông tin trực tiếp hay không. Nếu cần, nó tìm kiếm web, lấy nội dung trang và đưa ra câu trả lời có nguồn dẫn — không cần bật "chế độ tìm kiếm" gì cả.
- **`/memo` cho ghi chú riêng tư.** Gõ `/memo Khóa SSH homelab của tôi là X` hoặc `/memo Tôi thích Tailwind hơn CSS thuần`, và Bạn Tâm Sự ghi nhớ. Lần sau khi chủ đề liên quan xuất hiện — kể cả nhiều tháng sau — những ghi chú đó có thể được tra cứu lại dễ dàng. **Mã hóa khi lưu**, với khóa nằm ngoài cơ sở dữ liệu — kể cả bản sao lưu DB bị đánh cắp cũng không thể đọc được.
- **Nó lớn lên cùng bạn.** Bạn Tâm Sự xây dựng hồ sơ về bạn theo thời gian — sở thích, bối cảnh, những gì bạn chia sẻ — và dùng sự hiểu biết đó để đưa ra câu trả lời phù hợp, cá nhân hóa hơn. Nằm trên phần cứng của bạn; có thể xem hoặc xóa bất kỳ lúc nào trong Cài đặt hội thoại.
- **Không có giới hạn bộ nhớ.** Phiên dài đến đâu cũng được — ngữ cảnh cũ được nén thông minh. Bạn không bao giờ chạm trần token.

### Trợ Lý (Assistant) — AI làm việc trong nền khi bạn chat

Cho các tác vụ tốn thời gian: nghiên cứu, viết tài liệu dài, chạy code, điều phối nhiều bước. Bạn giao mục tiêu; nó tự làm việc và thông báo khi hoàn thành. Trong khi nó chạy, bạn vẫn chat tiếp được — hỏi *"sao rồi?"* sẽ có cập nhật trực tiếp về tiến độ.

Trợ Lý có thể:

- **Chạy script trong sandbox.** Bash, Python, curl, jq, git, node — Trợ Lý có thể viết và thực thi script trong một container cô lập. Tác vụ dài (hàng giờ, qua đêm) vẫn chạy trong khi bạn làm việc khác.
- **Nhiệm vụ định kỳ.** Bảo nó *"tóm tắt các bài arxiv vật lý mới mỗi sáng 8 giờ"* và nó sẽ tiếp tục làm. Có thể chỉnh sửa, tạm dừng hay hủy bất kỳ nhiệm vụ nào từ thanh bên.
- **Đọc và ghi tệp.** Mỗi phiên có không gian làm việc riêng. Trợ Lý đọc tệp đã tải lên, lấy trang web, và ghi kết quả vào không gian làm việc trong quá trình thực hiện.
- **Kết nối dịch vụ bên ngoài.** Nhiều dịch vụ (HuggingFace và một danh sách đang lớn dần) có giao diện công cụ AI tiêu chuẩn (MCP). Bảo Trợ Lý *"kết nối HuggingFace"* — nó sẽ thực hiện ủy quyền, và từ đó các hành động của dịch vụ trở thành công cụ trực tiếp cho nhiệm vụ đó.
- **`/wiki` cho cơ sở tri thức của riêng bạn.** Gõ `/wiki https://docs-noi-bo-cua-toi.example` để thu thập và lập chỉ mục một site, hoặc `/wiki <tệp đính kèm>` cho một tài liệu đơn lẻ. Từ đó về sau, Trợ Lý kéo các đoạn liên quan ra mỗi khi cần — kiểu Perplexity, nhưng trên dữ liệu riêng của bạn.
- **Chạy nhiều phiên cùng lúc.** Mở nhiều phiên Trợ Lý; mỗi phiên chạy song song. Gửi điều chỉnh giữa chừng và Trợ Lý tiếp nhận ở bước tiếp theo. Nhấn Stop để hủy sạch sẽ.

**Khi nào dùng cái nào:**

| | Bạn Tâm Sự | Trợ Lý |
|---|---|---|
| Phong cách | Phát trực tiếp, tức thì | Chạy ngầm, thông báo khi xong |
| Phù hợp với | Câu hỏi, viết lách, phân tích ảnh / tài liệu, brainstorming | Công việc nhiều bước, scripting, nghiên cứu, tự động hóa, tích hợp |
| Bạn phải đợi? | Có, nhưng chỉ vài giây | Không — chat tiếp bình thường |
| Đồng thời | Một phiên hoạt động một lúc | Nhiều nhiệm vụ mỗi phiên, nhiều phiên cùng lúc |

---

## Tính năng nổi bật

- **Bộ nhớ đồng hành & ghi chú riêng tư** — hồ sơ tự xây + ghi chú `/memo` mã hóa, tất cả trên phần cứng của bạn
- **Tìm kiếm web tích hợp** — tương tự Perplexity, nhưng tự host và riêng tư; hoạt động với mọi ngôn ngữ
- **Agent chạy trong sandbox** — Bash, Python, thao tác tệp, trích xuất tài liệu, lấy trang web, lịch định kỳ
- **Tích hợp dịch vụ bên ngoài** — cho mọi dịch vụ hỗ trợ chuẩn MCP
- **Cơ sở tri thức cá nhân** — `/wiki` thu thập URL, tệp hoặc thư mục; AI tự truy xuất khi cần
- **Đính kèm đa phương tiện** — PDF, DOCX, XLSX, hình ảnh và video; trên điện thoại có thể chụp hoặc quay thẳng vào chat
- **Hỗ trợ nhiều người dùng** — mỗi người có đăng nhập, lịch sử và tệp riêng; admin quản lý người dùng ngay trong ứng dụng
- **Lưu lịch sử chat** — toàn bộ cuộc trò chuyện được lưu và có thể tìm lại
- **Giao diện đa ngôn ngữ** — Tiếng Anh, Tiếng Việt, Tiếng Đức, Tiếng Tây Ban Nha, Tiếng Pháp
- **Truy cập từ mọi thiết bị trong mạng nội bộ** — điện thoại, máy tính bảng, laptop

Để xem mô tả kỹ thuật chi tiết, xem [specs/architecture.md](specs/architecture.md).

---

## Cài đặt

### Bước 1 — Cài Docker

Docker chạy DMH-AI trong một container độc lập.

**Linux:**
```bash
curl -fsSL https://get.docker.com | sh
```

**macOS / Windows:** Tải và chạy **Docker Desktop** từ [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/). Sau khi cài, mở Docker Desktop và đợi biểu tượng cá voi trên thanh menu (macOS) hoặc thanh tác vụ (Windows) ngừng chuyển động — khi đó là sẵn sàng.

### Bước 2 — Build và cài đặt DMH-AI

**Linux / macOS:**
```bash
./build.sh        # build Docker image và tạo dist/
./install.sh      # cài vào ~/.dmh_ai/ và đăng ký lệnh dmh_ai
dmh_ai start       # khởi động ứng dụng
```

**Windows** — mở Command Prompt và chạy:
```
build.bat
install.bat
dmh_ai start
```

Mở [http://localhost:8080](http://localhost:8080) trong trình duyệt.

### Quản lý ứng dụng

```bash
dmh_ai start      # khởi động
dmh_ai stop       # dừng
dmh_ai restart    # khởi động lại (tự nhận bản build mới)
dmh_ai status     # xem trạng thái container
```

Sau khi cập nhật code, build lại và cài lại:
```bash
./build.sh --no-export   # build lại image, không xuất tar (nhanh hơn)
./install.sh             # cập nhật cấu hình đã cài; giữ nguyên toàn bộ dữ liệu
dmh_ai restart
```

Trên Windows, dùng `build.bat` và `install.bat` thay thế.

### Đăng nhập lần đầu

Lần đầu khởi chạy, DMH-AI tạo tài khoản admin mặc định:

| Tên đăng nhập | Mật khẩu |
|---|---|
| `admin` | `dmh_ai` |

Đăng nhập xong, **đổi mật khẩu ngay**: nhấn biểu tượng người dùng (góc trên phải) → **Đổi mật khẩu**.

---

## Kết nối dịch vụ AI (admin)

DMH-AI cần một backend AI để hoạt động. Admin cấu hình điều này một lần trong Cài đặt. Người dùng không tương tác với việc chọn mô hình.

### Mặc định — Ollama cloud

Ollama cung cấp mô hình AI cloud mạnh mẽ hoàn toàn miễn phí, với hạn mức sử dụng rộng rãi. Đây là cách thiết lập đơn giản nhất: không cần GPU, không yêu cầu phần cứng đặc biệt.

1. Vào [ollama.com](https://ollama.com) và tạo tài khoản miễn phí
2. Nhấn vào ảnh đại diện → **Settings** → **API Keys** → **Create new key**, sao chép key
3. Trong DMH-AI: biểu tượng người dùng → **Cài đặt** → **Ollama Cloud — Tài khoản API** → **Thêm tài khoản**, dán key vào

Vậy là xong. Cả hai chế độ Bạn Tâm Sự và Trợ Lý đều sẵn sàng ngay lập tức cho tất cả người dùng.

Trong thiết lập này, chỉ có nội dung văn bản của mỗi yêu cầu AI được gửi đến máy chủ Ollama để xử lý. Toàn bộ dữ liệu người dùng — lịch sử chat, bộ nhớ đồng hành, tệp đã tải lên, ghi chú `/memo` — đều ở lại trên máy của bạn và không bao giờ được chia sẻ với bất kỳ bên thứ ba nào.

### Thay thế — Ollama local (hoàn toàn offline)

Để có thiết lập mà tuyệt đối không có gì rời khỏi mạng nội bộ — kể cả yêu cầu AI — bạn có thể chuyển sang dùng Ollama chạy cục bộ. Cách này yêu cầu phần cứng đủ mạnh để chạy mô hình AI (CPU hiện đại là đủ cho các mô hình nhỏ; GPU giúp tăng tốc đáng kể cho các mô hình lớn hơn).

**Cài Ollama:**

```bash
# Linux
curl -fsSL https://ollama.com/install.sh | sh
```

macOS / Windows: tải từ [ollama.com/download](https://ollama.com/download). Ollama tự khởi động sau khi cài xong.

**Tải mô hình** (admin quyết định dùng mô hình nào):
```bash
ollama pull <tên-mô-hình>
```

Trên Linux, khởi động Ollama nếu chưa chạy dưới dạng dịch vụ:
```bash
ollama serve
```

Trong cài đặt admin của DMH-AI, trỏ **Ollama Local — URL Endpoint** vào instance Ollama của bạn (ví dụ: `http://localhost:11434`) và cấu hình Mô hình AI để dùng tên mô hình local.

---

## Truy cập từ thiết bị khác trong mạng

Sau khi DMH-AI chạy, bất kỳ điện thoại, máy tính bảng hay laptop nào trong cùng mạng Wi-Fi đều có thể dùng.

Tìm địa chỉ IP local của máy bạn (ví dụ: `192.168.1.10`) và mở `http://192.168.1.10:8080` trên thiết bị bất kỳ.

**Nhập liệu bằng giọng nói** cần HTTPS. Dùng `https://<địa-chỉ-IP>:8443`. Trình duyệt sẽ hiện cảnh báo về chứng chỉ tự ký — đây là bình thường, chấp nhận một lần. Trên iOS, nhấn vào liên kết trong cảnh báo chứng chỉ để tải về và cài qua Cài đặt (làm một lần cho mỗi thiết bị).

---

## Tài liệu tham khảo Cài đặt Admin

Nhấn biểu tượng người dùng → **Cài đặt** (chỉ admin).

**Ollama Cloud — Tài khoản API**

Thêm một hoặc nhiều tài khoản (nhãn + API key). DMH-AI tự động luân phiên qua tất cả tài khoản đã thêm — nếu một tài khoản bị giới hạn lượt dùng, tài khoản tiếp theo tiếp quản mà không bị gián đoạn.

**Ví dụ:** Một gia đình bốn người, mỗi người tạo một tài khoản Ollama miễn phí rồi thêm cả bốn key vào đây. DMH-AI tự động phân phối tải một cách minh bạch — không ai trong gia đình cần quan tâm tài khoản nào đang được dùng hay hạn mức có bị vượt không.

**Mô hình AI**

Cấu hình mô hình AI cho từng vai trò: hội thoại Bạn Tâm Sự, xử lý nền Trợ Lý, phân loại nhanh (Swift), tóm tắt ngữ cảnh dài (Oracle), phân tích hình ảnh và video, embedding. Mỗi vai trò có thể dùng một mô hình khác nhau được tối ưu cho nhiệm vụ đó.

**Ollama Local — URL Endpoint**

Mặc định, DMH-AI kết nối Ollama tại `http://localhost:11434`. Thay đổi nếu Ollama chạy trên máy khác trong mạng nội bộ (ví dụ: máy chủ tại nhà).

---

## Tìm kiếm web

DMH-AI tích hợp quy trình tìm kiếm web — tương tự Perplexity hay ChatGPT Search, nhưng tự host và riêng tư.

**Cách hoạt động:**

1. Bạn đặt câu hỏi bằng bất kỳ ngôn ngữ nào
2. AI tự đánh giá xem câu hỏi có cần thông tin trực tiếp từ web không (không dùng từ khóa cứng — nó hiểu ý định)
3. Nếu cần, DMH-AI tìm kiếm qua SearXNG tích hợp và lấy kết quả hàng đầu
4. AI tổng hợp kết quả thành câu trả lời mạch lạc, có cấu trúc, có nguồn dẫn

Bạn không cần làm gì khác — chỉ cần hỏi. Truy vấn tìm kiếm đi qua SearXNG tự host của bạn, không qua dịch vụ bên thứ ba nào.

---

## Dữ liệu của bạn

Sau khi chạy `install.sh`, toàn bộ dữ liệu được lưu trong `~/.dmh_ai/`:

- `~/.dmh_ai/db/` — lịch sử chat (cơ sở dữ liệu SQLite)
- `~/.dmh_ai/secrets/` — khóa mã hóa chính cho ghi chú `/memo` (sao lưu **riêng** với cơ sở dữ liệu — xem bên dưới)
- `~/.dmh_ai/user_assets/` — tệp đã tải lên, theo phiên
- `~/.dmh_ai/system_logs/system.log` — nhật ký tìm kiếm web và hệ thống

Chạy lại `install.sh` là an toàn — không bao giờ ghi đè dữ liệu hiện có. Mỗi tệp chỉ được copy từ `dist/` nếu chưa tồn tại trong `~/.dmh_ai/`.

Để sao lưu hoặc chuyển DMH-AI sang máy khác, sao chép thư mục `~/.dmh_ai/` và chạy `install.sh` trên máy mới.

**Về mã hóa `/memo`.** Ghi chú đã lưu của bạn được mã hóa bằng một khóa riêng cho từng người dùng, khóa đó lại được bọc bởi khóa chính trong `~/.dmh_ai/secrets/`. Hãy sao lưu thư mục `secrets/` **riêng** với cơ sở dữ liệu — đó chính là điểm cốt lõi: chỉ có bản sao lưu DB không thể giải mã ghi chú của bạn. Nếu bạn mất thư mục `secrets/`, các ghi chú hiện có không còn đọc được nữa (DMH-AI vẫn cho bạn lưu ghi chú mới dưới một khóa mới).

Để thêm người dùng: biểu tượng người dùng → **Quản lý người dùng**.
