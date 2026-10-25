import "./globals.css";
import Nav from "@/components/Nav";
export const metadata = { title: "Hostel Meals" };
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (<html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1" /></head><body><Nav />{children}</body></html>);
}
