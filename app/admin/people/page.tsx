"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, toPoisha } from "@/lib/supabase";

type Batch = { id: number; name: string; is_active: boolean };
type Stu = { id: string; student_code: string; roll_no: string | null; status: string; batch_id: number; profiles: { full_name: string } | null };
type Adm = { id: string; full_name: string; is_active: boolean; admin_batches: { batch_id: number }[] };

export default function People() {
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);
  const [tab, setTab] = useState<"batches" | "students" | "admins">("batches");
  const [batches, setBatches] = useState<Batch[]>([]);
  const [students, setStudents] = useState<Stu[]>([]);
  const [admins, setAdmins] = useState<Adm[]>([]);
  const [q, setQ] = useState("");
  const [newBatch, setNewBatch] = useState("");
  const [editing, setEditing] = useState<string | null>(null);
  const [editSet, setEditSet] = useState<Set<number>>(new Set());
  const [f, setF] = useState({ full_name: "", email: "", password: "", student_code: "", roll_no: "", batch_id: "", opening: "" });
  const [fa, setFa] = useState({ full_name: "", email: "", password: "" });
  const [faBatches, setFaBatches] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function load() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    setRole(me?.role ?? "none");
    if (me?.role !== "super_admin") return;
    const [b, s, a] = await Promise.all([
      supabase.from("batches").select("id,name,is_active").order("name"),
      supabase.from("students").select("id,student_code,roll_no,status,batch_id,profiles(full_name)").order("student_code").limit(2000),
      supabase.from("profiles").select("id,full_name,is_active,admin_batches(batch_id)").eq("role", "batch_admin").order("full_name"),
    ]);
    setBatches((b.data ?? []) as Batch[]); setStudents((s.data ?? []) as unknown as Stu[]); setAdmins((a.data ?? []) as unknown as Adm[]);
  }
  useEffect(() => { load(); }, []);

  const bname = (id: number) => batches.find((b) => b.id === id)?.name ?? "?";
  const run = async (p: PromiseLike<{ error: { message: string } | null }>, ok: string) => {
    const { error } = await p; setMsg(error ? { ok: false, text: error.message } : { ok: true, text: ok }); if (!error) load(); return !error;
  };

  async function create(body: object, reset: () => void) {
    setBusy(true); setMsg(null);
    const { data: { session } } = await supabase.auth.getSession();
    const res = await fetch("/api/admin/create-user", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session?.access_token}` }, body: JSON.stringify(body),
    });
    const j = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) return setMsg({ ok: false, text: j.error ?? "Failed" });
    setMsg({ ok: true, text: "Account created. Share the temporary password privately; ask them to change it." }); reset(); load();
  }

  const list = useMemo(() => students.filter((s) => !q || s.student_code.toLowerCase().includes(q.toLowerCase())
    || (s.profiles?.full_name ?? "").toLowerCase().includes(q.toLowerCase())).slice(0, 100), [students, q]);
  const toggle = (set: Set<number>, id: number, fn: (s: Set<number>) => void) => { const n = new Set(set); n.has(id) ? n.delete(id) : n.add(id); fn(n); };

  if (role === null) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (role !== "super_admin") return <main><div className="card">Super Admin access only.</div></main>;
  const tabBtn = (t: typeof tab, l: string) => <button className="btn sm" style={{ background: tab === t ? undefined : "#64748b", marginRight: 6 }} onClick={() => { setTab(t); setMsg(null); }}>{l}</button>;

  return (
    <main className="wide">
      <h1>Batches, students &amp; admins</h1>
      <p><a href="/admin/dashboard">← Dashboard</a></p>
      <p>{tabBtn("batches", "Batches")}{tabBtn("students", "Students")}{tabBtn("admins", "Batch admins")}</p>
      {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}

      {tab === "batches" && (
        <div className="card tblwrap">
          <table className="t"><thead><tr><th>Batch</th><th>Status</th><th>Students</th><th></th></tr></thead><tbody>
            {batches.map((b) => (
              <tr key={b.id}><td>{b.name}</td><td>{b.is_active ? "Active" : "Inactive"}</td>
                <td>{students.filter((s) => s.batch_id === b.id).length}</td>
                <td>
                  <button className="btn sm" onClick={() => { const n = window.prompt("New batch name", b.name); if (n) run(supabase.rpc("upsert_batch", { p_id: b.id, p_name: n, p_active: b.is_active }), "Batch renamed."); }}>Rename</button>{" "}
                  <button className="btn sm" style={{ background: "#64748b" }} onClick={() => window.confirm(`${b.is_active ? "Deactivate" : "Activate"} ${b.name}?`) && run(supabase.rpc("upsert_batch", { p_id: b.id, p_name: b.name, p_active: !b.is_active }), "Batch updated.")}>{b.is_active ? "Deactivate" : "Activate"}</button>
                </td></tr>
            ))}</tbody></table>
          <p><input className="sel" placeholder="New batch name" aria-label="New batch name" value={newBatch} onChange={(e) => setNewBatch(e.target.value)} />
            <button className="btn sm" disabled={!newBatch} onClick={async () => { if (await run(supabase.rpc("upsert_batch", { p_id: null, p_name: newBatch, p_active: true }), "Batch added.")) setNewBatch(""); }}>Add batch</button></p>
        </div>
      )}

      {tab === "students" && (
        <>
          <form className="card" onSubmit={(e) => {
            e.preventDefault();
            const op = f.opening ? toPoisha(f.opening) : 0;
            if (op === null) return setMsg({ ok: false, text: "Invalid opening balance" });
            create({ kind: "student", full_name: f.full_name, email: f.email, password: f.password, student_code: f.student_code,
              roll_no: f.roll_no, batch_id: Number(f.batch_id), opening_poisha: op },
              () => setF({ full_name: "", email: "", password: "", student_code: "", roll_no: "", batch_id: "", opening: "" }));
          }}>
            <b>Register student</b><br />
            {([["full_name", "Full name"], ["email", "Email"], ["password", "Temporary password (min 8)"], ["student_code", "Student ID"], ["roll_no", "Roll no"], ["opening", "Opening balance ৳ (optional)"]] as const).map(([k, l]) => (
              <span key={k}><label htmlFor={k}>{l}</label><br /><input id={k} className="sel" required={!["roll_no", "opening"].includes(k)} type={k === "password" ? "password" : "text"}
                value={(f as any)[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} /><br /></span>))}
            <label htmlFor="bt">Batch</label><br />
            <select id="bt" className="sel" required value={f.batch_id} onChange={(e) => setF({ ...f, batch_id: e.target.value })}>
              <option value="">Select…</option>{batches.filter((b) => b.is_active).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select><br />
            <button className="btn" disabled={busy}>{busy ? "Creating…" : "Create student account"}</button>
          </form>

          <input className="sel" style={{ width: "100%" }} placeholder="Search students" aria-label="Search students" value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="card tblwrap"><table className="t"><thead><tr><th>Name</th><th>ID</th><th>Batch</th><th>Status</th><th></th></tr></thead><tbody>
            {list.map((s) => (
              <tr key={s.id}><td>{s.profiles?.full_name}</td><td>{s.student_code}</td><td>{bname(s.batch_id)}</td><td>{s.status}</td>
                <td><button className="btn sm" style={{ background: "#64748b" }} onClick={() => {
                  const to = s.status === "active" ? "suspended" : "active";
                  if (window.confirm(`Set ${s.student_code} to ${to}?`)) run(supabase.rpc("set_student_status", { p_student: s.id, p_status: to }), "Status updated.");
                }}>{s.status === "active" ? "Suspend" : "Activate"}</button></td></tr>))}</tbody></table></div>
        </>
      )}

      {tab === "admins" && (
        <>
          <form className="card" onSubmit={(e) => { e.preventDefault(); create({ kind: "batch_admin", ...fa, batch_ids: [...faBatches] }, () => { setFa({ full_name: "", email: "", password: "" }); setFaBatches(new Set()); }); }}>
            <b>Create batch admin</b><br />
            {([["full_name", "Full name"], ["email", "Email"], ["password", "Temporary password (min 8)"]] as const).map(([k, l]) => (
              <span key={k}><label htmlFor={"a" + k}>{l}</label><br /><input id={"a" + k} className="sel" required type={k === "password" ? "password" : "text"}
                value={fa[k]} onChange={(e) => setFa({ ...fa, [k]: e.target.value })} /><br /></span>))}
            <fieldset><legend>Assigned batches</legend>
              {batches.map((b) => <label key={b.id} style={{ marginRight: 10 }}><input type="checkbox" checked={faBatches.has(b.id)} onChange={() => toggle(faBatches, b.id, setFaBatches)} /> {b.name}</label>)}</fieldset>
            <button className="btn" disabled={busy}>{busy ? "Creating…" : "Create batch admin"}</button>
          </form>

          <div className="card tblwrap"><table className="t"><thead><tr><th>Admin</th><th>Batches</th><th>Status</th><th></th></tr></thead><tbody>
            {admins.map((a) => (
              <tr key={a.id}><td>{a.full_name}</td>
                <td>{editing === a.id ? batches.map((b) => <label key={b.id} style={{ marginRight: 8 }}><input type="checkbox" checked={editSet.has(b.id)} onChange={() => toggle(editSet, b.id, setEditSet)} /> {b.name}</label>)
                  : a.admin_batches.map((x) => bname(x.batch_id)).join(", ") || "None"}</td>
                <td>{a.is_active ? "Active" : "Suspended"}</td>
                <td>{editing === a.id
                  ? <button className="btn sm" onClick={async () => { if (await run(supabase.rpc("set_admin_batches", { p_admin: a.id, p_batches: [...editSet] }), "Assignments saved.")) setEditing(null); }}>Save</button>
                  : <button className="btn sm" onClick={() => { setEditing(a.id); setEditSet(new Set(a.admin_batches.map((x) => x.batch_id))); }}>Edit batches</button>}{" "}
                  <button className="btn sm" style={{ background: "#64748b" }} onClick={() => window.confirm(`${a.is_active ? "Suspend" : "Reactivate"} ${a.full_name}?`) && run(supabase.rpc("set_user_active", { p_user: a.id, p_active: !a.is_active }), "Account updated.")}>{a.is_active ? "Suspend" : "Reactivate"}</button></td></tr>))}</tbody></table></div>
        </>
      )}
    </main>
  );
}
