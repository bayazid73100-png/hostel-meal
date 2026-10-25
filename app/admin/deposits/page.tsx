"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka } from "@/lib/supabase";

type Stu = { id: string; student_code: string; batches: { name: string } | null; profiles: { full_name: string } | null };
type Txn = { id: string; type: string; delta: number; method: string | null; reference: string | null; note: string | null; created_at: string; reverses_id: string | null };

const TYPES: Record<string, string> = {
  deposit: "Deposit", refund: "Refund (pay back to student)",
  credit_adj: "Credit adjustment", debit_adj: "Debit adjustment",
};
const METHODS = ["cash", "bkash", "nagad", "bank_transfer", "other"];

/** "40.5" -> 4050 poisha, integer math only. Returns null if invalid. */
function toPoisha(v: string): number | null {
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(v.trim());
  if (!m) return null;
  const n = Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0") || 0);
  return n > 0 ? n : null;
}

export default function Deposits() {
  const router = useRouter();
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [students, setStudents] = useState<Stu[]>([]);
  const [bal, setBal] = useState<Record<string, number>>({});
  const [q, setQ] = useState("");
  const [sel, setSel] = useState<Stu | null>(null);
  const [txns, setTxns] = useState<Txn[]>([]);
  const [type, setType] = useState("deposit");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState("cash");
  const [ref, setRef] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  async function loadStudents() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    if (!me || !["super_admin", "batch_admin"].includes(me.role)) return setAllowed(false);
    setAllowed(true);
    // RLS: only students in this admin's batches come back.
    const { data } = await supabase.from("students")
      .select("id,student_code,batches(name),profiles(full_name)").order("student_code").limit(1000);
    setStudents((data ?? []) as unknown as Stu[]);
    const { data: w } = await supabase.from("student_wallets").select("student_id,balance");
    setBal(Object.fromEntries((w ?? []).map((x) => [x.student_id, x.balance])));
  }
  async function loadTxns(id: string) {
    const { data } = await supabase.from("wallet_transactions")
      .select("id,type,delta,method,reference,note,created_at,reverses_id")
      .eq("student_id", id).order("created_at", { ascending: false }).limit(15);
    setTxns((data ?? []) as Txn[]);
  }
  useEffect(() => { loadStudents(); }, []);
  useEffect(() => { if (sel) loadTxns(sel.id); }, [sel]);

  const list = useMemo(() => students.filter((s) =>
    !q || s.student_code.toLowerCase().includes(q.toLowerCase()) ||
    (s.profiles?.full_name ?? "").toLowerCase().includes(q.toLowerCase())).slice(0, 30), [students, q]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!sel) return;
    const p = toPoisha(amount);
    if (p === null) return setMsg({ ok: false, text: "Enter a valid amount, e.g. 500 or 500.50" });
    const label = TYPES[type].split(" (")[0];
    if (!window.confirm(`${label} of ${taka(p)} for ${sel.profiles?.full_name} (${sel.student_code}). This is recorded permanently; mistakes need a reversal. Continue?`)) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("post_transaction", {
      p_student: sel.id, p_type: type, p_amount: p, p_method: method, p_ref: ref || null, p_note: note || null,
    });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: error.message });
    setMsg({ ok: true, text: `${label} of ${taka(p)} recorded.` });
    setAmount(""); setRef(""); setNote("");
    loadStudents(); loadTxns(sel.id);
  }

  async function reverse(id: string) {
    const reason = window.prompt("Reason for reversal (required):");
    if (!reason) return;
    const { error } = await supabase.rpc("reverse_transaction", { p_txn: id, p_reason: reason });
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Transaction reversed." });
    if (!error && sel) { loadStudents(); loadTxns(sel.id); }
  }

  if (allowed === false) return <main><div className="card">Admin access only.</div></main>;
  if (allowed === null) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  const reversedIds = new Set(txns.map((t) => t.reverses_id).filter(Boolean));

  return (
    <main className="wide">
      <h1>Deposits &amp; adjustments</h1>
      <input className="sel" style={{ width: "100%" }} placeholder="Search name or student ID" aria-label="Search students"
        value={q} onChange={(e) => setQ(e.target.value)} />

      {!sel && (
        <div className="card tblwrap">
          {list.length === 0 ? "No students found." : (
            <table className="t"><thead><tr><th>Student</th><th>ID</th><th>Batch</th><th>Balance</th><th></th></tr></thead>
              <tbody>{list.map((s) => (
                <tr key={s.id}>
                  <td>{s.profiles?.full_name}</td><td>{s.student_code}</td><td>{s.batches?.name}</td>
                  <td>{taka(bal[s.id] ?? 0)}{(bal[s.id] ?? 0) < 0 && <span className="warn"> ⚠ Negative</span>}</td>
                  <td><button className="btn sm" onClick={() => { setSel(s); setMsg(null); }}>Select</button></td>
                </tr>))}</tbody></table>
          )}
        </div>
      )}

      {sel && (
        <>
          <div className="card">
            <b>{sel.profiles?.full_name}</b> · {sel.student_code} · {sel.batches?.name}
            <div className="balance">{taka(bal[sel.id] ?? 0)}</div>
            <button className="btn sm" style={{ background: "#64748b" }} onClick={() => { setSel(null); setTxns([]); }}>Change student</button>
          </div>

          <form className="card" onSubmit={submit}>
            <label htmlFor="type">Type</label><br />
            <select id="type" className="sel" value={type} onChange={(e) => setType(e.target.value)}>
              {Object.entries(TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select><br />
            <label htmlFor="amt">Amount (৳)</label><br />
            <input id="amt" className="sel" inputMode="decimal" required value={amount} onChange={(e) => setAmount(e.target.value)} /><br />
            <label htmlFor="mth">Payment method</label><br />
            <select id="mth" className="sel" value={method} onChange={(e) => setMethod(e.target.value)}>
              {METHODS.map((m) => <option key={m}>{m}</option>)}
            </select><br />
            <label htmlFor="ref">Reference (bKash/Nagad TrxID, bank ref)</label><br />
            <input id="ref" className="sel" value={ref} onChange={(e) => setRef(e.target.value)} /><br />
            <label htmlFor="note">Note</label><br />
            <input id="note" className="sel" value={note} onChange={(e) => setNote(e.target.value)} /><br />
            <button className="btn" disabled={busy}>{busy ? "Saving…" : "Record transaction"}</button>
            {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}
          </form>

          <div className="card tblwrap">
            <b>Recent transactions</b>
            <table className="t"><thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Method / ref</th><th></th></tr></thead>
              <tbody>{txns.map((t) => (
                <tr key={t.id}>
                  <td>{new Date(t.created_at).toLocaleString("en-GB", { timeZone: "Asia/Dhaka" })}</td>
                  <td>{t.type.replace("_", " ")}</td>
                  <td>{t.delta > 0 ? "+" : "−"}{taka(Math.abs(t.delta))}</td>
                  <td>{[t.method, t.reference].filter(Boolean).join(" · ")}</td>
                  <td>{t.type === "reversal" ? "↩ Reversal" : reversedIds.has(t.id) ? "Reversed"
                    : t.type !== "meal_charge" && t.type !== "opening"
                      ? <button className="btn sm" style={{ background: "#b91c1c" }} onClick={() => reverse(t.id)}>Reverse</button> : ""}</td>
                </tr>))}</tbody></table>
          </div>
        </>
      )}
    </main>
  );
}
