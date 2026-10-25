"use client";
import { useEffect, useState } from "react";
import { supabase, taka, dhakaTomorrow } from "@/lib/supabase";

type Meal = "lunch" | "dinner";
type Wallet = { student_id: string; balance: number; reserved: number; available: number };

export default function BookPage() {
  const date = dhakaTomorrow();
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [prices, setPrices] = useState<Record<Meal, number>>({ lunch: 0, dinner: 0 });
  const [sel, setSel] = useState<Set<Meal>>(new Set());
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);

  async function load() {
    // RLS limits these queries to the signed-in student's own rows.
    const { data: w } = await supabase.from("student_wallets").select("*").limit(1).single();
    const { data: p } = await supabase.from("meal_prices").select("meal,price,effective_from")
      .lte("effective_from", date).order("effective_from", { ascending: false });
    const pr: Record<Meal, number> = { lunch: 0, dinner: 0 };
    p?.forEach((r) => { if (!pr[r.meal as Meal]) pr[r.meal as Meal] = r.price; });
    setPrices(pr);
    if (w) {
      setWallet(w);
      const { data: b } = await supabase.from("meal_bookings").select("meal")
        .eq("student_id", w.student_id).eq("meal_date", date).in("status", ["booked", "authorized_exception"]);
      setSel(new Set((b ?? []).map((r) => r.meal as Meal)));
    }
    setLoading(false);
  }
  useEffect(() => { load(); }, []);

  const toggle = (m: Meal) => setSel((s) => { const n = new Set(s); n.has(m) ? n.delete(m) : n.add(m); return n; });
  const total = [...sel].reduce((a, m) => a + prices[m], 0);
  const shortfall = wallet ? Math.max(0, total - wallet.available) : 0;

  async function confirm() {
    if (!wallet) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("book_meals", {
      p_student: wallet.student_id, p_date: date, p_meals: [...sel],
    });
    setMsg(error ? { ok: false, text: error.message }
                 : { ok: true, text: sel.size ? `Booked for ${date}.` : `No meals for ${date}.` });
    setBusy(false);
    if (!error) load();
  }

  if (loading) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (!wallet) return <main><div className="card">No student account found.</div></main>;

  return (
    <main>
      <div className="card">
        <div>Current balance</div>
        <div className="balance">{taka(wallet.balance)}</div>
        <div>Available: {taka(wallet.available)}</div>
        {wallet.balance < 0 && <div className="warn">⚠ Negative balance — please deposit.</div>}
      </div>

      <h2>Meals for {date}</h2>
      <p>Deadline: 10:00 PM Bangladesh time (checked on the server).</p>

      {(["lunch", "dinner"] as Meal[]).map((m) => (
        <button key={m} className="meal" aria-pressed={sel.has(m)} onClick={() => toggle(m)}>
          <span>{m === "lunch" ? "🍛 Lunch" : "🍽 Dinner"}</span>
          <span>{taka(prices[m])} · {sel.has(m) ? "✔ Selected" : "Not selected"}</span>
        </button>
      ))}

      <div className="card">
        <div>Estimated total: <b>{taka(total)}</b></div>
        {shortfall > 0 && <div className="warn">Additional {taka(shortfall)} needed.</div>}
      </div>

      <button className="btn" disabled={busy || shortfall > 0} onClick={confirm}>
        {busy ? "Saving…" : "Confirm booking"}
      </button>
      {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}
    </main>
  );
}
