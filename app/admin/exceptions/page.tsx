"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka, toPoisha, dhakaTomorrow } from "@/lib/supabase";

type Stu = { id: string; student_code: string; batches: { name: string } | null; profiles: { full_name: string } | null };
type Exc = { id: string; meal_date: string; meal: string | null; amount: number; reason: string; created_at: string; students: { student_code: string } | null };

export default function Exceptions() {
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);
  const [students, setStudents] = useState<Stu[]>([]);
  const [bal, setBal] = useState<Record<string, number>>({});
  const [excs, setExcs] = useState<Exc[]>([]);
  const [q, setQ] = useState("");
  const [sel, setSel] = useState<Stu | null>(null);
  const [date, setDate] = useState(dhakaTomorrow());
  const [meal, setMeal] = useState("lunch");
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function load() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    setRole(me?.role ?? "none");
    if (me?.role !== "super_admin") return;
    const [s, w, e] = await Promise.all([
      supabase.from("students").select("id,student_code,batches(name),profiles(full_name)").order("student_code").limit(1000),
      supabase.from("student_wallets").select("student_id,balance"),
      supabase.from("authorized_exceptions").select("id,meal_date,meal,amount,reason,created_at,students(student_code)")
        .order("created_at", { ascending: false }).limit(15),
    ]);
    setStudents((s.data ?? []) as unknown as Stu[]);
    setBal(Object.fromEntries((w.data ?? []).map((x) => [x.student_id, x.balance])));
    setExcs((e.data ?? []) as unknown as Exc[]);
  }
  useEffect(() => { load(); }, []);

  const negatives = students.filter((s) => (bal[s.id] ?? 0) < 0);
  const list = useMemo(() => students.filter((s) =>
    !q || s.student_code.toLowerCase().includes(q.toLowerCase()) ||
    (s.profiles?.full_name ?? "").toLowerCase().includes(q.toLowerCase())).slice(0, 20), [students, q]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!sel) return;
    const p = toPoisha(amount);
    if (p === null) return setMsg({ ok: false, text: "Enter a valid amount, e.g. 40" });
    if (reason.trim().length < 4) return setMsg({ ok: false, text: "Please give a reason." });
    if (!window.confirm(`Authorize up to ${taka(p)} on credit for ${sel.profiles?.full_name} (${sel.student_code}) on ${date}? A negative balance may result.`)) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("authorize_exception", {
      p_student: sel.id, p_date: date, p_meal: meal === "both" ? null : meal, p_amount: p, p_reason: reason,
    });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: error.message });
    setMsg({ ok: true, text: "Exception authorized. The student (or an admin) can now book that meal." });
    setAmount(""); setReason(""); load();
  }

  if (role === null) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (role !== "super_admin") return <main><div className="card">Super Admin access only.</div></main>;

  return (
    <main className="wide">
      <h1>Negative-balance exceptions</h1>

      <div className="card">
        <b>Students with negative balance ({negatives.length})</b>
        {negatives.length === 0 ? <p>None.</p> : (
          <ul style={{ paddingLeft: 18 }}>
            {negatives.map((s) => (
              <li key={s.id}>⚠ {s.profiles?.full_name} · {s.student_code} · {s.batches?.name} · <b>{taka(bal[s.id])}</b></li>
            ))}
          </ul>
        )}
      </div>

      {!sel ? (
        <>
          <input className="sel" style={{ width: "100%" }} placeholder="Search student to authorize" aria-label="Search students"
            value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="card tblwrap">
            <table className="t"><tbody>{list.map((s) => (
              <tr key={s.id}><td>{s.profiles?.full_name}</td><td>{s.student_code}</td><td>{s.batches?.name}</td>
                <td>{taka(bal[s.id] ?? 0)}</td>
                <td><button className="btn sm" onClick={() => { setSel(s); setMsg(null); }}>Select</button></td></tr>
            ))}</tbody></table>
          </div>
        </>
      ) : (
        <form className="card" onSubmit={submit}>
          <b>{sel.profiles?.full_name}</b> · {sel.student_code} · balance {taka(bal[sel.id] ?? 0)}<br /><br />
          <label htmlFor="d">Meal date</label><br />
          <input id="d" type="date" className="sel" value={date} onChange={(e) => setDate(e.target.value)} /><br />
          <label htmlFor="m">Meal</label><br />
          <select id="m" className="sel" value={meal} onChange={(e) => setMeal(e.target.value)}>
            <option value="lunch">Lunch</option><option value="dinner">Dinner</option><option value="both">Both</option>
          </select><br />
          <label htmlFor="a">Credit allowed (৳): the shortfall this exception may cover</label><br />
          <input id="a" className="sel" inputMode="decimal" required value={amount} onChange={(e) => setAmount(e.target.value)} /><br />
          <label htmlFor="r">Reason (recorded in audit log)</label><br />
          <input id="r" className="sel" style={{ width: "100%" }} required value={reason} onChange={(e) => setReason(e.target.value)} /><br />
          <button className="btn" disabled={busy}>{busy ? "Saving…" : "Authorize exception"}</button>{" "}
          <button type="button" className="btn sm" style={{ background: "#64748b", marginTop: 8 }} onClick={() => setSel(null)}>Change student</button>
          {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}
        </form>
      )}
      {sel === null && msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}

      <div className="card tblwrap">
        <b>Recent exceptions</b>
        {excs.length === 0 ? <p>None yet.</p> : (
          <table className="t"><thead><tr><th>Student</th><th>Date</th><th>Meal</th><th>Amount</th><th>Reason</th></tr></thead>
            <tbody>{excs.map((x) => (
              <tr key={x.id}><td>{x.students?.student_code}</td><td>{x.meal_date}</td><td>{x.meal ?? "both"}</td>
                <td>{taka(x.amount)}</td><td>{x.reason}</td></tr>
            ))}</tbody></table>
        )}
      </div>
    </main>
  );
}
