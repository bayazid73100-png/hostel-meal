// Dependency-free horizontal bar chart. Values are printed next to bars (not color-only).
type Series = { name: string; color: string };
export type BarRow = { label: string; values: number[]; fmt?: (n: number) => string };

export default function Bars({ title, series, rows, empty = "No data yet." }:
  { title: string; series: Series[]; rows: BarRow[]; empty?: string }) {
  const max = Math.max(1, ...rows.flatMap((r) => r.values));
  const none = rows.every((r) => r.values.every((v) => v === 0));
  return (
    <section className="card" aria-label={title}>
      <b>{title}</b>
      {series.length > 1 && (
        <div style={{ fontSize: ".8rem", margin: "4px 0" }}>
          {series.map((s) => (
            <span key={s.name} style={{ marginRight: 12 }}>
              <span style={{ display: "inline-block", width: 10, height: 10, background: s.color, borderRadius: 2 }} /> {s.name}
            </span>
          ))}
        </div>
      )}
      {none ? <p>{empty}</p> : rows.map((r) => (
        <div key={r.label} style={{ margin: "6px 0" }}>
          <div style={{ fontSize: ".8rem" }}>{r.label}</div>
          {r.values.map((v, i) => (
            <div key={i} style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <div style={{ background: series[i].color, height: 10, borderRadius: 5, width: `${Math.max(1, (v / max) * 100)}%`, maxWidth: "75%" }} />
              <span style={{ fontSize: ".75rem" }}>{(r.fmt ?? String)(v)}</span>
            </div>
          ))}
        </div>
      ))}
    </section>
  );
}
