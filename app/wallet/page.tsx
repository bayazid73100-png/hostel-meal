"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka } from "@/lib/supabase";

type Txn = { id: string; type: string; delta: number; method: string | null; reference: string | null; note: string | null; created_at: string };
const LABEL: Record<string, string> = {
  opening: "Opening balance", deposit: "Deposit", refund: "Refund", credit_adj: "Credit adjustment",
  debit_adj: "Debit adjustment", meal_charge: "Meal charge", reversal: "Reversal",
};
const PAGE = 50;

export default function Wallet() {
  const router = useRouter();
  const [ready, setReady] = useState(false);
  const [sid, setSid] = useState<string | null>(null);
  const [txns, setTxns] = useState<Txn[]>([]);
  const [sum, setSum] = useState<Record<string, number>>({});
  const [counts, setCounts] = useState({ booked: 0, consumed: 0 });
  const [limit, setLimit] = useState(PAGE);
  const [more, setMore] = useState(false);

  useEffect(() => {
    (async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return router.replace("/login");
      const { data: s } = await supabase.from("students").select("id").limit(1).single();
      if (!s) return setReady(true);
      setSid(s.id);

      // Totals are computed from the full ledger, not just the visible page.
      const { data: all } = await supabase.from("wallet_transactions").select("type,delta").eq("student_id", s.id);
      const t: Record<string, number> = {};
      (all ?? []).forEach((r) => { t[r.type] = (t[r.type] ?? 0) + r.delta; });
      setSum(t);

      const [b, c] = await Promise.all([
        supabase.from("meal_bookings").select("id", { count: "exact", head: true }).eq("student_id", s.id).neq("status", "cancelled"),
        supabase.from("meal_consumptions").select("id", { count: "exact", head: true }).eq("student_id", s.id).is("reversed_at", null),
      ]);
      setCounts({ booked: b.count ?? 0, consumed: c.count ?? 0 });
      setReady(true);
    })();
  }, []);

  useEffect(() => {
    if (!sid) return;
    supabase.from("wallet_transactions").select("id,type,delta,method,reference,note,created_at")
      .eq("student_id", sid).order("created_at", { ascending: false }).limit(limit + 1)
      .then(({ data }) => { const d = (data ?? []) as Txn[]; setMore(d.length > limit); setTxns(d.slice(0, limit)); });
  }, [sid, limit]);

  if (!ready) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (!sid) return <main><div className="card">No student account linked to this login.</div></main>;

  const balance = Object.values(sum).reduce((a, b) => a + b, 0);
  const signed = (n: number) => `${n < 0 ? "−" : n > 0 ? "+" : ""}${taka(Math.abs(n))}`;
  const rows: [string, number][] = [
    ["Opening balance", sum.opening ?? 0], ["Deposits", sum.deposit ?? 0], ["Refunds", sum.refund ?? 0],
    ["Credit adjustments", sum.credit_adj ?? 0], ["Debit adjustments", sum.debit_adj ?? 0],
    ["Meal charges", sum.meal_charge ?? 0], ["Reversals (net)", sum.reversal ?? 0],
  ];

  return (
    <main>
      <p><a href="/dashboard">← Dashboard</a></p>
      <div className="card">
        <div>Current balance</div>
        <div className="balance">{taka(balance)}</div>
        {balance < 0 && <div className="warn">⚠ Negative balance. Additional payment required.</div>}
      </div>

      <div className="card">
        <b>Summary</b>
        <table className="t"><tbody>
          {rows.map(([k, v]) => <tr key={k}><td>{k}</td><td style={{ textAlign: "right" }}>{signed(v)}</td></tr>)}
          <tr><td>Meals booked (not cancelled)</td><td style={{ textAlign: "right" }}>{counts.booked}</td></tr>
          <tr><td>Meals consumed (confirmed)</td><td style={{ textAlign: "right" }}>{counts.consumed}</td></tr>
        </tbody></table>
      </div>

      <div className="card">
        <b>Transactions</b>
        {txns.length === 0 ? <p>No transactions yet.</p> : (
          <ul style={{ listStyle: "none", padding: 0 }}>
            {txns.map((t) => (
              <li key={t.id} style={{ padding: "10px 0", borderBottom: "1px solid #e2e8f0" }}>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span>{LABEL[t.type] ?? t.type}</span><b>{signed(t.delta)}</b>
                </div>
                <small>
                  {new Date(t.created_at).toLocaleString("en-GB", { timeZone: "Asia/Dhaka" })}
                  {t.method ? ` · ${t.method}` : ""}{t.reference ? ` · ${t.reference}` : ""}{t.note ? ` · ${t.note}` : ""}
                </small>
              </li>
            ))}
          </ul>
        )}
        {more && <button className="btn" onClick={() => setLimit(limit + PAGE)}>Load more</button>}
      </div>
    </main>
  );
}
