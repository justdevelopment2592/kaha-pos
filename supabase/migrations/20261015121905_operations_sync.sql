-- Kaha POS · M1/M2 operations: invoice series, shifts, cash, sales, payments, audit, sync
create type public.shift_status   as enum ('open','closed');
create type public.payment_method as enum ('cash','card_manual','ewallet_manual');
create type public.payment_status as enum ('collected','manually_verified');
create type public.cash_direction as enum ('in','out');
create type public.command_status as enum ('applied','rejected');

-- One demo series per device enrollment. A replacement device gets a new series, so numbers never collide.
create table public.invoice_series (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  branch_id     uuid not null,
  device_id     uuid not null,
  terminal_code text not null,
  series_no     integer not null check (series_no > 0),
  mode          public.invoice_mode not null default 'demo' check (mode = 'demo'),
  prefix        text not null,
  last_issued   bigint not null default 0 check (last_issued >= 0),
  created_at    timestamptz not null default now(),
  unique (tenant_id, prefix),
  unique (tenant_id, id),
  unique (tenant_id, branch_id, terminal_code, series_no),
  foreign key (tenant_id, branch_id) references public.branches(tenant_id, id),
  foreign key (tenant_id, device_id) references public.devices(tenant_id, id)
);
create index invoice_series_device_idx on public.invoice_series(tenant_id, device_id);

create table public.shifts (
  id            uuid primary key,                 -- generated on the device
  tenant_id     uuid not null,
  branch_id     uuid not null,
  device_id     uuid not null,
  staff_id      uuid not null,
  opening_float bigint not null check (opening_float >= 0),
  opened_at     timestamptz not null,
  business_date date not null,
  status        public.shift_status not null default 'open',
  closed_at     timestamptz,
  expected_cash bigint,
  counted_cash  bigint check (counted_cash >= 0),
  variance      bigint,
  close_note    text,
  reviewer_id   uuid,
  unique (tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, device_id)   references public.devices(tenant_id, id),
  foreign key (tenant_id, staff_id)    references public.staff(tenant_id, id),
  foreign key (tenant_id, reviewer_id) references public.staff(tenant_id, id),
  check ((status = 'closed') = (closed_at is not null)),
  check (status = 'open' or (expected_cash is not null and counted_cash is not null and variance = counted_cash - expected_cash)),
  check (status = 'open' or variance = 0 or length(trim(coalesce(close_note,''))) > 0)
);
create unique index shifts_one_open_per_device on public.shifts(device_id) where status = 'open';
create index shifts_branch_date_idx on public.shifts(tenant_id, branch_id, business_date);
create index shifts_staff_idx on public.shifts(tenant_id, staff_id);
create index shifts_reviewer_idx on public.shifts(tenant_id, reviewer_id);

create table public.cash_movements (
  id          uuid primary key,                   -- generated on the device
  tenant_id   uuid not null,
  branch_id   uuid not null,
  shift_id    uuid not null,
  direction   public.cash_direction not null,
  amount      bigint not null check (amount > 0),
  reason      text not null check (length(trim(reason)) > 0),
  staff_id    uuid not null,
  approved_by uuid,
  occurred_at timestamptz not null,
  created_at  timestamptz not null default now(),
  check (direction = 'in' or approved_by is not null),
  foreign key (tenant_id, shift_id)    references public.shifts(tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, staff_id)    references public.staff(tenant_id, id),
  foreign key (tenant_id, approved_by) references public.staff(tenant_id, id)
);
create index cash_movements_shift_idx on public.cash_movements(tenant_id, shift_id);
create index cash_movements_branch_idx on public.cash_movements(tenant_id, branch_id);
create index cash_movements_staff_idx on public.cash_movements(tenant_id, staff_id);
create index cash_movements_approver_idx on public.cash_movements(tenant_id, approved_by);

-- Completed sales only. Immutable once written; corrections are returns (M4).
create table public.sales (
  id                uuid primary key,             -- generated on the device before checkout
  tenant_id         uuid not null,
  branch_id         uuid not null,
  device_id         uuid not null,
  shift_id          uuid not null,
  staff_id          uuid not null,
  ref               text not null check (length(ref) between 1 and 40),
  invoice_series_id uuid not null,
  invoice_number    bigint not null check (invoice_number > 0),
  invoice_label     text not null,
  business_date     date not null,
  occurred_at       timestamptz not null,
  gross             bigint not null check (gross >= 0),
  discount          bigint not null check (discount >= 0),
  payable           bigint not null check (payable >= 0),
  vat               bigint not null check (vat >= 0),
  vatable_sales     bigint not null check (vatable_sales >= 0),
  exempt_sales      bigint not null check (exempt_sales >= 0),
  zero_rated_sales  bigint not null check (zero_rated_sales >= 0),
  non_vat_sales     bigint not null check (non_vat_sales >= 0),
  discount_info     jsonb,
  command_id        uuid not null,
  received_at       timestamptz not null default now(),
  check (payable = gross - discount),
  check (payable = vatable_sales + vat + exempt_sales + zero_rated_sales + non_vat_sales),
  unique (tenant_id, id),
  unique (tenant_id, invoice_series_id, invoice_number),
  foreign key (tenant_id, branch_id)         references public.branches(tenant_id, id),
  foreign key (tenant_id, device_id)         references public.devices(tenant_id, id),
  foreign key (tenant_id, shift_id)          references public.shifts(tenant_id, id),
  foreign key (tenant_id, staff_id)          references public.staff(tenant_id, id),
  foreign key (tenant_id, invoice_series_id) references public.invoice_series(tenant_id, id)
);
create index sales_branch_date_idx on public.sales(tenant_id, branch_id, business_date);
create index sales_shift_idx  on public.sales(tenant_id, shift_id);
create index sales_device_idx on public.sales(tenant_id, device_id);
create index sales_staff_idx  on public.sales(tenant_id, staff_id);

create table public.sale_items (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  branch_id     uuid not null,
  sale_id       uuid not null,
  line_no       smallint not null check (line_no > 0),
  variant_id    uuid,
  sku           text not null,
  name          text not null,
  unit          text not null,
  unit_price    bigint not null check (unit_price >= 0),
  qty           numeric(12,3) not null check (qty > 0),
  tax_treatment public.tax_treatment not null,
  tax_rate_bp   integer not null check (tax_rate_bp between 0 and 10000),
  gross         bigint not null check (gross >= 0),
  discount      bigint not null check (discount >= 0 and discount <= gross),
  net           bigint not null,
  vat           bigint not null check (vat >= 0),
  check (net = gross - discount),
  unique (sale_id, line_no),
  foreign key (tenant_id, sale_id)    references public.sales(tenant_id, id),
  foreign key (tenant_id, variant_id) references public.product_variants(tenant_id, id),
  foreign key (tenant_id, branch_id)  references public.branches(tenant_id, id)
);
create index sale_items_variant_idx on public.sale_items(tenant_id, variant_id);
create index sale_items_sale_idx on public.sale_items(tenant_id, sale_id);
create index sale_items_branch_idx on public.sale_items(tenant_id, branch_id);

create table public.payments (
  id           uuid primary key,                  -- generated on the device
  tenant_id    uuid not null,
  branch_id    uuid not null,
  sale_id      uuid not null,
  method       public.payment_method not null,
  status       public.payment_status not null,
  amount       bigint not null check (amount > 0),
  tendered     bigint not null,
  change_given bigint not null default 0 check (change_given >= 0),
  reference    text,
  verified_by  uuid,
  verified_at  timestamptz,
  check (tendered - change_given = amount),
  check (method = 'cash' or change_given = 0),
  check ((method = 'cash') = (status = 'collected')),
  check (method = 'cash' or (length(trim(coalesce(reference,''))) >= 4 and verified_by is not null and verified_at is not null)),
  foreign key (tenant_id, sale_id)     references public.sales(tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, verified_by) references public.staff(tenant_id, id)
);
create index payments_sale_idx on public.payments(tenant_id, sale_id);
create index payments_branch_idx on public.payments(tenant_id, branch_id);
create index payments_verifier_idx on public.payments(tenant_id, verified_by);

-- Things that synced fine but need a human look (price differences, oversold stock).
create table public.sale_exceptions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  branch_id   uuid not null,
  sale_id     uuid not null,
  type        text not null,
  detail      jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  foreign key (tenant_id, sale_id)     references public.sales(tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, resolved_by) references public.staff(tenant_id, id)
);
create index sale_exceptions_open_idx on public.sale_exceptions(tenant_id, branch_id) where resolved_at is null;
create index sale_exceptions_sale_idx on public.sale_exceptions(tenant_id, sale_id);
create index sale_exceptions_resolver_idx on public.sale_exceptions(tenant_id, resolved_by);

create table public.audit_logs (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id),
  branch_id      uuid,
  device_id      uuid,
  actor_staff_id uuid,
  approved_by    uuid,
  action         text not null,
  reason         text,
  detail         jsonb not null default '{}',
  occurred_at    timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index audit_logs_tenant_time_idx on public.audit_logs(tenant_id, occurred_at desc);
create index audit_logs_branch_idx on public.audit_logs(tenant_id, branch_id);

-- Idempotency record for every pushed command.
create table public.sync_commands (
  tenant_id      uuid not null references public.tenants(id),
  command_id     uuid not null,
  device_id      uuid not null references public.devices(id),
  type           text not null,
  schema_version integer not null,
  aggregate_id   uuid,
  local_sequence bigint,
  occurred_at    timestamptz,
  payload_hash   text not null,
  status         public.command_status not null,
  reason         text,
  result         jsonb,
  received_at    timestamptz not null default now(),
  primary key (tenant_id, command_id)
);
create index sync_commands_device_idx on public.sync_commands(device_id, received_at);
create index sync_commands_rejected_idx on public.sync_commands(tenant_id) where status = 'rejected';

-- Change feed for device pulls. Cursor = (txid, id); only rows from transactions older
-- than the oldest in-progress transaction are served, so a late commit is never skipped.
create table public.change_log (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references public.tenants(id),
  branch_id  uuid,
  entity     text not null,
  entity_id  uuid not null,
  op         text not null check (op in ('upsert','delete')),
  data       jsonb,
  txid       xid8 not null default pg_current_xact_id(),
  created_at timestamptz not null default now()
);
create index change_log_cursor_idx on public.change_log(tenant_id, txid, id);
