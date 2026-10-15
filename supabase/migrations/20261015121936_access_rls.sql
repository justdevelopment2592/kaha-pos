-- Kaha POS · access helpers, integrity triggers, row-level security
-- Reads: RLS. Writes to financial/stock tables: only via security-definer RPC functions.

-- ---------- who is calling ----------
create or replace function app.current_staff_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.id from public.staff s where s.user_id = auth.uid() and s.active
$$;

create or replace function app.current_tenant_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.tenant_id from public.staff s where s.user_id = auth.uid() and s.active
$$;

create or replace function app.staff_role_now() returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select s.role from public.staff s where s.user_id = auth.uid() and s.active
$$;

create or replace function app.can_access_branch(p_branch_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff s
    join public.branches b on b.tenant_id = s.tenant_id and b.id = p_branch_id
    where s.user_id = auth.uid() and s.active
      and (s.role = 'owner'
           or exists (select 1 from public.staff_branches sb where sb.staff_id = s.id and sb.branch_id = p_branch_id))
  )
$$;

create or replace function app.is_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(app.staff_role_now() in ('owner','manager'), false)
$$;

-- ---------- integrity triggers ----------
create or replace function app.forbid_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% is append-only; record a correction instead', tg_table_name using errcode = '42501';
end $$;

create trigger stock_movements_append_only before update or delete on public.stock_movements for each row execute function app.forbid_change();
create trigger sales_immutable           before update or delete on public.sales           for each row execute function app.forbid_change();
create trigger sale_items_immutable      before update or delete on public.sale_items      for each row execute function app.forbid_change();
create trigger payments_immutable        before update or delete on public.payments        for each row execute function app.forbid_change();
create trigger cash_movements_immutable  before update or delete on public.cash_movements  for each row execute function app.forbid_change();
create trigger audit_logs_append_only    before update or delete on public.audit_logs      for each row execute function app.forbid_change();
create trigger sync_commands_append_only before update or delete on public.sync_commands   for each row execute function app.forbid_change();

create or replace function app.forbid_closed_shift_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' or old.status = 'closed' then
    raise exception 'closed shifts cannot be changed' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger shifts_closed_immutable before update or delete on public.shifts for each row execute function app.forbid_closed_shift_change();

create or replace function app.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['tenants','branches','staff','tax_codes','categories','products','product_variants','product_barcodes'] loop
    execute format('create trigger %I before update on public.%I for each row execute function app.touch_updated_at()', t||'_touch', t);
  end loop;
end $$;

-- ---------- change feed for devices ----------
create or replace function app.log_catalog_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_op text;
begin
  if tg_op = 'DELETE' then v := to_jsonb(old); v_op := 'delete';
  else
    v := to_jsonb(new);
    v_op := case when v->>'deleted_at' is not null then 'delete' else 'upsert' end;
  end if;
  insert into public.change_log(tenant_id, branch_id, entity, entity_id, op, data)
  values ((v->>'tenant_id')::uuid, null, tg_table_name, (v->>'id')::uuid, v_op, case when v_op = 'delete' then null else v end);
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['tax_codes','categories','products','product_variants','product_barcodes'] loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.log_catalog_change()', t||'_feed', t);
  end loop;
end $$;

create or replace function app.log_stock_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.locations l where l.id = new.location_id and l.kind = 'sellable') then
    insert into public.change_log(tenant_id, branch_id, entity, entity_id, op, data)
    values (new.tenant_id, new.branch_id, 'stock', new.variant_id, 'upsert',
            jsonb_build_object('variant_id', new.variant_id, 'qty', new.qty, 'updated_at', new.updated_at));
  end if;
  return null;
end $$;
create trigger inventory_balances_feed after insert or update on public.inventory_balances
  for each row execute function app.log_stock_change();

-- ---------- row-level security ----------
do $$ declare t text; begin
  foreach t in array array['tenants','branches','staff','staff_branches','devices','device_secrets','enrollment_codes',
    'tax_codes','categories','products','product_variants','product_barcodes','locations','inventory_balances',
    'stock_movements','invoice_series','shifts','cash_movements','sales','sale_items','payments','sale_exceptions',
    'audit_logs','sync_commands','change_log'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
-- device_secrets and change_log intentionally have no policies (RPC only).

create policy tenants_read on public.tenants for select to authenticated
  using (id = (select app.current_tenant_id()));

create policy staff_read on public.staff for select to authenticated
  using (tenant_id = (select app.current_tenant_id()));

-- Tenant-wide catalog: everyone in the tenant reads; owners/managers write.
do $$ declare t text; begin
  foreach t in array array['tax_codes','categories','products','product_variants','product_barcodes'] loop
    execute format($f$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()))$f$, t||'_read', t);
    execute format($f$create policy %I on public.%I for insert to authenticated
      with check (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()))$f$, t||'_insert', t);
    execute format($f$create policy %I on public.%I for update to authenticated
      using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()))
      with check (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()))$f$, t||'_update', t);
  end loop;
end $$;
create policy product_barcodes_delete on public.product_barcodes for delete to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()));

-- Branch-scoped reads.
create policy branches_read on public.branches for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and app.can_access_branch(id));
create policy staff_branches_read on public.staff_branches for select to authenticated
  using (tenant_id = (select app.current_tenant_id()));

do $$ declare t text; begin
  foreach t in array array['locations','inventory_balances','stock_movements','shifts','cash_movements','sales','sale_items','sale_exceptions'] loop
    execute format($f$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()) and app.can_access_branch(branch_id))$f$, t||'_read', t);
  end loop;
end $$;

-- Payments: not visible to inventory staff.
create policy payments_read on public.payments for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and app.can_access_branch(branch_id)
         and (select app.staff_role_now()) <> 'inventory');

-- Manager-only views of devices, codes, series, audit, sync records.
create policy devices_read on public.devices for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()) and app.can_access_branch(branch_id));
create policy enrollment_codes_read on public.enrollment_codes for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()) and app.can_access_branch(branch_id));
create policy invoice_series_read on public.invoice_series for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()) and app.can_access_branch(branch_id));
create policy audit_logs_read on public.audit_logs for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()));
create policy sync_commands_read on public.sync_commands for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.is_manager()));

-- ---------- privileges ----------
revoke all on all tables in schema public from anon;
-- TRUNCATE ignores RLS, so nobody outside the server gets it. Writes are RPC-only except catalog upkeep.
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from authenticated;
grant insert, update on public.tax_codes, public.categories, public.products, public.product_variants, public.product_barcodes to authenticated;
grant delete on public.product_barcodes to authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on schema app from public;
grant usage on schema app to authenticated;
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function app.current_staff_id(), app.current_tenant_id(), app.staff_role_now(),
  app.can_access_branch(uuid), app.is_manager() to authenticated;

-- Same rules for objects created by later migrations.
alter default privileges for role postgres in schema public revoke truncate, references, trigger on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon;
