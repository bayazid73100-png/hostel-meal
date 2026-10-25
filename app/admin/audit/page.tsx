"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

type Log = { id: number; action: string; target_student: string | null; details: any; created_at: string; profiles: { full_name: string } | null };
const PAGE = 50;
const todayStr = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date());

export default function Audit() {
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);
  const [logs, setLogs] = useState<Log[]>([]);
  const [codes, setCodes] = useState<Record<string, string>>({});
  const [action, setAction] = useState("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState(todayStr());
  const [code, setCode] = useState("");
  const [limit, setLimit] = useState(PAGE);
  const [more, setMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");

  async function load() {
    setLoading(true); setErr("");
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    setRole(me?.role ?? "none");
    if (me?.role !== "super_admin") return setLoading(false);   // RLS also limits audit_logs to Super Admin

    let q = supabase.from("audit_logs").select("id,action,target_student,details,created_at,profiles(full_name)")
      .order("id", { ascending: false }).limit(limit + 1);
    if (action !== "all") q = q.eq("action", action);
    if (from) q = q.gte("created_at", `${from}T00:00:00+06:00`);
    if (to) q = q.lte("created_at", `${to}T23:59:59+06:00`);
    if (code.trim()) {
      const { data: s } = await supabase.from("students").select("id").ilike("student_code", code.trim()).limit(1).single();
      if (!s) { setLogs([]); setMore(false); return setLoading(false); }
      q = q.eq("target_student", s.id);
    }
    const { data, error } = await q;
    if (error) { setErr(error.message); return setLoading(false); }
    const list = (data ?? []) as unknown as Log[];
    setMore(list.length > limit); setLogs(list.slice(0, limit));

    const ids = [...new Set(list.map((l) => l.target_student).filter(Boolean))] as string[];
    if (ids.length) {
      const { data: st } = await supabase.from("students").select("id,student_code").in("id", ids);
      setCodes(Object.fromEntries((st ?? []).map((x) => [x.id, x.student_code])));
    }
    setLoading(false);
  }
  useEffect(() => { load(); }, [limit]);

  if (role !== null && role !== "super_admin") return <main><div className="card">Super Admin access only.</div></main>;

  const actions = ["confirm_consumption", "mark_missed", "post_deposit", "post_refund", "post_credit_adj", "post_debit_adj", "reverse",
    "authorize_exception", "set_meal_price", "set_booking_deadline", "upsert_batch", "set_student_status", "set_admin_batches",
    "set_user_active", "create_student", "create_batch_admin"];

  return (
    <main className="wide">
      <h1>Audit log</h1>
      <div className="no-print">
        <select className="sel" aria-label="Action" value={action} onChange={(e) => setAction(e.target.value)}>
          <option value="all">All actions</option>{actions.map((a) => <option key={a}>{a}</option>)}</select>
        <input className="sel" type="date" aria-label="From" value={from} onChange={(e) => setFrom(e.target.value)} />
        <input className="sel" type="date" aria-label="To" value={to} onChange={(e) => setTo(e.target.value)} />
        <input className="sel" placeholder="Student ID" aria-label="Student ID" value={code} onChange={(e) => setCode(e.target.value)} />
        <button className="btn sm" onClick={() => { setLimit(PAGE); load(); }}>Apply</button>
      </div>
      {err && <div className="msg err" role="alert">{err}</div>}
      {loading ? <div className="card" aria-busy="true">Loading…</div> : logs.length === 0 ? <div className="card">No log entries match.</div> : (
        <div className="card tblwrap">
          <table className="t"><thead><tr><th>Time (BST)</th><th>By</th><th>Action</th><th>Student</th><th>Details</th></tr></thead><tbody>
            {logs.map((l) => (
              <tr key={l.id}>
                <td>{new Date(l.created_at).toLocaleString("en-GB", { timeZone: "Asia/Dhaka" })}</td>
                <td>{l.profiles?.full_name ?? "—"}</td><td><span className="chip">{l.action}</span></td>
                <td>{l.target_student ? codes[l.target_student] ?? "…" : "—"}</td>
                <td><details><summary>View</summary><pre style={{ whiteSpace: "pre-wrap", fontSize: ".75rem", margin: 0 }}>{JSON.stringify(l.details, null, 1)}</pre></details></td>
              </tr>))}</tbody></table>
          {more && <button className="btn" onClick={() => setLimit(limit + PAGE)}>Load more</button>}
        </div>
      )}
    </main>
  );
}
