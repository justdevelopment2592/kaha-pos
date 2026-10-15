-- Kaha POS · server functions (RPC). Every business write goes through here.

-- ---------- small helpers ----------
create or replace function app.sha256_hex(p text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(p, ''), 'sha256'), 'hex')
$$;

-- VAT contained in a VAT-inclusive amount, rounded half up (ADR-002). 1200 bp = 12%.
create or replace function app.vat_in(p_net bigint, p_rate_bp integer) returns bigint
language sql immutable set search_path = '' as $$
  select case when p_rate_bp = 0 then 0::bigint
              else (p_net * p_rate_bp + (10000 + p_rate_bp) / 2) / (10000 + p_rate_bp) end
$$;

create or replace function app.random_code(p_len integer) returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 chars, no 0/O/1/I
  b bytea := extensions.gen_random_bytes(p_len);
  r text := '';
begin
  for i in 0 .. p_len - 1 loop
    r := r || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return r;
end $$;

create or replace function app.audit(p_tenant uuid, p_branch uuid, p_device uuid, p_actor uuid, p_approver uuid,
  p_action text, p_reason text, p_detail jsonb, p_occurred timestamptz default now()) returns void
language sql volatile security definer set search_path = '' as $$
  insert into public.audit_logs(tenant_id, branch_id, device_id, actor_staff_id, approved_by, action, reason, detail, occurred_at)
  values (p_tenant, p_branch, p_device, p_actor, p_approver, p_action, p_reason, coalesce(p_detail, '{}'), coalesce(p_occurred, now()))
$$;

-- Caller must be signed in, the device active with the right secret, and the caller assigned to its branch.
create or replace function app.require_device(p_device_id uuid, p_secret text) returns public.devices
language plpgsql stable security definer set search_path = '' as $$
declare d public.devices;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  select * into d from public.devices where id = p_device_id;
  if not found or d.status <> 'active' then raise exception 'device_not_active' using errcode = '42501'; end if;
  if not exists (select 1 from public.device_secrets s where s.device_id = d.id and s.secret_hash = app.sha256_hex(p_secret)) then
    raise exception 'device_secret_invalid' using errcode = '42501';
  end if;
  if app.current_staff_id() is null or app.current_tenant_id() is distinct from d.tenant_id or not app.can_access_branch(d.branch_id) then
    raise exception 'not_assigned_to_this_branch' using errcode = '42501';
  end if;
  return d;
end $$;

-- Staff named inside a command (e.g. the cashier who rang an offline sale) must belong to the device's branch.
create or replace function app.staff_for_branch(p_tenant uuid, p_branch uuid, p_staff uuid) returns public.staff
language plpgsql stable security definer set search_path = '' as $$
declare s public.staff;
begin
  select * into s from public.staff where id = p_staff and tenant_id = p_tenant;
  if not found or not (s.role = 'owner' or exists (select 1 from public.staff_branches sb where sb.staff_id = s.id and sb.branch_id = p_branch)) then
    raise exception 'staff_not_assigned_to_branch';
  end if;
  return s;
end $$;

create or replace function app.require_approver(p_tenant uuid, p_staff uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_staff is null or not exists (select 1 from public.staff s where s.id = p_staff and s.tenant_id = p_tenant and s.role in ('owner','manager')) then
    raise exception 'manager_approval_required';
  end if;
  return p_staff;
end $$;

create or replace function app.post_movement(p_tenant uuid, p_branch uuid, p_location uuid, p_variant uuid,
  p_type public.movement_type, p_qty numeric, p_source_type text, p_source_id uuid, p_reason text,
  p_staff uuid, p_device uuid, p_occurred timestamptz) returns numeric
language plpgsql volatile security definer set search_path = '' as $$
declare v_qty numeric;
begin
  insert into public.stock_movements(tenant_id, branch_id, location_id, variant_id, type, qty, source_type, source_id, reason, staff_id, device_id, occurred_at)
  values (p_tenant, p_branch, p_location, p_variant, p_type, p_qty, p_source_type, p_source_id, p_reason, p_staff, p_device, p_occurred);
  insert into public.inventory_balances as b (tenant_id, branch_id, location_id, variant_id, qty)
  values (p_tenant, p_branch, p_location, p_variant, p_qty)
  on conflict (location_id, variant_id) do update set qty = b.qty + excluded.qty, updated_at = now()
  returning b.qty into v_qty;
  return v_qty;
end $$;

-- ---------- device enrollment ----------
create or replace function public.create_enrollment_code_v1(p_branch_id uuid, p_terminal_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_staff uuid := app.current_staff_id();
  v_tenant uuid := app.current_tenant_id();
  v_code text; v_exp timestamptz := now() + interval '24 hours';
begin
  if v_staff is null or not app.is_manager() then raise exception 'only_owner_or_manager' using errcode = '42501'; end if;
  if not app.can_access_branch(p_branch_id) then raise exception 'branch_not_found' using errcode = '42501'; end if;
  v_code := app.random_code(4) || '-' || app.random_code(4);
  insert into public.enrollment_codes(tenant_id, branch_id, terminal_code, code_hash, expires_at, created_by)
  values (v_tenant, p_branch_id, upper(p_terminal_code), app.sha256_hex(v_code), v_exp, v_staff);
  perform app.audit(v_tenant, p_branch_id, null, v_staff, null, 'device.enrollment_code_created', null,
                    jsonb_build_object('terminal_code', upper(p_terminal_code), 'expires_at', v_exp));
  return jsonb_build_object('code', v_code, 'terminal_code', upper(p_terminal_code), 'expires_at', v_exp);
end $$;

create or replace function public.enroll_device_v1(p_code text, p_device_name text default 'Terminal', p_app_version text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  c public.enrollment_codes; v_staff uuid := app.current_staff_id();
  v_device uuid; v_secret text; v_branch public.branches; v_no integer; v_series public.invoice_series;
begin
  if v_staff is null then raise exception 'not_staff' using errcode = '42501'; end if;
  select * into c from public.enrollment_codes where code_hash = app.sha256_hex(upper(trim(p_code))) for update;
  if not found or c.used_at is not null or c.expires_at < now() then
    raise exception 'enrollment_code_invalid_or_used' using errcode = '22023';
  end if;
  if c.tenant_id is distinct from app.current_tenant_id() or not app.can_access_branch(c.branch_id) then
    raise exception 'not_assigned_to_this_branch' using errcode = '42501';
  end if;
  if exists (select 1 from public.devices where tenant_id = c.tenant_id and branch_id = c.branch_id
             and terminal_code = c.terminal_code and status = 'active') then
    raise exception 'terminal_already_has_an_active_device: revoke it first' using errcode = '23505';
  end if;

  insert into public.devices(tenant_id, branch_id, terminal_code, name, app_version, enrolled_by)
  values (c.tenant_id, c.branch_id, c.terminal_code, coalesce(nullif(trim(p_device_name), ''), 'Terminal'), p_app_version, v_staff)
  returning id into v_device;

  v_secret := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.device_secrets(device_id, secret_hash) values (v_device, app.sha256_hex(v_secret));
  update public.enrollment_codes set used_at = now(), used_by_device = v_device where id = c.id;

  select * into v_branch from public.branches where id = c.branch_id;
  select coalesce(max(series_no), 0) + 1 into v_no from public.invoice_series
   where tenant_id = c.tenant_id and branch_id = c.branch_id and terminal_code = c.terminal_code;
  insert into public.invoice_series(tenant_id, branch_id, device_id, terminal_code, series_no, mode, prefix)
  values (c.tenant_id, c.branch_id, v_device, c.terminal_code, v_no, 'demo',
          format('DEMO-%s-%s-%s', v_branch.code, c.terminal_code, lpad(v_no::text, 2, '0')))
  returning * into v_series;

  perform app.audit(c.tenant_id, c.branch_id, v_device, v_staff, null, 'device.enrolled', null,
                    jsonb_build_object('terminal_code', c.terminal_code, 'series', v_series.prefix));
  return jsonb_build_object(
    'device_id', v_device, 'device_secret', v_secret,
    'tenant_id', c.tenant_id, 'branch_id', c.branch_id, 'terminal_code', c.terminal_code,
    'invoice_series', jsonb_build_object('id', v_series.id, 'prefix', v_series.prefix, 'last_issued', 0));
end $$;

create or replace function public.revoke_device_v1(p_device_id uuid, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d public.devices; v_staff uuid := app.current_staff_id();
begin
  if v_staff is null or not app.is_manager() then raise exception 'only_owner_or_manager' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'reason_required' using errcode = '22023'; end if;
  select * into d from public.devices where id = p_device_id and tenant_id = app.current_tenant_id() for update;
  if not found or not app.can_access_branch(d.branch_id) then raise exception 'device_not_found' using errcode = '42501'; end if;
  if d.status = 'revoked' then return jsonb_build_object('device_id', d.id, 'status', 'revoked'); end if;
  update public.devices set status = 'revoked', revoked_at = now(), revoked_by = v_staff, revoke_reason = p_reason where id = d.id;
  perform app.audit(d.tenant_id, d.branch_id, d.id, v_staff, null, 'device.revoked', p_reason, '{}');
  return jsonb_build_object('device_id', d.id, 'status', 'revoked');
end $$;

-- ---------- bootstrap + pull ----------
create or replace function public.bootstrap_v1(p_device_id uuid, p_device_secret text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  d public.devices := app.require_device(p_device_id, p_device_secret);
  v_xmin xid8 := pg_snapshot_xmin(pg_current_snapshot());
  c_tx xid8; c_id bigint;
begin
  select l.txid, l.id into c_tx, c_id from public.change_log l
   where l.tenant_id = d.tenant_id and l.txid < v_xmin order by l.txid desc, l.id desc limit 1;
  return jsonb_build_object(
    'tenant', (select jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone,
                 'vat_registered', t.vat_registered, 'invoice_mode', t.invoice_mode) from public.tenants t where t.id = d.tenant_id),
    'branch', (select jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name) from public.branches b where b.id = d.branch_id),
    'device', jsonb_build_object('id', d.id, 'terminal_code', d.terminal_code, 'name', d.name),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'display_name', s.display_name, 'role', s.role) order by s.display_name), '[]')
                from public.staff s where s.tenant_id = d.tenant_id and s.active
                 and (s.role = 'owner' or exists (select 1 from public.staff_branches sb where sb.staff_id = s.id and sb.branch_id = d.branch_id))),
    'tax_codes',  (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.tax_codes x where x.tenant_id = d.tenant_id and x.deleted_at is null),
    'categories', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order), '[]') from public.categories x where x.tenant_id = d.tenant_id and x.deleted_at is null),
    'products',   (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.products x where x.tenant_id = d.tenant_id and x.deleted_at is null),
    'variants',   (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.product_variants x where x.tenant_id = d.tenant_id and x.deleted_at is null),
    'barcodes',   (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.product_barcodes x where x.tenant_id = d.tenant_id),
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', b.variant_id, 'qty', b.qty, 'updated_at', b.updated_at)), '[]')
                from public.inventory_balances b join public.locations l on l.id = b.location_id
               where l.tenant_id = d.tenant_id and l.branch_id = d.branch_id and l.kind = 'sellable'),
    'invoice_series', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'prefix', s.prefix, 'last_issued', s.last_issued, 'mode', s.mode)), '[]')
                         from public.invoice_series s where s.device_id = d.id),
    'open_shift', (select to_jsonb(s) from public.shifts s where s.device_id = d.id and s.status = 'open'),
    'cursor', case when c_tx is null then null else c_tx::text || ':' || c_id end,
    'server_time', now());
end $$;

create or replace function public.sync_pull_v1(p_device_id uuid, p_device_secret text, p_cursor text default null, p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  d public.devices := app.require_device(p_device_id, p_device_secret);
  v_xmin xid8 := pg_snapshot_xmin(pg_current_snapshot());
  c_tx xid8 := '0'; c_id bigint := 0;
  v_lim integer := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_rows jsonb; v_more boolean; v_next text;
begin
  if p_cursor is not null then
    begin
      c_tx := split_part(p_cursor, ':', 1)::xid8; c_id := split_part(p_cursor, ':', 2)::bigint;
    exception when others then raise exception 'invalid_cursor' using errcode = '22023';
    end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('entity', p.entity, 'id', p.entity_id, 'op', p.op, 'data', p.data)
                            order by p.txid, p.id) filter (where p.rn <= v_lim), '[]'),
         count(*) > v_lim,
         (array_agg(p.txid::text || ':' || p.id order by p.txid desc, p.id desc) filter (where p.rn <= v_lim))[1]
    into v_rows, v_more, v_next
    from (select l.*, row_number() over (order by l.txid, l.id) as rn
            from public.change_log l
           where l.tenant_id = d.tenant_id
             and (l.branch_id is null or l.branch_id = d.branch_id)
             and (l.txid, l.id) > (c_tx, c_id)
             and l.txid < v_xmin
           order by l.txid, l.id
           limit v_lim + 1) p;
  return jsonb_build_object('changes', v_rows, 'cursor', coalesce(v_next, p_cursor), 'has_more', v_more, 'server_time', now());
end $$;

-- ---------- command handlers ----------
create or replace function app.cmd_shift_open(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare s public.staff; v_float bigint := (p->>'opening_float')::bigint; v_id uuid := (p->>'shift_id')::uuid;
begin
  s := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);
  if v_id is null then raise exception 'missing_shift_id'; end if;
  if v_float is null or v_float < 0 then raise exception 'invalid_opening_float'; end if;
  insert into public.shifts(id, tenant_id, branch_id, device_id, staff_id, opening_float, opened_at, business_date)
  values (v_id, d.tenant_id, d.branch_id, d.id, s.id, v_float, (p->>'opened_at')::timestamptz, (p->>'business_date')::date);
  perform app.audit(d.tenant_id, d.branch_id, d.id, s.id, null, 'shift.opened', null,
                    jsonb_build_object('shift_id', v_id, 'opening_float', v_float), (p->>'opened_at')::timestamptz);
  return jsonb_build_object('shift_id', v_id);
end $$;

create or replace function app.cmd_cash_movement(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare sh public.shifts; s public.staff; v_dir public.cash_direction := (p->>'direction')::public.cash_direction;
  v_amt bigint := (p->>'amount')::bigint; v_appr uuid;
begin
  select * into sh from public.shifts where id = (p->>'shift_id')::uuid and tenant_id = d.tenant_id;
  if not found or sh.device_id <> d.id or sh.status <> 'open' then raise exception 'shift_not_open_on_this_device'; end if;
  s := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);
  if v_dir = 'out' then v_appr := app.require_approver(d.tenant_id, (p->>'approved_by')::uuid); end if;
  insert into public.cash_movements(id, tenant_id, branch_id, shift_id, direction, amount, reason, staff_id, approved_by, occurred_at)
  values ((p->>'id')::uuid, d.tenant_id, d.branch_id, sh.id, v_dir, v_amt, p->>'reason', s.id, v_appr, (p->>'occurred_at')::timestamptz);
  perform app.audit(d.tenant_id, d.branch_id, d.id, s.id, v_appr, 'cash.' || v_dir::text, p->>'reason',
                    jsonb_build_object('amount', v_amt, 'shift_id', sh.id), (p->>'occurred_at')::timestamptz);
  return jsonb_build_object('cash_movement_id', p->>'id');
end $$;

create or replace function app.shift_expected_cash(p_shift uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select sh.opening_float
       + coalesce((select sum(pm.amount) from public.payments pm join public.sales s on s.id = pm.sale_id
                    where s.shift_id = sh.id and pm.method = 'cash'), 0)
       + coalesce((select sum(case when cm.direction = 'in' then cm.amount else -cm.amount end)
                     from public.cash_movements cm where cm.shift_id = sh.id), 0)
       -- cash refunds are subtracted here once returns land (M4)
  from public.shifts sh where sh.id = p_shift
$$;

create or replace function app.cmd_shift_close(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare sh public.shifts; v_expected bigint; v_counted bigint := (p->>'counted_cash')::bigint; v_rev uuid; v_closer public.staff;
begin
  select * into sh from public.shifts where id = (p->>'shift_id')::uuid and tenant_id = d.tenant_id for update;
  if not found or sh.device_id <> d.id or sh.status <> 'open' then raise exception 'shift_not_open_on_this_device'; end if;
  if v_counted is null or v_counted < 0 then raise exception 'invalid_counted_cash'; end if;
  v_closer := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);
  v_rev := app.require_approver(d.tenant_id, (p->>'reviewer_id')::uuid);
  v_expected := app.shift_expected_cash(sh.id);
  update public.shifts set status = 'closed', closed_at = (p->>'closed_at')::timestamptz, expected_cash = v_expected,
         counted_cash = v_counted, variance = v_counted - v_expected, close_note = p->>'note', reviewer_id = v_rev
   where id = sh.id;
  perform app.audit(d.tenant_id, d.branch_id, d.id, v_closer.id, v_rev, 'shift.closed', p->>'note',
                    jsonb_build_object('shift_id', sh.id, 'expected', v_expected, 'counted', v_counted, 'variance', v_counted - v_expected),
                    (p->>'closed_at')::timestamptz);
  return jsonb_build_object('shift_id', sh.id, 'expected_cash', v_expected, 'counted_cash', v_counted, 'variance', v_counted - v_expected);
end $$;

-- Server re-checks every number the device sent. Prices that changed since are flagged, never rewritten.
create or replace function app.cmd_sale_complete(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_sale uuid := (p->>'sale_id')::uuid;
  v_num bigint := (p->>'invoice_number')::bigint;
  v_occ timestamptz := (p->>'occurred_at')::timestamptz;
  t jsonb := p->'totals';
  sh public.shifts; s public.staff; ser public.invoice_series;
  l jsonb; pay jsonb; v_exc jsonb := '[]';
  g bigint := 0; dsc bigint := 0; nt bigint := 0; vt bigint := 0; vat_net bigint := 0; ex bigint := 0; zr bigint := 0; nv bigint := 0; paid bigint := 0;
  q numeric; pr bigint; lg bigint; ld bigint; ln bigint; lv bigint; tr public.tax_treatment; rt integer; cat bigint;
  v_loc uuid; v_bal numeric; v_label text; v_line text; v_m public.payment_method; v_appr uuid;
begin
  if v_sale is null then raise exception 'missing_sale_id'; end if;
  if v_occ is null or (p->>'business_date') is null then raise exception 'missing_time_or_business_date'; end if;
  select * into sh from public.shifts where id = (p->>'shift_id')::uuid and tenant_id = d.tenant_id;
  if not found or sh.device_id <> d.id then raise exception 'shift_not_found_for_this_device'; end if;
  s := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);

  select * into ser from public.invoice_series where id = (p->>'invoice_series_id')::uuid and tenant_id = d.tenant_id for update;
  if not found or ser.device_id <> d.id then raise exception 'invoice_series_not_assigned_to_this_device'; end if;
  if v_num is null or v_num < 1 then raise exception 'invalid_invoice_number'; end if;
  if exists (select 1 from public.sales x where x.tenant_id = d.tenant_id and x.invoice_series_id = ser.id and x.invoice_number = v_num) then
    raise exception 'invoice_number_already_used';
  end if;
  v_label := ser.prefix || '-' || lpad(v_num::text, 6, '0');

  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 500 then raise exception 'invalid_lines'; end if;
  if jsonb_typeof(p->'payments') is distinct from 'array' or jsonb_array_length(p->'payments') not between 1 and 10 then raise exception 'invalid_payments'; end if;

  -- pass 1: validate lines and recompute totals
  for l in select value from jsonb_array_elements(p->'lines') loop
    v_line := coalesce(l->>'line_no', '?');
    q := (l->>'qty')::numeric; pr := (l->>'unit_price')::bigint; ld := coalesce((l->>'discount')::bigint, 0);
    if q is null or q <= 0 or q <> trunc(q) then raise exception 'line %: quantity must be a whole number above zero', v_line; end if;
    if pr is null or pr < 0 then raise exception 'line %: invalid unit price', v_line; end if;
    lg := pr * q::bigint;
    if (l->>'gross')::bigint is distinct from lg then raise exception 'line %: gross should be %', v_line, lg; end if;
    if ld < 0 or ld > lg then raise exception 'line %: invalid discount', v_line; end if;
    ln := lg - ld;
    if (l->>'net')::bigint is distinct from ln then raise exception 'line %: net should be %', v_line, ln; end if;
    tr := (l->>'tax_treatment')::public.tax_treatment; rt := coalesce((l->>'tax_rate_bp')::integer, 0);
    if tr <> 'vatable' and rt <> 0 then raise exception 'line %: only VATable lines carry a VAT rate', v_line; end if;
    lv := case when tr = 'vatable' then app.vat_in(ln, rt) else 0 end;
    if (l->>'vat')::bigint is distinct from lv then raise exception 'line %: VAT should be %', v_line, lv; end if;
    g := g + lg; dsc := dsc + ld; nt := nt + ln; vt := vt + lv;
    case tr when 'vatable' then vat_net := vat_net + ln; when 'exempt' then ex := ex + ln;
            when 'zero_rated' then zr := zr + ln; else nv := nv + ln; end case;
    if l->>'variant_id' is not null then
      select pv.price_centavos into cat from public.product_variants pv where pv.id = (l->>'variant_id')::uuid and pv.tenant_id = d.tenant_id;
      if not found then raise exception 'line %: unknown product', v_line; end if;
      if cat <> pr then
        v_exc := v_exc || jsonb_build_object('type', 'price_differs', 'line_no', (l->>'line_no')::int, 'catalog_price', cat, 'sold_price', pr);
      end if;
    end if;
  end loop;

  if t is null
     or (t->>'gross')::bigint is distinct from g or (t->>'discount')::bigint is distinct from dsc
     or (t->>'payable')::bigint is distinct from nt or (t->>'vat')::bigint is distinct from vt
     or (t->>'vatable_sales')::bigint is distinct from (vat_net - vt) or (t->>'exempt_sales')::bigint is distinct from ex
     or coalesce((t->>'zero_rated_sales')::bigint, 0) <> zr or coalesce((t->>'non_vat_sales')::bigint, 0) <> nv then
    raise exception 'totals_mismatch: expected gross %, discount %, payable %, vat %, vatable %, exempt %', g, dsc, nt, vt, vat_net - vt, ex;
  end if;

  for pay in select value from jsonb_array_elements(p->'payments') loop
    paid := paid + (pay->>'amount')::bigint;
  end loop;
  if paid <> nt then raise exception 'payments_do_not_match_total: paid %, due %', paid, nt; end if;

  select id into v_loc from public.locations where tenant_id = d.tenant_id and branch_id = d.branch_id and kind = 'sellable';
  if v_loc is null then raise exception 'branch_has_no_sellable_location'; end if;

  -- pass 2: write
  insert into public.sales(id, tenant_id, branch_id, device_id, shift_id, staff_id, ref, invoice_series_id, invoice_number, invoice_label,
    business_date, occurred_at, gross, discount, payable, vat, vatable_sales, exempt_sales, zero_rated_sales, non_vat_sales, discount_info, command_id)
  values (v_sale, d.tenant_id, d.branch_id, d.id, sh.id, s.id, coalesce(p->>'ref', 'S-' || left(v_sale::text, 8)), ser.id, v_num, v_label,
    (p->>'business_date')::date, v_occ, g, dsc, nt, vt, vat_net - vt, ex, zr, nv, p->'discount_info', p_cmd);

  for l in select value from jsonb_array_elements(p->'lines') loop
    insert into public.sale_items(tenant_id, branch_id, sale_id, line_no, variant_id, sku, name, unit, unit_price, qty,
      tax_treatment, tax_rate_bp, gross, discount, net, vat)
    values (d.tenant_id, d.branch_id, v_sale, (l->>'line_no')::smallint, (l->>'variant_id')::uuid, l->>'sku', l->>'name', coalesce(l->>'unit', 'pc'),
      (l->>'unit_price')::bigint, (l->>'qty')::numeric, (l->>'tax_treatment')::public.tax_treatment, coalesce((l->>'tax_rate_bp')::integer, 0),
      (l->>'gross')::bigint, coalesce((l->>'discount')::bigint, 0), (l->>'net')::bigint, (l->>'vat')::bigint);
    if l->>'variant_id' is not null then
      v_bal := app.post_movement(d.tenant_id, d.branch_id, v_loc, (l->>'variant_id')::uuid, 'sale', -((l->>'qty')::numeric),
                                 'sale', v_sale, null, s.id, d.id, v_occ);
      if v_bal < 0 then
        v_exc := v_exc || jsonb_build_object('type', 'oversold', 'line_no', (l->>'line_no')::int, 'variant_id', l->>'variant_id', 'balance_after', v_bal);
      end if;
    end if;
  end loop;

  for pay in select value from jsonb_array_elements(p->'payments') loop
    v_m := (pay->>'method')::public.payment_method;
    v_appr := case when v_m = 'cash' then null else (app.staff_for_branch(d.tenant_id, d.branch_id, coalesce((pay->>'verified_by')::uuid, s.id))).id end;
    insert into public.payments(id, tenant_id, branch_id, sale_id, method, status, amount, tendered, change_given, reference, verified_by, verified_at)
    values ((pay->>'id')::uuid, d.tenant_id, d.branch_id, v_sale, v_m,
            case when v_m = 'cash' then 'collected'::public.payment_status else 'manually_verified' end,
            (pay->>'amount')::bigint, coalesce((pay->>'tendered')::bigint, (pay->>'amount')::bigint), coalesce((pay->>'change_given')::bigint, 0),
            pay->>'reference', v_appr, case when v_m = 'cash' then null else coalesce((pay->>'verified_at')::timestamptz, v_occ) end);
  end loop;

  insert into public.sale_exceptions(tenant_id, branch_id, sale_id, type, detail)
  select d.tenant_id, d.branch_id, v_sale, e->>'type', e from jsonb_array_elements(v_exc) e;

  update public.invoice_series set last_issued = greatest(last_issued, v_num) where id = ser.id;
  perform app.audit(d.tenant_id, d.branch_id, d.id, s.id, nullif(p->'discount_info'->>'approved_by', '')::uuid, 'sale.completed', null,
                    jsonb_build_object('sale_id', v_sale, 'invoice', v_label, 'payable', nt), v_occ);
  return jsonb_build_object('sale_id', v_sale, 'invoice_label', v_label, 'exceptions', v_exc);
end $$;

-- ---------- push ----------
create or replace function public.sync_push_v1(p_device_id uuid, p_device_secret text, p_commands jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  d public.devices := app.require_device(p_device_id, p_device_secret);
  cmd jsonb; v_id uuid; v_type text; v_hash text; ex public.sync_commands; v_res jsonb; v_out jsonb := '[]';
  v_msg text; v_state text; v_con text;
begin
  if jsonb_typeof(p_commands) is distinct from 'array' or jsonb_array_length(p_commands) > 100 then
    raise exception 'commands must be an array of at most 100' using errcode = '22023';
  end if;

  for cmd in select value from jsonb_array_elements(p_commands) order by (value->>'local_sequence')::bigint nulls last loop
    begin
      v_id := (cmd->>'command_id')::uuid;
    exception when others then v_id := null;
    end;
    if v_id is null then
      v_out := v_out || jsonb_build_object('command_id', cmd->>'command_id', 'status', 'rejected', 'reason', 'invalid_command_id');
      continue;
    end if;
    v_type := cmd->>'type';
    v_hash := app.sha256_hex(concat_ws('|', v_type, cmd->>'schema_version', cmd->>'aggregate_id', (cmd->'payload')::text));

    select * into ex from public.sync_commands where tenant_id = d.tenant_id and command_id = v_id;
    if found then
      if ex.payload_hash = v_hash and ex.device_id = d.id then
        v_out := v_out || jsonb_build_object('command_id', v_id, 'status', 'duplicate', 'original_status', ex.status, 'reason', ex.reason, 'result', ex.result);
      else
        v_out := v_out || jsonb_build_object('command_id', v_id, 'status', 'rejected', 'reason', 'idempotency_conflict');
      end if;
      continue;
    end if;

    begin
      if coalesce((cmd->>'schema_version')::integer, 0) <> 1 then raise exception 'unsupported_schema_version'; end if;
      v_res := case v_type
        when 'shift.open'     then app.cmd_shift_open(d, v_id, cmd->'payload')
        when 'cash.movement'  then app.cmd_cash_movement(d, v_id, cmd->'payload')
        when 'sale.complete'  then app.cmd_sale_complete(d, v_id, cmd->'payload')
        when 'shift.close'    then app.cmd_shift_close(d, v_id, cmd->'payload')
        else null end;
      if v_res is null then raise exception 'unknown_command_type: %', v_type; end if;
      insert into public.sync_commands(tenant_id, command_id, device_id, type, schema_version, aggregate_id, local_sequence, occurred_at, payload_hash, status, result)
      values (d.tenant_id, v_id, d.id, v_type, 1, (cmd->>'aggregate_id')::uuid, (cmd->>'local_sequence')::bigint,
              (cmd->>'occurred_at')::timestamptz, v_hash, 'applied', v_res);
      v_out := v_out || jsonb_build_object('command_id', v_id, 'status', 'applied', 'result', v_res);
    exception when others then
      get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate, v_con = constraint_name;
      if v_state in ('40001', '40P01', '55P03') or (v_state = '23505' and v_con = 'sync_commands_pkey') then
        v_out := v_out || jsonb_build_object('command_id', v_id, 'status', 'retry', 'reason', v_state);
      else
        insert into public.sync_commands(tenant_id, command_id, device_id, type, schema_version, aggregate_id, local_sequence, occurred_at, payload_hash, status, reason)
        values (d.tenant_id, v_id, d.id, coalesce(v_type, '?'), coalesce((cmd->>'schema_version')::integer, 0), null,
                (cmd->>'local_sequence')::bigint, now(), v_hash, 'rejected', v_msg)
        on conflict do nothing;
        v_out := v_out || jsonb_build_object('command_id', v_id, 'status', 'rejected', 'reason', v_msg);
      end if;
    end;
  end loop;

  update public.devices set last_seen_at = now() where id = d.id;
  return jsonb_build_object('outcomes', v_out, 'server_time', now());
end $$;

-- ---------- dev only: attach a Supabase Auth user to a tenant (SQL editor / service role) ----------
create or replace function app.dev_attach_user(p_email text, p_tenant uuid, p_role public.staff_role, p_display_name text) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid; v_staff uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then raise exception 'no auth user with email %', p_email; end if;
  insert into public.staff(tenant_id, user_id, display_name, role) values (p_tenant, v_user, p_display_name, p_role) returning id into v_staff;
  insert into public.staff_branches(tenant_id, staff_id, branch_id) select p_tenant, v_staff, b.id from public.branches b where b.tenant_id = p_tenant;
  return v_staff;
end $$;

-- ---------- privileges ----------
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function app.current_staff_id(), app.current_tenant_id(), app.staff_role_now(),
  app.can_access_branch(uuid), app.is_manager() to authenticated;
revoke execute on function public.create_enrollment_code_v1(uuid, text), public.enroll_device_v1(text, text, text),
  public.revoke_device_v1(uuid, text), public.bootstrap_v1(uuid, text), public.sync_pull_v1(uuid, text, text, integer),
  public.sync_push_v1(uuid, text, jsonb) from public, anon;
grant execute on function public.create_enrollment_code_v1(uuid, text), public.enroll_device_v1(text, text, text),
  public.revoke_device_v1(uuid, text), public.bootstrap_v1(uuid, text), public.sync_pull_v1(uuid, text, text, integer),
  public.sync_push_v1(uuid, text, jsonb) to authenticated;
