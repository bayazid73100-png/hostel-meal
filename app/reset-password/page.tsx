"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

// Used for both: the password-reset email link, and "change password" for signed-in users.
export default function ResetPassword() {
  const router = useRouter();
  const [ready, setReady] = useState(false);
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === "PASSWORD_RECOVERY" || session) setReady(true);
    });
    supabase.auth.getSession().then(({ data }) => { if (data.session) setReady(true); });
    const t = setTimeout(() => setReady((r) => r), 4000);
    return () => { sub.subscription.unsubscribe(); clearTimeout(t); };
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setMsg(null);
    if (pw.length < 8) return setMsg({ ok: false, text: "Password must be at least 8 characters." });
    if (pw !== pw2) return setMsg({ ok: false, text: "Passwords do not match." });
    setBusy(true);
    const { error } = await supabase.auth.updateUser({ password: pw });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: error.message });
    setMsg({ ok: true, text: "Password updated. Redirecting…" });
    setTimeout(() => router.replace("/dashboard"), 1200);
  }

  const inp: React.CSSProperties = { width: "100%", padding: 12, margin: "6px 0 14px", borderRadius: 10, border: "1px solid #cbd5e1", fontSize: "1rem" };
  return (
    <main>
      <h1>Set a new password</h1>
      {!ready ? (
        <div className="card">
          <p>Waiting for a valid reset link or sign-in…</p>
          <p>If nothing happens, request a new link from the <a href="/login">sign-in page</a>.</p>
        </div>
      ) : (
        <form className="card" onSubmit={submit}>
          <label htmlFor="pw">New password (min 8 characters)</label>
          <input id="pw" type="password" autoComplete="new-password" required value={pw} onChange={(e) => setPw(e.target.value)} style={inp} />
          <label htmlFor="pw2">Confirm new password</label>
          <input id="pw2" type="password" autoComplete="new-password" required value={pw2} onChange={(e) => setPw2(e.target.value)} style={inp} />
          <button className="btn" disabled={busy}>{busy ? "Saving…" : "Update password"}</button>
          {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}
        </form>
      )}
    </main>
  );
}
