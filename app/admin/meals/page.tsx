"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka, dhakaTomorrow } from "@/lib/supabase";

type Meal = "lunch" | "dinner";
type Row = {
  id: string; student_id: string; status: string; meal: Meal;
  students: { student_code: string; batches: { name: string } | null; profiles: { full_name: string } | null };
};

export default function DailyMeals() {
  const router = useRouter();
  const [date, setDate] = useState(dhakaTomorrow());
  const [meal, setMeal] = useState<Meal>("lunch");
  const [batch, setBatch] = useState("all");
  const [q, setQ] = useState("");
  const [rows, setRows] = useState<Row[]>([]);
  const [bal, setBal] = useState<Record<string, number>>({});
  const [price, setPrice] = useState(0);
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function load() {
    setLoading(true);
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    if (!me || !["super_admin", "batch_admin"].includes(me.role)) { setAllowed(false); setLoading(false); return; }
    setAllowed(true);

    // RLS returns only students from this admin's assigned batches.
    const { data } = await supabase.from("meal_bookings")
      .select("id,student_id,status,meal,students(student_code,batches(name),profiles(full_name))")
      .eq("meal_date", date).eq("meal", meal);
    const list = (data ?? []) as unknown as Row[];
    setRows(list);

    const ids = list.map((r) => r.student_id);
    if (ids.length) {
      const { data: w } = await supabase.from("student_wallets").select("student_id,balance").in("student_id", ids);
      setBal(Object.fromEntries((w ?? []).map((x) => [x.student_id, x.balance])));
    } else setBal({});
    const { data: p } = await supabase.from("meal_prices").select("price").eq("meal", meal)
      .lte("effective_from", date).order("effective_from", { ascending: false }).limit(1);
    setPrice(p?.[0]?.price ?? 0);
    setLoading(false);
  }
  useEffect(() => { load(); }, [date, meal]);

  const eligibility = (r: Row) =>
    r.status === "authorized_exception" ? "Authorized exception"
    : r.status === "booked" && (bal[r.student_id] ?? 0) < price ? "Insufficient balance" : "Eligible";

  const batches = useMemo(() => [...new Set(rows.map((r) => r.students.batches?.name ?? ""))].filter(Boolean), [rows]);
  const shown = rows.filter((r) =>
    (batch === "all" || r.students.batches?.name === batch) &&
    (!q || r.students.student_code.toLowerCase().includes(q.toLowerCase()) ||
      (r.students.profiles?.full_name ?? "").toLowerCase().includes(q.toLowerCase())));

  const count = (f: (r: Row) => boolean) => shown.filter(f).length;
  const active = (r: Row) => ["booked", "authorized_exception", "consumed"].includes(r.status);
  const pending = shown.filter((r) => ["booked", "authorized_exception"].includes(r.status));

  async function confirmOne(id: string) {
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("confirm_consumption", { p_booking: id });
    setBusy(false);
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Consumption confirmed and charged." });
    if (!error) load();
  }

  async function markMissed(id: string) {
    if (!window.confirm("Mark as missed? The student will not be charged.")) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("mark_missed", { p_booking: id });
    setBusy(false);
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Marked as missed (no charge)." });
    if (!error) load();
  }

  async function reverse(id: string) {
    const reason = window.prompt("Reason for reversing this charge (required):");
    if (!reason) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("reverse_meal_charge", { p_booking: id, p_reason: reason });
    setBusy(false);
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Charge reversed. Booking reopened." });
    if (!error) load();
  }

  async function confirmAll() {
    if (!pending.length) return;
    if (!window.confirm(`Confirm ${pending.length} meals as eaten? Each student will be charged ${taka(price)} (final).`)) return;
    setBusy(true); setMsg(null);
    let ok = 0; const errs: string[] = [];
    for (const r of pending) {
      const { error } = await supabase.rpc("confirm_consumption", { p_booking: r.id });
      if (error) errs.push(`${r.students.student_code}: ${error.message}`); else ok++;
    }
    setBusy(false);
    setMsg({ ok: errs.length === 0, text: `${ok} confirmed.${errs.length ? " Failed: " + errs.join("; ") : ""}` });
    load();
  }

  if (allowed === false) return <main><div className="card">Admin access only.</div></main>;

  return (
    <main className="wide">
      <div className="no-print">
        <h1>Daily meal management</h1>
        <div>
          <input className="sel" type="date" aria-label="Date" value={date} onChange={(e) => setDate(e.target.value)} />
          <select className="sel" aria-label="Meal" value={meal} onChange={(e) => setMeal(e.target.value as Meal)}>
            <option value="lunch">Lunch</option><option value="dinner">Dinner</option>
          </select>
          <select className="sel" aria-label="Batch" value={batch} onChange={(e) => setBatch(e.target.value)}>
            <option value="all">All batches</option>
            {batches.map((b) => <option key={b}>{b}</option>)}
          </select>
          <input className="sel" placeholder="Name or student ID" aria-label="Search" value={q} onChange={(e) => setQ(e.target.value)} />
        </div>

        <div className="card">
          Price: <b>{taka(price)}</b> · Booked: <b>{count(active)}</b> ·
          Eligible: <b>{count((r) => r.status === "booked" && eligibility(r) === "Eligible")}</b> ·
          Exceptions: <b>{count((r) => r.status === "authorized_exception")}</b> ·
          Insufficient: <b>{count((r) => r.status === "booked" && eligibility(r) === "Insufficient balance")}</b> ·
          Consumed: <b>{count((r) => r.status === "consumed")}</b> ·
          Missed: <b>{count((r) => r.status === "missed")}</b> ·
          Cancelled: <b>{count((r) => r.status === "cancelled")}</b>
        </div>

        {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}

        <p>
          <button className="btn sm" disabled={busy || !pending.length} onClick={confirmAll}>Confirm all pending ({pending.length})</button>{" "}
          <button className="btn sm" onClick={() => window.print()}>Print kitchen list</button>
        </p>

        {loading ? <div className="card" aria-busy="true">Loading…</div>
        : shown.length === 0 ? <div className="card">No bookings for this date and meal.</div>
        : (
          <div className="card tblwrap">
            <table className="t">
              <thead><tr><th>Student</th><th>ID</th><th>Batch</th><th>Booking</th><th>Eligibility</th><th>Price</th><th></th></tr></thead>
              <tbody>
                {shown.map((r) => (
                  <tr key={r.id}>
                    <td>{r.students.profiles?.full_name}</td>
                    <td>{r.students.student_code}</td>
                    <td>{r.students.batches?.name}</td>
                    <td><span className="chip">{r.status.replace("_", " ")}</span></td>
                    <td>{["booked", "authorized_exception"].includes(r.status) ? eligibility(r) : "—"}</td>
                    <td>{taka(price)}</td>
                    <td>
                      {["booked", "authorized_exception"].includes(r.status) ? (<>
                        <button className="btn sm" disabled={busy} onClick={() => confirmOne(r.id)}>Confirm ate</button>{" "}
                        <button className="btn sm" style={{ background: "#64748b" }} disabled={busy} onClick={() => markMissed(r.id)}>Missed</button>
                      </>) : r.status === "consumed" ? (<>
                        ✔ Charged{" "}
                        <button className="btn sm" style={{ background: "#b91c1c" }} disabled={busy} onClick={() => reverse(r.id)}>Reverse</button>
                      </>) : ""}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Kitchen list: IDs and meals only, no balances */}
      <div className="print-only">
        <h2>Kitchen list · {date} · {meal}</h2>
        <p>Total: {count(active)}</p>
        <table className="t"><thead><tr><th>#</th><th>Student ID</th><th>Name</th><th>Batch</th></tr></thead>
          <tbody>
            {shown.filter(active).map((r, i) => (
              <tr key={r.id}><td>{i + 1}</td><td>{r.students.student_code}</td>
                <td>{r.students.profiles?.full_name}</td><td>{r.students.batches?.name}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
    </main>
  );
}
