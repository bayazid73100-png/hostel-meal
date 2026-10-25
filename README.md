# Hostel Meal Management (Next.js + Supabase)

Six batches, student wallets (ledger-based), next-day meal booking (10 PM Asia/Dhaka), charge only after an admin confirms the meal, audited negative-balance exceptions, reports and reconciliation.

> **Status: not production-ready.** Written without being run. Follow "Verify before use" below.

## Setup
1. Create a Supabase project.
2. SQL editor: run `supabase/migrations/001` … `006` in order.
3. Create the Super Admin: follow `supabase/init_super_admin.sql`.
4. `cp .env.example .env.local`, fill URL, anon key, service-role key.
   The service-role key is server-only (used only by `app/api/admin/create-user`). Never prefix it with `NEXT_PUBLIC_`.
5. Supabase → Authentication → URL Configuration: add your site URL and `<site>/reset-password` to the redirect allow-list.
6. `npm install && npm run dev`.

## Test data (separate project only, never production)
Run `supabase/seed_test.sql` (password for all test users: `Test@12345`; emails `super@`, `admin11@`, `admin12@`, `student1@`, `student2@test.local`). Then run `tests.sql`, `tests_002.sql` … `tests_006.sql`. Each rolls back and prints `PASS`/`FAIL` notices. Before first production use, delete test users.

## Verify before use
- Run all test scripts on a fresh Supabase project and fix failures.
- Confirm RLS from a real `authenticated` session (student cannot read another student; batch admin cannot read an unassigned batch; direct writes to ledger tables are denied).
- Run a concurrent-booking test (two parallel `book_meals` calls on one low-balance student; one must fail). Not yet automated.
- Try the UI on a real Android phone.

## Workflows
**Booking** (`book_meals`): student picks lunch / dinner / both / none for tomorrow. Server checks the deadline using Asia/Dhaka (default 22:00, configurable by Super Admin), then available balance = ledger balance − reservations for other dates. Insufficient funds → error with shortfall. A booking reserves the meal price; it is **not** a charge and **not** consumption. After the deadline only an admin can change it, with a reason (stored with admin ID).

**Charging** (`confirm_consumption`): an admin of that student's batch confirms the student actually ate. The server inserts one consumption row and one `meal_charge` ledger row at the price effective on the meal date, and releases the reservation. Duplicates are blocked by unique indexes. `mark_missed` charges nothing. Cancelled bookings charge nothing.

**Corrections** (`reverse_transaction`, `reverse_meal_charge`): never edit or delete. A reversal row negates the original (one per transaction); a reversed meal charge reopens the booking so it can be re-confirmed.

**Negative balance**: never automatic. Only a Super Admin can call `authorize_exception` (student, date, meal, amount cap, reason; audited). The student can then book up to that cap; the booking becomes `authorized_exception`. When the meal is confirmed it is charged normally and the balance may go negative. It stays flagged on `/admin/exceptions` and the student dashboard until a deposit or credit adjustment clears it. Reconciliation flags negative balances that have no exception.

**Prices**: effective-dated (`set_meal_price`, Super Admin). Past charges keep their stored price.

## Security model
- Balances are derived from `wallet_transactions` (integer poisha). Ledger, consumption and audit tables are immutable via triggers (only `reversed_at` may be set on consumption).
- Clients cannot write to financial tables; all writes go through `SECURITY DEFINER` functions that re-check role and batch (`is_admin_for`). RLS restricts reads (student: own rows; batch admin: assigned batches; super admin: all).
- Account creation uses the server route with the service-role key after verifying the caller is an active Super Admin.

## Deployment (Vercel)
Import the repo, set the three env vars, deploy. Use a separate Supabase project for production. Enable email confirmation/password policy in Supabase Auth, and set a custom SMTP provider so reset emails are reliable.

## Backup and recovery
- Supabase paid plans: enable daily backups / point-in-time recovery.
- Always: weekly `pg_dump` of the database to storage outside Supabase (`pg_dump "$DATABASE_URL" -Fc -f backup-$(date +%F).dump`); also export the `wallet_transactions` table to CSV monthly.
- Restore into a fresh project: `pg_restore -d "$NEW_DATABASE_URL" backup.dump`, recreate Auth users if restoring across projects (profile IDs must match `auth.users`), then run `reconciliation_report()` and compare against `/admin/reports`.
- Test a restore before you rely on it.

## Implemented
Auth (login, forgot/reset password), student dashboard, booking, wallet history, calendar, admin dashboard + charts, daily meal management (confirm, missed, reverse, bulk, kitchen print list), deposits/refunds/adjustments, exceptions, prices and deadline, reports (CSV, print), reconciliation, batch/student/admin management, audit log viewer (Super Admin).

## Not implemented / known gaps
- Authorization request flow for batch admins; configurable batch-admin limits (hardcoded ৳500 for refunds/debits) and low-balance threshold (hardcoded ৳80).
- Cancellation, reservation and charging policy settings (behaviour is fixed to the defaults above).
- Separate reservation table (reservations are derived from open bookings).
- Student notifications beyond dashboard warnings; QR attendance; payment gateway.
- Booking/consumption status filters on the daily meals page; per-student statement page; student-side batch change.
- **Refund sign:** refunds currently reduce the balance (money returned to the student). Your spec's formula adds refunds. Decide which you want and change `post_transaction` accordingly.
- Dashboards fetch rows client-side (fine for hundreds of students; move to SQL views for more).
- Tailwind and a component library were not used (plain CSS).
