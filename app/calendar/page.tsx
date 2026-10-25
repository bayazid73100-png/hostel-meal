"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

type B = { meal_date: string; meal: "lunch" | "dinner"; status: string };

// Symbol + text, so status never depends on color alone.
const ST: Record<string, { sym: string; text: string; bg: string }> = {
  booked: { sym: "🕒", text: "Booked", bg: "#e0e7ff" },
  consumed: { sym: "✔", text: "Eaten", bg: "#dcfce7" },
  cancelled: { sym: "✖", text: "Cancelled", bg: "#f1f5f9" },
  missed: { sym: "⚠", text: "Missed", bg: "#fef3c7" },
  authorized_exception: { sym: "★", text: "Exception", bg: "#fce7f3" },
};
const pad = (n: number) => String(n).padStart(2, "0");

export default function Calendar() {
  const router = useRouter();
  const now = new Date(new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date()) + "T00:00:00Z");
  const [y, setY] = useState(now.getUTCFullYear());
  const [m, setM] = useState(now.getUTCMonth()); // 0-11
  const [data, setData] = useState<Record<string, Partial<Record<"lunch" | "dinner", string>>>>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      setLoading(true);
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return router.replace("/login");
      const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
      const { data: rows } = await supabase.from("meal_bookings").select("meal_date,meal,status")
        .gte("meal_date", `${y}-${pad(m + 1)}-01`).lte("meal_date", `${y}-${pad(m + 1)}-${pad(last)}`);
      const map: typeof data = {};
      ((rows ?? []) as B[]).forEach((r) => { (map[r.meal_date] ??= {})[r.meal] = r.status; });
      setData(map); setLoading(false);
    })();
  }, [y, m]);

  const shift = (d: number) => { const t = new Date(Date.UTC(y, m + d, 1)); setY(t.getUTCFullYear()); setM(t.getUTCMonth()); };
  const lead = new Date(Date.UTC(y, m, 1)).getUTCDay();
  const days = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const title = new Date(Date.UTC(y, m, 1)).toLocaleString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });

  const chip = (s?: string, label?: string) => s && ST[s]
    ? <div style={{ background: ST[s].bg, borderRadius: 6, padding: "1px 3px", margin: "2px 0", fontSize: ".7rem" }}
        title={`${label}: ${ST[s].text}`} aria-label={`${label} ${ST[s].text}`}>{label?.[0]}{ST[s].sym}</div>
    : <div style={{ fontSize: ".7rem", color: "#94a3b8" }}>{label?.[0]}·</div>;

  return (
    <main>
      <p><a href="/dashboard">← Dashboard</a></p>
      <div className="card" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <button className="btn sm" onClick={() => shift(-1)} aria-label="Previous month">‹</button>
        <b>{title}</b>
        <button className="btn sm" onClick={() => shift(1)} aria-label="Next month">›</button>
      </div>

      <div className="card" aria-busy={loading}>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", gap: 4, textAlign: "center" }}>
          {["S", "M", "T", "W", "T", "F", "S"].map((d, i) => <b key={i}>{d}</b>)}
          {Array.from({ length: lead }).map((_, i) => <div key={`e${i}`} />)}
          {Array.from({ length: days }).map((_, i) => {
            const key = `${y}-${pad(m + 1)}-${pad(i + 1)}`;
            return (
              <div key={key} style={{ border: "1px solid #e2e8f0", borderRadius: 8, padding: 2, minHeight: 64 }}>
                <div style={{ fontSize: ".75rem" }}>{i + 1}</div>
                {chip(data[key]?.lunch, "Lunch")}
                {chip(data[key]?.dinner, "Dinner")}
              </div>
            );
          })}
        </div>
      </div>

      <div className="card">
        <b>Key</b> (L = lunch, D = dinner)
        <ul style={{ paddingLeft: 18 }}>
          {Object.values(ST).map((s) => <li key={s.text}>{s.sym} {s.text}</li>)}
        </ul>
        <small>A booking is not a meal eaten. “Eaten” appears only after an admin confirms.</small>
      </div>
    </main>
  );
}
