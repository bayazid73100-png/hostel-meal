"use client";
import { useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";

type Link = [string, string];
const STUDENT: Link[] = [["/dashboard", "Home"], ["/book", "Book"], ["/wallet", "Wallet"], ["/calendar", "Calendar"]];
const ADMIN: Link[] = [["/admin/dashboard", "Dashboard"], ["/admin/meals", "Meals"], ["/admin/deposits", "Deposits"], ["/admin/reports", "Reports"]];
const SUPER: Link[] = [["/admin/exceptions", "Exceptions"], ["/admin/settings", "Prices"], ["/admin/people", "People"], ["/admin/audit", "Audit"]];

export default function Nav() {
  const path = usePathname();
  const router = useRouter();
  const [role, setRole] = useState<string | null>(null);

  useEffect(() => {
    const load = async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) return setRole(null);
      const { data } = await supabase.from("profiles").select("role").eq("id", session.user.id).single();
      setRole(data?.role ?? null);
    };
    load();
    const { data: sub } = supabase.auth.onAuthStateChange(() => { load(); });
    return () => sub.subscription.unsubscribe();
  }, []);

  if (!role || path === "/login" || path === "/reset-password") return null;
  const links = role === "student" ? STUDENT : [...ADMIN, ...(role === "super_admin" ? SUPER : [])];

  return (
    <nav className="nav no-print" aria-label="Main">
      {links.map(([href, label]) => (
        <a key={href} href={href} aria-current={path === href ? "page" : undefined}>{label}</a>
      ))}
      <a href="/reset-password">Password</a>
      <a href="#" onClick={async (e) => { e.preventDefault(); await supabase.auth.signOut(); router.replace("/login"); }}>Sign out</a>
    </nav>
  );
}
