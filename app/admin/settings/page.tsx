"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka, toPoisha, dhakaTomorrow } from "@/lib/supabase";

type P = { id: number; meal: string; price: number; effective_from: string };

export default function Settings() {
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);
  const [prices, setPrices] = useState<P[]>([]);
  const [deadline, setDeadline] = useState("22:00");
  const [meal, setMeal] = useState("lunch");
  const [amount, setAmount] = useState("");
  const [from, setFrom] = useState(dhakaTomorrow());
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date());

  async function load() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return router.replace("/login");
    const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
    setRole(me?.role ?? "none");
    if (me?.role !== "super_admin") return;
    const [p, s] = await Promise.all([
      supabase.from("meal_prices").select("id,meal,price,effective_from").order("effective_from", { ascending: false }),
      supabase.from("settings").select("value").eq("key", "booking_deadline").single(),
    ]);
    setPrices((p.data ?? []) as P[]);
    if (s.data) setDeadline(s.data.value);
  }
  useEffect(() => { load(); }, []);

  const current = (m: string) => prices.find((p) => p.meal === m && p.effective_from <= today);

  async function savePrice(e: React.FormEvent) {
    e.preventDefault();
    const p = toPoisha(amount);
    if (p === null) return setMsg({ ok: false, text: "Enter a valid price, e.g. 40 or 42.50" });
    if (!window.confirm(`Set ${meal} price to ${taka(p)} from ${from}? Past meals keep their old price.`)) return;
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("set_meal_price", { p_meal: meal, p_price: p, p_from: from });
    setBusy(false);
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Price saved." });
    if (!error) { setAmount(""); load(); }
  }

  async function saveDeadline() {
    if (!window.confirm(`Change the daily booking deadline to ${deadline} (Bangladesh time)?`)) return;
    const { error } = await supabase.rpc("set_booking_deadline", { p_time: deadline });
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Deadline updated." });
  }

  if (role === null) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (role !== "super_admin") return <main><div className="card">Super Admin access only.</div></main>;

  return (
    <main className="wide">
      <h1>Meal prices &amp; booking deadline</h1>
      <p><a href="/admin/dashboard">← Dashboard</a></p>

      <div className="card">
        <b>Current prices</b>
        <p>Lunch: <b>{taka(current("lunch")?.price ?? 0)}</b> · Dinner: <b>{taka(current("dinner")?.price ?? 0)}</b></p>
      </div>

      <form className="card" onSubmit={savePrice}>
        <b>Set a new price</b><br /><br />
        <label htmlFor="m">Meal</label><br />
        <select id="m" className="sel" value={meal} onChange={(e) => setMeal(e.target.value)}>
          <option value="lunch">Lunch</option><option value="dinner">Dinner</option>
        </select><br />
        <label htmlFor="a">New price (৳)</label><br />
        <input id="a" className="sel" inputMode="decimal" required value={amount} onChange={(e) => setAmount(e.target.value)} /><br />
        <label htmlFor="f">Effective from</label><br />
        <input id="f" type="date" className="sel" min={today} value={from} onChange={(e) => setFrom(e.target.value)} /><br />
        <button className="btn" disabled={busy}>{busy ? "Saving…" : "Save price"}</button>
      </form>

      <div className="card">
        <label htmlFor="dl"><b>Daily booking deadline</b> (Bangladesh time, applies to next-day booking)</label><br />
        <input id="dl" className="sel" value={deadline} onChange={(e) => setDeadline(e.target.value)} placeholder="22:00" />
        <button className="btn sm" onClick={saveDeadline}>Save deadline</button>
      </div>
      {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}

      <div className="card tblwrap">
        <b>Price history</b>
        <table className="t"><thead><tr><th>Meal</th><th>Price</th><th>Effective from</th><th></th></tr></thead>
          <tbody>{prices.map((p) => (
            <tr key={p.id}><td>{p.meal}</td><td>{taka(p.price)}</td><td>{p.effective_from}</td>
              <td>{p.effective_from > today ? "Scheduled" : p.id === current(p.meal)?.id ? "Current" : "Past"}</td></tr>
          ))}</tbody></table>
      </div>
    </main>
  );
}
