-- Kaha POS · M1 catalog + inventory ledger
create type public.tax_treatment as enum ('vatable','exempt','zero_rated','non_vat');
create type public.location_kind as enum ('sellable','damaged','in_transit');
create type public.movement_type as enum
  ('opening_balance','stock_receipt','sale','customer_return','adjustment','transfer_out','transfer_in');

create table public.tax_codes (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id),
  code       text not null check (length(code) between 1 and 20),
  name       text not null check (length(name) between 1 and 100),
  treatment  public.tax_treatment not null,
  rate_bp    integer not null check (rate_bp between 0 and 10000),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, code),
  unique (tenant_id, id),
  check (treatment = 'vatable' or rate_bp = 0)
);
comment on column public.tax_codes.rate_bp is 'Basis points: 1200 = 12%.';

create table public.categories (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id),
  name       text not null check (length(name) between 1 and 100),
  sort_order integer not null default 0,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id)
);

create table public.products (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id),
  category_id uuid,
  name        text not null check (length(name) between 1 and 200),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, category_id) references public.categories(tenant_id, id)
);
create index products_category_idx on public.products(tenant_id, category_id);

create table public.product_variants (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  product_id     uuid not null,
  sku            text not null check (sku ~ '^[A-Za-z0-9._-]{1,40}$'),
  variant_name   text,
  unit           text not null default 'pc' check (length(unit) between 1 and 20),
  tax_code_id    uuid not null,
  price_centavos bigint not null check (price_centavos between 0 and 100000000000),
  deleted_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, sku),
  unique (tenant_id, id),
  foreign key (tenant_id, product_id)  references public.products(tenant_id, id),
  foreign key (tenant_id, tax_code_id) references public.tax_codes(tenant_id, id)
);
comment on column public.product_variants.price_centavos is 'VAT-inclusive selling price in centavos.';
create index product_variants_product_idx on public.product_variants(tenant_id, product_id);
create index product_variants_tax_idx on public.product_variants(tenant_id, tax_code_id);

create table public.product_barcodes (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  variant_id uuid not null,
  barcode    text not null check (barcode ~ '^[0-9A-Za-z-]{4,32}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, barcode),
  foreign key (tenant_id, variant_id) references public.product_variants(tenant_id, id) on delete cascade
);
create index product_barcodes_variant_idx on public.product_barcodes(tenant_id, variant_id);

create table public.locations (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null,
  branch_id  uuid not null,
  kind       public.location_kind not null,
  name       text not null,
  created_at timestamptz not null default now(),
  unique (tenant_id, branch_id, kind),
  unique (tenant_id, id),
  foreign key (tenant_id, branch_id) references public.branches(tenant_id, id)
);

create table public.inventory_balances (
  tenant_id   uuid not null,
  branch_id   uuid not null,
  location_id uuid not null,
  variant_id  uuid not null,
  qty         numeric(14,3) not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (location_id, variant_id),
  foreign key (tenant_id, location_id) references public.locations(tenant_id, id),
  foreign key (tenant_id, variant_id)  references public.product_variants(tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id)
);
create index inventory_balances_branch_idx on public.inventory_balances(tenant_id, branch_id);
create index inventory_balances_variant_idx on public.inventory_balances(tenant_id, variant_id);

-- Append-only ledger. Corrections are new movements.
create table public.stock_movements (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  branch_id   uuid not null,
  location_id uuid not null,
  variant_id  uuid not null,
  type        public.movement_type not null,
  qty         numeric(14,3) not null check (qty <> 0),
  source_type text not null,
  source_id   uuid,
  reason      text,
  staff_id    uuid,
  device_id   uuid,
  occurred_at timestamptz not null,
  created_at  timestamptz not null default now(),
  check (type <> 'adjustment' or length(trim(coalesce(reason,''))) > 0),
  foreign key (tenant_id, location_id) references public.locations(tenant_id, id),
  foreign key (tenant_id, variant_id)  references public.product_variants(tenant_id, id),
  foreign key (tenant_id, branch_id)   references public.branches(tenant_id, id),
  foreign key (tenant_id, staff_id)    references public.staff(tenant_id, id),
  foreign key (tenant_id, device_id)   references public.devices(tenant_id, id)
);
create index stock_movements_source_idx  on public.stock_movements(tenant_id, source_type, source_id);
create index stock_movements_variant_idx on public.stock_movements(tenant_id, variant_id, occurred_at);
create index stock_movements_branch_idx  on public.stock_movements(tenant_id, branch_id, occurred_at);
create index stock_movements_location_idx on public.stock_movements(tenant_id, location_id);
create index stock_movements_staff_idx   on public.stock_movements(tenant_id, staff_id);
create index stock_movements_device_idx  on public.stock_movements(tenant_id, device_id);
