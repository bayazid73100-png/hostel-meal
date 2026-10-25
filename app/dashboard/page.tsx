"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase, taka, dhakaTomorrow } from "@/lib/supabase";

type Txn = { id: string; type: string; delta: number; method: string | null; created_at: string };
type Eaten = { id: string; meal_date: string; meal: string; price: number };

const LABEL: Record<string, string> = {
  opening: "Opening", deposit: "Deposit", refund: "Refund", credit_adj: "Credit adjustment",
  debit_adj: "Debit adjustment", meal_charge: "Meal charge", reversal: "Reversal",
};

export default function Dashboard() {
  const router = useRouter();
  const [state, setState] = useState<"loading" | "ready" | "none">("loading");
  const [name, setName] = useState("");
  const [stu, setStu] = useState<{ student_code: string; roll_no: string | null; batch: string } | null>(null);
  const [w, setW] = useState<{ balance: number; available: number } | null>(null);
  const [txns, setTxns] = useState<Txn[]>([]);
  const [eaten, setEaten] = useState<Eaten[]>([]);
  const [month, setMonth] = useState({ count: 0, spend: 0 });
  const [tomorrow, setTomorrow] = useState<string[]>([]);
  const date = dhakaTomorrow();

  useEffect(() => {
    (async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return router.replace("/login");

      const { data: s } = await supabase.from("students")
        .select("id,student_code,roll_no,batches(name)").limit(1).single();
      if (!s) {
        const { data: me } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
        if (me && me.role !== "student") return router.replace("/admin/dashboard");
        return setState("none");
      }
      const { data: p } = await supabase.from("profiles").select("full_name").eq("id", session.user.id).single();
      setName(p?.full_name ?? "");
      setStu({ student_code: s.student_code, roll_no: s.roll_no, batch: (s as any).batches?.name ?? "" });

      const monthStart = date.slice(0, 8) + "01";
      const [wal, tx, ea, mo, bk] = await Promise.all([
        supabase.from("student_wallets").select("balance,available").eq("student_id", s.id).single(),
        supabase.from("wallet_transactions").select("id,type,delta,method,created_at")
          .eq("student_id", s.id).order("created_at", { ascending: false }).limit(5),
        supabase.from("meal_consumptions").select("id,meal_date,meal,price")
          .eq("student_id", s.id).order("meal_date", { ascending: false }).limit(5),
        supabase.from("meal_consumptions").select("price").eq("student_id", s.id).gte("meal_date", monthStart),
        supabase.from("meal_bookings").select("meal").eq("student_id", s.id).eq("meal_date", date)
          .in("status", ["booked", "authorized_exception"]),
      ]);
      setW(wal.data as any);
      setTxns((tx.data ?? []) as Txn[]);
      setEaten((ea.data ?? []) as Eaten[]);
      setMonth({ count: mo.data?.length ?? 0, spend: (mo.data ?? []).reduce((a, r) => a + r.price, 0) });
      setTomorrow((bk.data ?? []).map((r) => r.meal));
      setState("ready");
    })();
  }, []);

  if (state === "loading") return <main><div className="card" aria-busy="true">Loading…</div></main>;
  if (state === "none") return <main><div className="card">No student account linked to this login. Contact the hostel admin.</div></main>;

  return (
    <main>
      <p>{name} · ID {stu?.student_code}{stu?.roll_no ? ` · Roll ${stu.roll_no}` : ""} · {stu?.batch}</p>

      <div className="card">
        <div>Current balance</div>
        <div className="balance">{taka(w?.balance ?? 0)}</div>
        <div>Available after reservations: {taka(w?.available ?? 0)}</div>
        {(w?.balance ?? 0) < 0 && <div className="warn">⚠ Negative balance. Additional payment required.</div>}
        {(w?.balance ?? 0) >= 0 && (w?.available ?? 0) < 8000 && <div className="warn">⚠ Low balance.</div>}
      </div>

      <div className="card">
        <div>Meals consumed this month: <b>{month.count}</b></div>
        <div>Expenditure this month: <b>{taka(month.spend)}</b></div>
      </div>

      <div className="card">
        <div>Tomorrow ({date})</div>
        <b>{tomorrow.length ? `Booked: ${tomorrow.join(" + ")}` : "No meals booked"}</b>
        <p><a href="/book">{tomorrow.length ? "Change booking" : "Book meals"}</a></p>
      </div>

      <div className="card">
        <b>Recent transactions</b>
        {txns.length === 0 && <p>No transactions yet.</p>}
        <ul style={{ paddingLeft: 18 }}>
          {txns.map((t) => (
            <li key={t.id}>
              {LABEL[t.type] ?? t.type}: {t.delta > 0 ? "+" : "−"}{taka(Math.abs(t.delta))}
              {t.method ? ` (${t.method})` : ""} · {new Date(t.created_at).toLocaleDateString("en-GB", { timeZone: "Asia/Dhaka" })}
            </li>
          ))}
        </ul>
      </div>

      <div className="card">
        <b>Recent meals eaten (confirmed)</b>
        {eaten.length === 0 && <p>None yet.</p>}
        <ul style={{ paddingLeft: 18 }}>
          {eaten.map((e) => <li key={e.id}>{e.meal_date} · {e.meal} · {taka(e.price)}</li>)}
        </ul>
      </div>

      <div className="card">
        <a href="/wallet">Full wallet history</a> · <a href="/calendar">Meal calendar</a>
      </div>

      <div className="card">
        <b>Payment instructions</b>
        <p>Pay your hostel admin by cash, bKash, Nagad or bank transfer. Your balance updates after the admin records the deposit.</p>
      </div>

    </main>
  );
}
