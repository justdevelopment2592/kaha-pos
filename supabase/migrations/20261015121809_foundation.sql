-- Kaha POS · M1 foundation: tenancy, staff, devices, enrollment
-- Tenant boundaries are enforced with composite foreign keys (tenant_id, id).

create extension if not exists pgcrypto with schema extensions;
create schema if not exists app;
comment on schema app is 'Private helpers. Not exposed through the Data API.';

create type public.staff_role    as enum ('owner','manager','cashier','inventory');
create type public.device_status as enum ('active','revoked');
create type public.invoice_mode  as enum ('demo','production');

create table public.tenants (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(name) between 1 and 200),
  timezone       text not null default 'Asia/Manila',
  vat_registered boolean not null default true,
  invoice_mode   public.invoice_mode not null default 'demo'
                 constraint production_invoicing_locked check (invoice_mode = 'demo'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on constraint production_invoicing_locked on public.tenants is
  'Remove only after every gate in 24 - Compliance Checklist has evidence.';

create table public.branches (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete restrict,
  code       text not null check (code ~ '^[A-Z0-9]{2,8}$'),
  name       text not null check (length(name) between 1 and 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, code),
  unique (tenant_id, id)
);

create table public.staff (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete restrict,
  user_id      uuid unique references auth.users(id) on delete set null,
  display_name text not null check (length(display_name) between 1 and 100),
  role         public.staff_role not null,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on column public.staff.user_id is 'M1: one tenant per sign-in account (unique).';
create index staff_tenant_idx on public.staff(tenant_id);

create table public.staff_branches (
  tenant_id uuid not null,
  staff_id  uuid not null,
  branch_id uuid not null,
  primary key (staff_id, branch_id),
  foreign key (tenant_id, staff_id)  references public.staff(tenant_id, id) on delete cascade,
  foreign key (tenant_id, branch_id) references public.branches(tenant_id, id) on delete cascade
);
create index staff_branches_branch_idx on public.staff_branches(tenant_id, branch_id);

create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  branch_id     uuid not null,
  terminal_code text not null check (terminal_code ~ '^T[0-9]{2}$'),
  name          text not null default 'Terminal' check (length(name) between 1 and 100),
  status        public.device_status not null default 'active',
  app_version   text,
  enrolled_by   uuid,
  enrolled_at   timestamptz not null default now(),
  revoked_at    timestamptz,
  revoked_by    uuid,
  revoke_reason text,
  last_seen_at  timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, enrolled_by) references public.staff(tenant_id, id),
  foreign key (tenant_id, revoked_by)  references public.staff(tenant_id, id),
  check ((status = 'revoked') = (revoked_at is not null))
);
create unique index devices_one_active_per_terminal
  on public.devices(tenant_id, branch_id, terminal_code) where status = 'active';
create index devices_branch_idx on public.devices(tenant_id, branch_id);

-- Hashed device secrets live apart from devices and have no RLS policy: clients can never read them.
create table public.device_secrets (
  device_id   uuid primary key references public.devices(id) on delete cascade,
  secret_hash text not null
);

create table public.enrollment_codes (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  branch_id      uuid not null,
  terminal_code  text not null check (terminal_code ~ '^T[0-9]{2}$'),
  code_hash      text not null unique,
  expires_at     timestamptz not null,
  used_at        timestamptz,
  used_by_device uuid references public.devices(id),
  created_by     uuid not null,
  created_at     timestamptz not null default now(),
  foreign key (tenant_id, branch_id)  references public.branches(tenant_id, id),
  foreign key (tenant_id, created_by) references public.staff(tenant_id, id)
);
create index enrollment_codes_tenant_idx on public.enrollment_codes(tenant_id, branch_id);
