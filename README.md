# Kaha POS

Philippine mobile point of sale. **Flutter / SQLite (Drift) / Supabase.** Spec and decisions live in the Obsidian vault (`KOS/ERP System/Point of Sale`).

> Demo mode only. Invoices use `DEMO-…` series and the database refuses production invoicing until the compliance gates are signed off.

## Layout
```
supabase/   migrations/, seed.sql, tests/   ← backend (applied to project opensource-pos)
mobile/     Flutter app (items, users, roles)    ← build on your Mac, see mobile/README.md
prototype-android/  WebView shell for the UI prototype APK
admin/      Next.js console                  ← later
docs/       sync-contract.md                 ← what the app sends and receives
```

## Backend status (M1)
Applied to `opensource-pos` (ap-southeast-1) on 2026-10-15:
- Tenancy: tenants, branches, staff, staff_branches (composite FKs keep every row inside its tenant)
- Devices: one-time enrollment codes, hashed device secrets, revoke, per-device demo invoice series
- Catalog: tax codes, categories, products, variants, barcodes (owners/managers can edit directly; RLS-checked)
- Inventory: append-only stock ledger + balances, sellable / damaged / in-transit locations
- Operations: shifts, cash in/out, sales, sale lines, payments, sale exceptions, audit log
- Sync: `sync_push_v1` (idempotent per command), `sync_pull_v1` (commit-safe cursor), `bootstrap_v1`
- Security: RLS on every table; financial tables write-only through server functions; TRUNCATE revoked; anon has no access
- Seed: "Tindahan Demo Trading", 2 branches, 24 products, opening stock at Calle Real

Verified with `supabase/tests/e2e_m1.sql` (runs as real roles, then rolls back).

### Added 2026-10-15 (migration `permissions_staff_catalog`)
- Permission matrix: 12 permissions, owners have all, other roles per store (`role_permissions`)
- Store onboarding `store_create_v1`, invitations (`staff_invite_v1`, `invitation_accept_v1`, `staff_invitation_revoke_v1`), `staff_update_v1`, `staff_list_v1`
- Items: `item_save_v1`, `item_archive_v1`, `category_save_v1`, `catalog_admin_list_v1`, `stock_receive_v1`; catalog tables are now write-only through these (audited)
- Offline approvals (cash out, shift close) now require the matching permission
- Verified: 23 permission checks + sync regression, all passing; test data rolled back

## Set up locally
1. Install the Supabase CLI and Docker.
2. `supabase init` (creates `supabase/config.toml`; keep the existing `migrations/`, `seed.sql`, `tests/`).
3. `supabase start` → local stack with these migrations and the seed.
4. `supabase link --project-ref cstntybwrrimdlyjucay` to work against the hosted test project.
5. `cp .env.example .env` and fill the publishable key from the dashboard (Project Settings → API).

## Create your first real users (hosted test project)
1. Dashboard → Authentication → Users → **Add user** (e.g. your email as owner, a second as cashier).
2. SQL editor:
   ```sql
   select app.dev_attach_user('you@example.com',     '11111111-1111-4111-8111-111111111111', 'owner',   'Justin');
   select app.dev_attach_user('cashier@example.com', '11111111-1111-4111-8111-111111111111', 'cashier', 'Mark');
   ```
   `app.dev_attach_user` is callable only from the SQL editor / service role.

## Rules for new migrations
- Every new table: `enable row level security`, a tenant-scoped policy, composite FK to its parent, indexes on FKs.
- Financial/stock writes go through a versioned `*_v1` function; never grant INSERT/UPDATE on them.
- Run Supabase advisors (security + performance) after each migration.
