# Flashcard Web — bản có Database + Auth + Admin

Bộ này chuyển dữ liệu người dùng ra khỏi `localStorage` và lưu trong Supabase PostgreSQL. Supabase Auth chịu trách nhiệm đăng nhập; Row Level Security (RLS) giới hạn dữ liệu của người dùng; Edge Function giữ `service_role` key ở phía server để Admin có thể cấp/xoá/đặt lại tài khoản.

## 1. Tạo Supabase project

Vào Supabase Dashboard, tạo 1 project mới.

Vào **SQL Editor** và chạy toàn bộ file `supabase/schema.sql`.

## 2. Tạo Admin

Trong **Authentication → Users**, tạo tài khoản Admin.

Email khuyến nghị dùng: `huynhgiahuys3883@gmail.com`.

Mật khẩu Admin có thể đặt là `hzhzhuyhuy` để giữ đúng mật khẩu đã yêu cầu trước đó. Không có mật khẩu Admin nào được hard-code trong HTML.

Sau khi tạo Auth user, chạy:

```sql
update public.profiles
set role='admin', status='active', expires_at=null
where email='huynhgiahuys3883@gmail.com';
```

## 3. Cấu hình HTML

Copy `supabase-config.example.js` thành `supabase-config.js`, sau đó thay:

```js
window.FLASHCARD_CONFIG = {
  supabaseUrl: 'https://YOUR_PROJECT_REF.supabase.co',
  supabasePublishableKey: 'YOUR_SUPABASE_PUBLISHABLE_KEY'
};
```

Không đưa `service_role` key vào HTML. Theo tài liệu Supabase, publishable/anon key có thể dùng ở browser khi RLS được cấu hình đúng; `service_role` phải giữ ở server/Edge Function. 

## 4. Deploy Edge Function

Trong thư mục dự án Supabase:

```bash
supabase functions deploy admin-manage-user
```

Function này dùng `SUPABASE_SERVICE_ROLE_KEY` của môi trường Edge Function để tạo, xoá và đổi mật khẩu người dùng. Key này không xuất hiện trong frontend.

## 5. Tắt đăng ký tự do

Vì mô hình của web là **Admin cấp tài khoản**, nên trong Authentication Settings nên tắt đăng ký công khai. Người dùng chỉ nhận email + mật khẩu từ Admin.

## 6. Luồng sử dụng

Người dùng mở web → đăng nhập → hệ thống kiểm tra `profiles.status` và `expires_at` → vào học → tiến độ, lịch sử, thời gian sử dụng được lưu vào database theo `user_id`.

Admin mở tab Admin → xem toàn bộ tài khoản → cấp tài khoản mới → xem thống kê từng người → khoá/gia hạn → đặt lại mật khẩu → xoá tài khoản.

## 7. Điều khoản và Liên hệ Admin

Trang đăng nhập có nút **Liên hệ Admin**. Người dùng phải đọc và tick đồng ý điều khoản trước khi mở Facebook/email. Việc chấp thuận được ghi vào bảng `terms_acceptances` theo phiên bản điều khoản.

Thông tin liên hệ đang được cấu hình:
- Facebook: https://www.facebook.com/ghuybboi
- Email: huynhgiahuys3883@gmail.com

Điều khoản trong giao diện là mẫu vận hành cho sản phẩm; bạn nên rà soát lại nội dung về giá, thời hạn, hoàn tiền, quyền sử dụng nội dung và xử lý dữ liệu cho đúng mô hình kinh doanh thực tế.

## 8. Dữ liệu cũ

Phiên bản cũ lưu dữ liệu trong `localStorage`. Phiên bản database không tự đoán ghép dữ liệu cũ vào tài khoản Auth. Nên giữ file cũ làm bản dự phòng; phần dữ liệu quan trọng có thể được chuyển sang tài khoản cụ thể bằng công cụ import/migration riêng.
