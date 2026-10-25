"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

export default function Login() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  async function signIn(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMsg(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: error.message });
    const { data: { user } } = await supabase.auth.getUser();
    const { data: me } = user ? await supabase.from("profiles").select("role").eq("id", user.id).single() : { data: null };
    router.replace(me && me.role !== "student" ? "/admin/dashboard" : "/dashboard");
  }

  async function forgot() {
    if (!email) return setMsg({ ok: false, text: "Enter your email first." });
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${location.origin}/reset-password`,
    });
    setMsg(error ? { ok: false, text: error.message } : { ok: true, text: "Password reset email sent." });
  }

  return (
    <main>
      <h1>Hostel Meals</h1>
      <form className="card" onSubmit={signIn}>
        <label htmlFor="email">Email</label>
        <input id="email" type="email" required autoComplete="username" value={email}
          onChange={(e) => setEmail(e.target.value)} style={inp} />
        <label htmlFor="pw">Password</label>
        <input id="pw" type="password" required autoComplete="current-password" value={password}
          onChange={(e) => setPassword(e.target.value)} style={inp} />
        <button className="btn" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
        <p><a href="#" onClick={(e) => { e.preventDefault(); forgot(); }}>Forgot password?</a></p>
        {msg && <div role="status" className={`msg ${msg.ok ? "ok" : "err"}`}>{msg.text}</div>}
      </form>
    </main>
  );
}
const inp: React.CSSProperties = { width: "100%", padding: 12, margin: "6px 0 14px", borderRadius: 10, border: "1px solid #cbd5e1", fontSize: "1rem" };
