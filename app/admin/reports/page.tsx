"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

type R = {
  student_id: string; student_code: string; full_name: string | null; batch: string;
  opening: number; deposits: number; refunds: number; credit_adj: number; debit_adj: number;
  meal_charges: number; reversals: number; closing: number; meals_booked: number; meals_consumed: number;
};
type Issue = { check_name: string; student_code: string; detail: string };

const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const todayStr = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date());
/** poisha -> "40.50" using integer math (for CSV/display, no floats). */
const money = (p: number) => `${p < 0 ? "-" : ""}${Math.floor(Math.abs(p) / 100)}.${String(Math.abs(p) % 100).padStart(2, "0")}`;

const COLS: [keyof R, string][] = [
  ["opening", "Opening"], ["deposits", "Deposits"], ["refunds", "Refunds"], ["credit_adj", "Credit adj"],
  ["debit_adj", "Debit adj"], ["meal_charges", "Meal charges"], ["reversals", "Reversals"], ["closing", "Closing"],
];
const CHECKS = ["Consumption without live charge", "Charge without valid consumption", "Possible duplicate deposit",
  "Unsettled reservation", "Negative balance without any exception", "Multiple opening balances", "Adjustment without admin author"];

export default function Reports() {
  const router = useRouter();
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [from, setFrom] = useState(todayStr().slice(0, 8) + "01");
  const [to, setTo] = useState(todayStr());
  const [batch, setBatch] = useState("all");
  const [batches, setBatches] = useState<{ id: number; name: string }[]>([]);
  const [level, setLevel] = useState<"student" | "batch" | "hostel">("student");
  const [tab, setTab] = useState<"report" | "recon">("report");
  const [rows, setRows] = useState<R[]>([]);
  const [issues, setIssues] = useState<Issue[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");

  useEffect(() => {
    (async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return router.replace("/login");
      const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
      if (!me || !["super_admin", "batch_admin"].includes(me.role)) return setAllowed(false);
      setAllowed(true);
      const { data: b } = await supabase.from("batches").select("id,name").order("name");
      setBatches(b ?? []);
    })();
  }, []);

  async function run() {
    setLoading(true); setErr("");
    if (tab === "report") {
      const { data, error } = await supabase.rpc("student_ledger_report",
        { p_from: from, p_to: to, p_batch: batch === "all" ? null : Number(batch) });
      if (error) setErr(error.message); else setRows((data ?? []) as R[]);
    } else {
      const { data, error } = await supabase.rpc("reconciliation_report");
      if (error) setErr(error.message); else setIssues((data ?? []) as Issue[]);
    }
    setLoading(false);
  }
  useEffect(() => { if (allowed) run(); }, [allowed, tab]);

  const table = useMemo(() => {
    const sum = (list: R[], label: string, code = ""): any => ({
      key: label + code, code, name: label, batch: "", meals_booked: list.reduce((a, r) => a + r.meals_booked, 0),
      meals_consumed: list.reduce((a, r) => a + r.meals_consumed, 0),
      ...Object.fromEntries(COLS.map(([k]) => [k, list.reduce((a, r) => a + (r[k] as number), 0)])),
    });
    if (level === "student") return rows.map((r) => ({ ...r, key: r.student_id, code: r.student_code, name: r.full_name ?? "" }));
    if (level === "hostel") return [sum(rows, "Entire hostel (selected scope)")];
    const by: Record<string, R[]> = {};
    rows.forEach((r) => (by[r.batch] ??= []).push(r));
    return Object.keys(by).sort().map((b) => sum(by[b], b));
  }, [rows, level]);
  const total = useMemo(() => ({
    ...Object.fromEntries(COLS.map(([k]) => [k, rows.reduce((a, r) => a + (r[k] as number), 0)])),
    meals_booked: rows.reduce((a, r) => a + r.meals_booked, 0), meals_consumed: rows.reduce((a, r) => a + r.meals_consumed, 0),
  }) as any, [rows]);

  function csv() {
    const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const head = ["Student ID", "Name", "Batch", ...COLS.map(([, l]) => l + " (BDT)"), "Meals booked", "Meals consumed"];
    const lines = (table as any[]).map((r) => [r.code, r.name, r.batch, ...COLS.map(([k]) => money(r[k])), r.meals_booked, r.meals_consumed].map(esc).join(","));
    const blob = new Blob(["\uFEFF" + [head.map(esc).join(","), ...lines].join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob);
    a.download = `hostel-report-${level}-${from}-to-${to}.csv`; a.click(); URL.revokeObjectURL(a.href);
  }

  if (allowed === false) return <main><div className="card">Admin access only.</div></main>;
  if (allowed === null) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  const preset = (days: number) => { setTo(todayStr()); setFrom(addDays(todayStr(), -days)); };

  return (
    <main className="wide">
      <div className="no-print">
        <h1>Reports &amp; reconciliation</h1>
        <p><a href="/admin/dashboard">← Dashboard</a></p>
        <button className={`btn sm`} style={{ background: tab === "report" ? undefined : "#64748b" }} onClick={() => setTab("report")}>Financial report</button>{" "}
        <button className={`btn sm`} style={{ background: tab === "recon" ? undefined : "#64748b" }} onClick={() => setTab("recon")}>Reconciliation</button>
      </div>

      {tab === "report" && (
        <>
          <div className="no-print" style={{ marginTop: 12 }}>
            <input className="sel" type="date" aria-label="From" value={from} onChange={(e) => setFrom(e.target.value)} />
            <input className="sel" type="date" aria-label="To" value={to} onChange={(e) => setTo(e.target.value)} />
            <select className="sel" aria-label="Batch" value={batch} onChange={(e) => setBatch(e.target.value)}>
              <option value="all">All my batches</option>{batches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
            <select className="sel" aria-label="Level" value={level} onChange={(e) => setLevel(e.target.value as any)}>
              <option value="student">Per student</option><option value="batch">Per batch</option><option value="hostel">Entire hostel</option>
            </select>
            <p>
              <button className="btn sm" onClick={() => preset(0)}>Today</button>{" "}
              <button className="btn sm" onClick={() => preset(6)}>7 days</button>{" "}
              <button className="btn sm" onClick={() => { setFrom(todayStr().slice(0, 8) + "01"); setTo(todayStr()); }}>This month</button>{" "}
              <button className="btn sm" onClick={run}>Run report</button>{" "}
              <button className="btn sm" disabled={!rows.length} onClick={csv}>Export CSV</button>{" "}
              <button className="btn sm" onClick={() => window.print()}>Print / PDF</button>
            </p>
          </div>
          <h2 className="print-only">Hostel financial report · {from} to {to}</h2>
          {err && <div className="msg err" role="alert">{err}</div>}
          {loading ? <div className="card" aria-busy="true">Loading…</div> : rows.length === 0 ? <div className="card">No data for this selection.</div> : (
            <div className="card tblwrap">
              <table className="t">
                <thead><tr><th>ID</th><th>Name / group</th>{COLS.map(([, l]) => <th key={l}>{l}</th>)}<th>Booked</th><th>Eaten</th></tr></thead>
                <tbody>
                  {(table as any[]).map((r) => (
                    <tr key={r.key}><td>{r.code}</td><td>{r.name}</td>{COLS.map(([k]) => <td key={k}>{money(r[k])}</td>)}<td>{r.meals_booked}</td><td>{r.meals_consumed}</td></tr>
                  ))}
                  <tr style={{ fontWeight: 700 }}><td colSpan={2}>Total</td>{COLS.map(([k]) => <td key={k}>{money(total[k])}</td>)}<td>{total.meals_booked}</td><td>{total.meals_consumed}</td></tr>
                </tbody>
              </table>
              <p><small>Amounts in BDT. Deposits are student wallet liabilities, not hostel profit. Meal charges are recognised only after consumption is confirmed. Closing = opening + all movements; refunds are shown as recorded (negative = paid back to student).</small></p>
            </div>
          )}
        </>
      )}

      {tab === "recon" && (
        <div style={{ marginTop: 12 }}>
          {err && <div className="msg err" role="alert">{err}</div>}
          {loading || issues === null ? <div className="card" aria-busy="true">Checking ledger…</div> : (
            <>
              <button className="btn sm no-print" onClick={run}>Re-run checks</button>
              {CHECKS.map((c) => {
                const list = issues.filter((i) => i.check_name === c);
                return (
                  <div className="card" key={c}>
                    <b>{list.length === 0 ? "✔ OK" : `⚠ ${list.length} issue(s)`}</b> · {c}
                    {list.length > 0 && <ul style={{ paddingLeft: 18 }}>{list.slice(0, 50).map((i, n) => <li key={n}>{i.student_code}: {i.detail}</li>)}</ul>}
                  </div>
                );
              })}
            </>
          )}
        </div>
      )}
    </main>
  );
}
