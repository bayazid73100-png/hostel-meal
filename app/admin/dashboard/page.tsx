"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka } from "@/lib/supabase";
import Bars from "@/components/Bars";

const dhakaDate = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(d);
const addDays = (iso: string, n: number) => { const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const short = (iso: string) => new Date(iso + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
const LOW = 8000; // ৳80, low-balance threshold (poisha)

type M = {
  students: number; active: number; batches: number;
  bk: Record<string, number>; eaten: Record<string, number>;
  low: number; neg: number; depToday: number; chgToday: number; liab: number; negTotal: number;
  days: string[]; consByDay: Record<string, { lunch: number; dinner: number }>;
  moneyByDay: Record<string, { dep: number; chg: number }>;
  batchPart: { name: string; booked: number; total: number }[];
  dist: [string, number][]; monthSpend: number;
};

export default function AdminDashboard() {
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);
  const [m, setM] = useState<M | null>(null);
  const [err, setErr] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const { data: { session } } = await supabase.auth.getSession();
        if (!session) return router.replace("/login");
        const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
        setRole(me?.role ?? "none");
        if (!me || !["super_admin", "batch_admin"].includes(me.role)) return;

        const today = dhakaDate(new Date()), tmr = addDays(today, 1), from = addDays(today, -13);
        const monthStart = today.slice(0, 8) + "01";
        const [st, bt, bk, co, tx, wl] = await Promise.all([
          supabase.from("students").select("id,status,batches(name)").limit(5000),
          supabase.from("batches").select("id", { count: "exact", head: true }).eq("is_active", true),
          supabase.from("meal_bookings").select("meal,meal_date,status,students(batches(name))")
            .in("meal_date", [today, tmr]).in("status", ["booked", "authorized_exception", "consumed"]).limit(10000),
          supabase.from("meal_consumptions").select("meal,meal_date,price").is("reversed_at", null).gte("meal_date", monthStart < from ? monthStart : from).limit(20000),
          supabase.from("wallet_transactions").select("type,delta,created_at").in("type", ["deposit", "meal_charge"])
            .gte("created_at", `${from}T00:00:00+06:00`).limit(20000),
          supabase.from("student_wallets").select("student_id,balance").limit(5000),
        ]);
        if (st.error || bk.error || co.error || tx.error || wl.error) throw new Error("Could not load dashboard data.");

        const students = st.data ?? [];
        const days = Array.from({ length: 14 }, (_, i) => addDays(from, i));
        const bkc: Record<string, number> = {};
        const bpart: Record<string, number> = {};
        (bk.data ?? []).forEach((r: any) => {
          bkc[`${r.meal_date === today ? "t" : "n"}-${r.meal}`] = (bkc[`${r.meal_date === today ? "t" : "n"}-${r.meal}`] ?? 0) + 1;
          if (r.meal_date === tmr) { const n = r.students?.batches?.name ?? "?"; bpart[n] = (bpart[n] ?? 0) + 1; }
        });
        const eaten: Record<string, number> = {}, cons: M["consByDay"] = {};
        let monthSpend = 0;
        (co.data ?? []).forEach((r) => {
          if (r.meal_date === today) eaten[r.meal] = (eaten[r.meal] ?? 0) + 1;
          if (r.meal_date >= monthStart) monthSpend += r.price;
          if (r.meal_date >= from) { const c = (cons[r.meal_date] ??= { lunch: 0, dinner: 0 }); (c as any)[r.meal]++; }
        });
        const money: M["moneyByDay"] = {};
        let depToday = 0, chgToday = 0;
        (tx.data ?? []).forEach((r) => {
          const d = dhakaDate(new Date(r.created_at));
          const x = (money[d] ??= { dep: 0, chg: 0 });
          if (r.type === "deposit") { x.dep += r.delta; if (d === today) depToday += r.delta; }
          else { x.chg += -r.delta; if (d === today) chgToday += -r.delta; }
        });
        const bal = (wl.data ?? []).map((w) => w.balance as number);
        const totals: Record<string, number> = {};
        students.forEach((s: any) => { const n = s.batches?.name ?? "?"; totals[n] = (totals[n] ?? 0) + 1; });
        const buckets: [string, (b: number) => boolean][] = [
          ["Negative", (b) => b < 0], ["৳0 – 79", (b) => b >= 0 && b < LOW], ["৳80 – 299", (b) => b >= LOW && b < 30000],
          ["৳300 – 999", (b) => b >= 30000 && b < 100000], ["৳1000+", (b) => b >= 100000],
        ];
        setM({
          students: students.length, active: students.filter((s: any) => s.status === "active").length, batches: bt.count ?? 0,
          bk: bkc, eaten, low: bal.filter((b) => b >= 0 && b < LOW).length, neg: bal.filter((b) => b < 0).length,
          depToday, chgToday, liab: bal.filter((b) => b > 0).reduce((a, b) => a + b, 0),
          negTotal: bal.filter((b) => b < 0).reduce((a, b) => a + b, 0),
          days, consByDay: cons, moneyByDay: money,
          batchPart: Object.keys(totals).sort().map((n) => ({ name: n, booked: bpart[n] ?? 0, total: totals[n] })),
          dist: buckets.map(([l, f]) => [l, bal.filter(f).length]), monthSpend,
        });
      } catch (e: any) { setErr(e.message ?? "Error"); }
    })();
  }, []);

  if (role === null && !err) return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (role !== null && !["super_admin", "batch_admin"].includes(role)) return <main><div className="card">Admin access only.</div></main>;
  if (err) return <main><div className="msg err" role="alert">{err}</div></main>;
  if (!m) return <main><div className="card" aria-busy="true">Loading…</div></main>;

  const stat = (label: string, v: string | number, warn = false) =>
    <div className="card" style={{ margin: 0 }}><div style={{ fontSize: ".8rem" }}>{label}</div>
      <div style={{ fontSize: "1.4rem", fontWeight: 700 }} className={warn ? "warn" : ""}>{warn ? "⚠ " : ""}{v}</div></div>;
  const g = (k: string) => m.bk[k] ?? 0;
  const lunchTot = m.days.reduce((a, d) => a + (m.consByDay[d]?.lunch ?? 0), 0);
  const dinnerTot = m.days.reduce((a, d) => a + (m.consByDay[d]?.dinner ?? 0), 0);

  return (
    <main className="wide">
      <h1>Admin dashboard</h1>
      <p>
        <a href="/admin/meals">Daily meals</a> · <a href="/admin/deposits">Deposits</a> · <a href="/admin/reports">Reports</a>
        {role === "super_admin" && <> · <a href="/admin/exceptions">Exceptions</a> · <a href="/admin/settings">Prices &amp; deadline</a> · <a href="/admin/people">People &amp; batches</a></>}
      </p>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(150px,1fr))", gap: 10, marginBottom: 12 }}>
        {stat("Registered students", m.students)}{stat("Active students", m.active)}{stat("Batches", m.batches)}
        {stat("Today lunch booked", g("t-lunch"))}{stat("Today dinner booked", g("t-dinner"))}
        {stat("Tomorrow lunch booked", g("n-lunch"))}{stat("Tomorrow dinner booked", g("n-dinner"))}
        {stat("Lunch eaten today", m.eaten.lunch ?? 0)}{stat("Dinner eaten today", m.eaten.dinner ?? 0)}
        {stat("Low balance", m.low, m.low > 0)}{stat("Negative balance", m.neg, m.neg > 0)}
        {stat("Deposits today", taka(m.depToday))}{stat("Meal charges today", taka(m.chgToday))}
        {stat("Wallet liabilities", taka(m.liab))}{stat("Owed by students (negative)", taka(Math.abs(m.negTotal)))}
        {stat("Meal expenditure this month", taka(m.monthSpend))}
      </div>

      <Bars title="Daily meals eaten (last 14 days)" series={[{ name: "Lunch", color: "#0d9488" }, { name: "Dinner", color: "#1e2a5a" }]}
        rows={m.days.map((d) => ({ label: short(d), values: [m.consByDay[d]?.lunch ?? 0, m.consByDay[d]?.dinner ?? 0] }))} />
      <Bars title="Lunch vs dinner (14-day total)" series={[{ name: "Meals", color: "#0d9488" }]}
        rows={[{ label: "Lunch", values: [lunchTot] }, { label: "Dinner", values: [dinnerTot] }]} />
      <Bars title="Tomorrow's booking participation by batch" series={[{ name: "Booked", color: "#0d9488" }]}
        rows={m.batchPart.map((b) => ({ label: `${b.name} (${b.booked} of ${b.total} students)`, values: [b.booked] }))} />
      <Bars title="Deposits vs meal charges (last 14 days)" series={[{ name: "Deposits", color: "#15803d" }, { name: "Meal charges", color: "#b45309" }]}
        rows={m.days.map((d) => ({ label: short(d), values: [m.moneyByDay[d]?.dep ?? 0, m.moneyByDay[d]?.chg ?? 0], fmt: taka }))} />
      <Bars title="Wallet balance distribution (students)" series={[{ name: "Students", color: "#1e2a5a" }]}
        rows={m.dist.map(([l, n]) => ({ label: l, values: [n] }))} />
    </main>
  );
}
