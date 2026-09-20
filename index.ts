import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "Server is not configured." }, 500);

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Unauthorized" }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return json({ error: "Unauthorized" }, 401);

  const { data: callerProfile, error: callerError } = await admin
    .from("profiles")
    .select("id, role, status")
    .eq("id", authData.user.id)
    .single();

  if (callerError || callerProfile?.role !== "admin" || callerProfile?.status !== "active") {
    return json({ error: "Admin access required." }, 403);
  }

  const body = await req.json().catch(() => ({}));
  const action = body.action;

  if (action === "create") {
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    const displayName = String(body.display_name || "Người học").trim().slice(0, 80);
    const gender = body.gender === "male" ? "male" : "female";
    const days = Math.max(1, Math.min(3650, Number(body.days || 30)));

    if (!/^\S+@\S+\.\S+$/.test(email)) return json({ error: "Email không hợp lệ." }, 400);
    if (password.length < 6) return json({ error: "Mật khẩu phải có ít nhất 6 ký tự." }, 400);

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name: displayName, gender },
    });
    if (createError || !created.user) return json({ error: createError?.message || "Không tạo được tài khoản." }, 400);

    const expiresAt = new Date(Date.now() + days * 86400000).toISOString();
    const { error: profileError } = await admin.from("profiles").upsert({
      id: created.user.id,
      email,
      display_name: displayName || "Người học",
      gender,
      role: "user",
      status: "active",
      expires_at: expiresAt,
    }, { onConflict: "id" });

    if (profileError) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: profileError.message }, 500);
    }

    return json({ ok: true, user_id: created.user.id, expires_at: expiresAt });
  }

  if (action === "set_password") {
    const userId = String(body.user_id || "");
    const password = String(body.password || "");
    if (!userId || password.length < 6) return json({ error: "Thiếu user_id hoặc mật khẩu quá ngắn." }, 400);
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (action === "delete") {
    const userId = String(body.user_id || "");
    if (!userId || userId === authData.user.id) return json({ error: "Không thể xoá tài khoản Admin đang đăng nhập." }, 400);
    const { data: target, error: targetError } = await admin.from("profiles").select("role").eq("id", userId).single();
    if (targetError) return json({ error: targetError.message }, 400);
    if (target?.role === "admin") return json({ error: "Không xoá tài khoản Admin bằng chức năng này." }, 400);

    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  return json({ error: "Unknown action" }, 400);
});
