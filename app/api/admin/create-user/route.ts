import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Server-only: uses the service-role key. The caller is verified from their JWT, and must be an active Super Admin.
export async function POST(req: NextRequest) {
  const svc = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } });
  const fail = (status: number, error: string) => NextResponse.json({ error }, { status });

  const token = req.headers.get("authorization")?.replace(/^Bearer /, "");
  if (!token) return fail(401, "Not signed in");
  const { data: { user } } = await svc.auth.getUser(token);
  if (!user) return fail(401, "Invalid session");
  const { data: me } = await svc.from("profiles").select("role,is_active").eq("id", user.id).single();
  if (me?.role !== "super_admin" || !me.is_active) return fail(403, "Super Admin only");

  let b: any;
  try { b = await req.json(); } catch { return fail(400, "Bad request"); }
  const email = String(b.email ?? "").trim().toLowerCase();
  const name = String(b.full_name ?? "").trim();
  const password = String(b.password ?? "");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return fail(400, "Invalid email");
  if (name.length < 2) return fail(400, "Name required");
  if (password.length < 8) return fail(400, "Password must be at least 8 characters");
  const kind = b.kind === "batch_admin" ? "batch_admin" : b.kind === "student" ? "student" : null;
  if (!kind) return fail(400, "Invalid kind");

  let batchId = 0, code = "", opening = 0, batchIds: number[] = [];
  if (kind === "student") {
    batchId = Number(b.batch_id); code = String(b.student_code ?? "").trim(); opening = Number(b.opening_poisha ?? 0);
    if (!Number.isInteger(batchId) || batchId <= 0) return fail(400, "Batch required");
    if (code.length < 2) return fail(400, "Student ID required");
    if (!Number.isInteger(opening) || opening < 0 || opening > 100_000_000) return fail(400, "Invalid opening balance");
  } else {
    batchIds = (Array.isArray(b.batch_ids) ? b.batch_ids : []).map(Number).filter((n: number) => Number.isInteger(n) && n > 0);
  }

  const { data: created, error: e1 } = await svc.auth.admin.createUser({ email, password, email_confirm: true });
  if (e1 || !created.user) return fail(400, e1?.message ?? "Could not create user");
  const uid = created.user.id;
  const undo = async (msg: string) => { await svc.auth.admin.deleteUser(uid); return fail(400, msg); };

  const { error: e2 } = await svc.from("profiles").insert({ id: uid, full_name: name, role: kind });
  if (e2) return undo(e2.message);

  if (kind === "student") {
    const { data: stu, error: e3 } = await svc.from("students").insert({
      user_id: uid, student_code: code, roll_no: b.roll_no ? String(b.roll_no) : null, batch_id: batchId,
    }).select("id").single();
    if (e3 || !stu) { await svc.from("profiles").delete().eq("id", uid); return undo(e3?.message ?? "Could not create student"); }
    if (opening > 0) {
      await svc.from("wallet_transactions").insert({
        student_id: stu.id, type: "opening", delta: opening, created_by: user.id, note: "Opening balance at registration",
      });
    }
    await svc.from("audit_logs").insert({ actor: user.id, action: "create_student", target_student: stu.id, details: { code, batchId, opening } });
  } else {
    if (batchIds.length) await svc.from("admin_batches").insert(batchIds.map((batch_id) => ({ admin_id: uid, batch_id })));
    await svc.from("audit_logs").insert({ actor: user.id, action: "create_batch_admin", details: { admin: uid, batchIds } });
  }
  return NextResponse.json({ ok: true, id: uid });
}
