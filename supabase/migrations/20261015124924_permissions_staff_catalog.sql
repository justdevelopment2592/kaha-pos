-- Kaha POS · permissions matrix, staff invitations, store onboarding, item management (RPC-only, audited)

-- ---------- permission catalog ----------
create table public.permissions (
  code        text primary key,
  label       text not null,
  description text not null,
  owner_only  boolean not null default false,
  sort_order  integer not null default 0
);
insert into public.permissions(code, label, description, owner_only, sort_order) values
  ('checkout.sell',     'Sell at checkout',          'Open shifts, ring up sales, hold carts, take payments', false, 10),
  ('discount.approve',  'Approve discounts',         'Approve discounts above the cashier limit',             false, 20),
  ('refund.approve',    'Approve returns',           'Approve returns and refunds',                          false, 30),
  ('cash.approve',      'Approve cash out',          'Approve taking cash out of a drawer',                  false, 40),
  ('shift.review',      'Review shift close',        'Sign off closed shifts and cash differences',          false, 50),
  ('catalog.manage',    'Manage items',              'Add and edit items, prices, barcodes and tax codes',   false, 60),
  ('stock.receive',     'Receive stock',             'Record deliveries and opening stock',                  false, 70),
  ('stock.adjust',      'Adjust stock',              'Correct stock counts with a reason',                   false, 80),
  ('staff.manage',      'Manage users',              'Invite users, change roles and branches, deactivate',  false, 90),
  ('devices.manage',    'Manage devices',            'Register and remove terminals',                        false, 100),
  ('reports.view',      'View reports',              'See sales, cash and stock reports',                    false, 110),
  ('settings.manage',   'Store settings',            'Change store settings and what each role can do',      true,  120);
alter table public.permissions enable row level security;
create policy permissions_read on public.permissions for select to authenticated using (true);
revoke insert, update, delete, truncate on public.permissions from authenticated;

-- What each role may do, per store. Owners always have everything and are not listed.
create table public.role_permissions (
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  role       public.staff_role not null check (role <> 'owner'),
  permission text not null references public.permissions(code),
  primary key (tenant_id, role, permission)
);
create index role_permissions_perm_idx on public.role_permissions(permission);
alter table public.role_permissions enable row level security;
create policy role_permissions_read on public.role_permissions for select to authenticated
  using (tenant_id = (select app.current_tenant_id()));
revoke insert, update, delete, truncate on public.role_permissions from authenticated;

create or replace function app.seed_role_permissions(p_tenant uuid) returns void
language sql volatile security definer set search_path = '' as $$
  insert into public.role_permissions(tenant_id, role, permission)
  select p_tenant, r.role::public.staff_role, r.perm from (values
    ('manager','checkout.sell'),('manager','discount.approve'),('manager','refund.approve'),('manager','cash.approve'),
    ('manager','shift.review'),('manager','catalog.manage'),('manager','stock.receive'),('manager','stock.adjust'),
    ('manager','staff.manage'),('manager','devices.manage'),('manager','reports.view'),
    ('cashier','checkout.sell'),
    ('inventory','stock.receive')) r(role, perm)
  on conflict do nothing
$$;
select app.seed_role_permissions(id) from public.tenants;

create or replace function app.staff_has_permission(p_staff uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff s
    where s.id = p_staff and s.active
      and (s.role = 'owner'
           or exists (select 1 from public.role_permissions rp
                       where rp.tenant_id = s.tenant_id and rp.role = s.role and rp.permission = p_perm)))
$$;

create or replace function app.has_permission(p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(app.staff_has_permission(app.current_staff_id(), p_perm), false)
$$;

create or replace function app.require_permission(p_perm text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v uuid := app.current_staff_id();
begin
  if v is null then raise exception 'not_staff' using errcode = '42501'; end if;
  if not app.staff_has_permission(v, p_perm) then
    raise exception 'missing_permission: %', p_perm using errcode = '42501';
  end if;
  return v;
end $$;

-- Approver named inside an offline command must hold the matching permission.
create or replace function app.require_approver_for(p_tenant uuid, p_staff uuid, p_perm text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_staff is null or not exists (select 1 from public.staff s where s.id = p_staff and s.tenant_id = p_tenant)
     or not app.staff_has_permission(p_staff, p_perm) then
    raise exception 'approval_requires_permission: %', p_perm;
  end if;
  return p_staff;
end $$;

-- Re-point existing checks at the permission matrix.
create or replace function public.create_enrollment_code_v1(p_branch_id uuid, p_terminal_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_staff uuid := app.require_permission('devices.manage');
  v_tenant uuid := app.current_tenant_id();
  v_code text; v_exp timestamptz := now() + interval '24 hours';
begin
  if not app.can_access_branch(p_branch_id) then raise exception 'branch_not_found' using errcode = '42501'; end if;
  if upper(coalesce(p_terminal_code, '')) !~ '^T[0-9]{2}$' then raise exception 'terminal_code_must_look_like_T01' using errcode = '22023'; end if;
  v_code := app.random_code(4) || '-' || app.random_code(4);
  insert into public.enrollment_codes(tenant_id, branch_id, terminal_code, code_hash, expires_at, created_by)
  values (v_tenant, p_branch_id, upper(p_terminal_code), app.sha256_hex(v_code), v_exp, v_staff);
  perform app.audit(v_tenant, p_branch_id, null, v_staff, null, 'device.enrollment_code_created', null,
                    jsonb_build_object('terminal_code', upper(p_terminal_code), 'expires_at', v_exp));
  return jsonb_build_object('code', v_code, 'terminal_code', upper(p_terminal_code), 'expires_at', v_exp);
end $$;

create or replace function public.revoke_device_v1(p_device_id uuid, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare d public.devices; v_staff uuid := app.require_permission('devices.manage');
begin
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'reason_required' using errcode = '22023'; end if;
  select * into d from public.devices where id = p_device_id and tenant_id = app.current_tenant_id() for update;
  if not found or not app.can_access_branch(d.branch_id) then raise exception 'device_not_found' using errcode = '42501'; end if;
  if d.status = 'revoked' then return jsonb_build_object('device_id', d.id, 'status', 'revoked'); end if;
  update public.devices set status = 'revoked', revoked_at = now(), revoked_by = v_staff, revoke_reason = p_reason where id = d.id;
  perform app.audit(d.tenant_id, d.branch_id, d.id, v_staff, null, 'device.revoked', p_reason, '{}');
  return jsonb_build_object('device_id', d.id, 'status', 'revoked');
end $$;

create or replace function app.cmd_cash_movement(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare sh public.shifts; s public.staff; v_dir public.cash_direction := (p->>'direction')::public.cash_direction;
  v_amt bigint := (p->>'amount')::bigint; v_appr uuid;
begin
  select * into sh from public.shifts where id = (p->>'shift_id')::uuid and tenant_id = d.tenant_id;
  if not found or sh.device_id <> d.id or sh.status <> 'open' then raise exception 'shift_not_open_on_this_device'; end if;
  s := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);
  if v_dir = 'out' then v_appr := app.require_approver_for(d.tenant_id, (p->>'approved_by')::uuid, 'cash.approve'); end if;
  insert into public.cash_movements(id, tenant_id, branch_id, shift_id, direction, amount, reason, staff_id, approved_by, occurred_at)
  values ((p->>'id')::uuid, d.tenant_id, d.branch_id, sh.id, v_dir, v_amt, p->>'reason', s.id, v_appr, (p->>'occurred_at')::timestamptz);
  perform app.audit(d.tenant_id, d.branch_id, d.id, s.id, v_appr, 'cash.' || v_dir::text, p->>'reason',
                    jsonb_build_object('amount', v_amt, 'shift_id', sh.id), (p->>'occurred_at')::timestamptz);
  return jsonb_build_object('cash_movement_id', p->>'id');
end $$;

create or replace function app.cmd_shift_close(d public.devices, p_cmd uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare sh public.shifts; v_expected bigint; v_counted bigint := (p->>'counted_cash')::bigint; v_rev uuid; v_closer public.staff;
begin
  select * into sh from public.shifts where id = (p->>'shift_id')::uuid and tenant_id = d.tenant_id for update;
  if not found or sh.device_id <> d.id or sh.status <> 'open' then raise exception 'shift_not_open_on_this_device'; end if;
  if v_counted is null or v_counted < 0 then raise exception 'invalid_counted_cash'; end if;
  v_closer := app.staff_for_branch(d.tenant_id, d.branch_id, (p->>'staff_id')::uuid);
  v_rev := app.require_approver_for(d.tenant_id, (p->>'reviewer_id')::uuid, 'shift.review');
  v_expected := app.shift_expected_cash(sh.id);
  update public.shifts set status = 'closed', closed_at = (p->>'closed_at')::timestamptz, expected_cash = v_expected,
         counted_cash = v_counted, variance = v_counted - v_expected, close_note = p->>'note', reviewer_id = v_rev
   where id = sh.id;
  perform app.audit(d.tenant_id, d.branch_id, d.id, v_closer.id, v_rev, 'shift.closed', p->>'note',
                    jsonb_build_object('shift_id', sh.id, 'expected', v_expected, 'counted', v_counted, 'variance', v_counted - v_expected),
                    (p->>'closed_at')::timestamptz);
  return jsonb_build_object('shift_id', sh.id, 'expected_cash', v_expected, 'counted_cash', v_counted, 'variance', v_counted - v_expected);
end $$;
drop function app.require_approver(uuid, uuid);

-- Catalog changes now go only through audited functions.
drop policy tax_codes_insert on public.tax_codes;               drop policy tax_codes_update on public.tax_codes;
drop policy categories_insert on public.categories;             drop policy categories_update on public.categories;
drop policy products_insert on public.products;                 drop policy products_update on public.products;
drop policy product_variants_insert on public.product_variants; drop policy product_variants_update on public.product_variants;
drop policy product_barcodes_insert on public.product_barcodes; drop policy product_barcodes_update on public.product_barcodes;
drop policy product_barcodes_delete on public.product_barcodes;
revoke insert, update, delete on public.tax_codes, public.categories, public.products, public.product_variants, public.product_barcodes from authenticated;

-- ---------- invitations ----------
create table public.staff_invitations (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  email        text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  display_name text not null check (length(display_name) between 1 and 100),
  role         public.staff_role not null,
  branch_ids   uuid[] not null default '{}',
  invited_by   uuid not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '14 days',
  accepted_at  timestamptz,
  accepted_staff_id uuid,
  revoked_at   timestamptz,
  foreign key (tenant_id, invited_by) references public.staff(tenant_id, id),
  foreign key (tenant_id, accepted_staff_id) references public.staff(tenant_id, id)
);
create unique index staff_invitations_one_pending on public.staff_invitations(tenant_id, lower(email))
  where accepted_at is null and revoked_at is null;
create index staff_invitations_email_idx on public.staff_invitations(lower(email));
create index staff_invitations_invited_by_idx on public.staff_invitations(tenant_id, invited_by);
create index staff_invitations_accepted_idx on public.staff_invitations(tenant_id, accepted_staff_id);
alter table public.staff_invitations enable row level security;
create policy staff_invitations_read on public.staff_invitations for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app.has_permission('staff.manage')));
revoke insert, update, delete, truncate on public.staff_invitations from authenticated;

create or replace function app.auth_email() returns text
language sql stable security definer set search_path = '' as $$
  select lower(u.email) from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null
$$;

create or replace function app.check_branch_ids(p_tenant uuid, p_ids uuid[]) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  foreach v in array coalesce(p_ids, '{}') loop
    if not exists (select 1 from public.branches b where b.id = v and b.tenant_id = p_tenant) or not app.can_access_branch(v) then
      raise exception 'branch_not_found: %', v using errcode = '22023';
    end if;
  end loop;
  return coalesce(p_ids, '{}');
end $$;

-- ---------- who am I ----------
create or replace function public.my_profile_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.staff; v_email text;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  select lower(email) into v_email from auth.users where id = auth.uid();
  select * into s from public.staff where user_id = auth.uid();
  if not found or not s.active then
    return jsonb_build_object('user_id', auth.uid(), 'email', v_email, 'staff', null,
      'deactivated', found and not s.active,
      'invitations', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'store', t.name, 'role', i.role, 'display_name', i.display_name, 'expires_at', i.expires_at)), '[]')
                        from public.staff_invitations i join public.tenants t on t.id = i.tenant_id
                       where lower(i.email) = app.auth_email() and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()),
      'email_confirmed', app.auth_email() is not null);
  end if;
  return jsonb_build_object(
    'user_id', auth.uid(), 'email', v_email,
    'staff', jsonb_build_object('id', s.id, 'display_name', s.display_name, 'role', s.role),
    'tenant', (select jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'vat_registered', t.vat_registered, 'invoice_mode', t.invoice_mode) from public.tenants t where t.id = s.tenant_id),
    'branches', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name) order by b.name), '[]')
                   from public.branches b where b.tenant_id = s.tenant_id and app.can_access_branch(b.id)),
    'permissions', (select coalesce(jsonb_agg(p.code order by p.sort_order), '[]') from public.permissions p where app.staff_has_permission(s.id, p.code)));
end $$;

-- ---------- new store (first owner) ----------
create or replace function public.store_create_v1(p_store_name text, p_owner_name text, p_branch_code text, p_branch_name text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_t uuid; v_b uuid; v_s uuid;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  if app.auth_email() is null then raise exception 'confirm_your_email_first' using errcode = '42501'; end if;
  if exists (select 1 from public.staff where user_id = auth.uid()) then raise exception 'account_already_belongs_to_a_store' using errcode = '23505'; end if;
  insert into public.tenants(name) values (trim(p_store_name)) returning id into v_t;
  insert into public.branches(tenant_id, code, name) values (v_t, upper(trim(p_branch_code)), trim(p_branch_name)) returning id into v_b;
  insert into public.locations(tenant_id, branch_id, kind, name) values
    (v_t, v_b, 'sellable', 'Shelf'), (v_t, v_b, 'damaged', 'Damaged / hold'), (v_t, v_b, 'in_transit', 'In transit');
  insert into public.tax_codes(tenant_id, code, name, treatment, rate_bp) values
    (v_t, 'V12', 'VATable 12%', 'vatable', 1200), (v_t, 'EX', 'VAT-exempt', 'exempt', 0),
    (v_t, 'ZR', 'Zero-rated', 'zero_rated', 0), (v_t, 'NV', 'Non-VAT', 'non_vat', 0);
  perform app.seed_role_permissions(v_t);
  insert into public.staff(tenant_id, user_id, display_name, role) values (v_t, auth.uid(), trim(p_owner_name), 'owner') returning id into v_s;
  insert into public.staff_branches(tenant_id, staff_id, branch_id) values (v_t, v_s, v_b);
  perform app.audit(v_t, v_b, null, v_s, null, 'store.created', null, jsonb_build_object('name', p_store_name));
  return jsonb_build_object('tenant_id', v_t, 'branch_id', v_b, 'staff_id', v_s);
end $$;

-- ---------- users ----------
create or replace function public.staff_list_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_t uuid := app.current_tenant_id(); v_manage boolean := app.has_permission('staff.manage');
begin
  if v_t is null then raise exception 'not_staff' using errcode = '42501'; end if;
  return jsonb_build_object(
    'staff', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', s.id, 'display_name', s.display_name, 'role', s.role, 'active', s.active,
                'email', case when v_manage then (select lower(u.email) from auth.users u where u.id = s.user_id) end,
                'branch_ids', (select coalesce(jsonb_agg(sb.branch_id), '[]') from public.staff_branches sb where sb.staff_id = s.id),
                'is_me', s.user_id = auth.uid()) order by s.active desc, s.display_name), '[]')
              from public.staff s where s.tenant_id = v_t),
    'invitations', case when v_manage then (select coalesce(jsonb_agg(jsonb_build_object(
                'id', i.id, 'email', i.email, 'display_name', i.display_name, 'role', i.role, 'branch_ids', to_jsonb(i.branch_ids),
                'expires_at', i.expires_at) order by i.created_at desc), '[]')
              from public.staff_invitations i where i.tenant_id = v_t and i.accepted_at is null and i.revoked_at is null and i.expires_at > now())
              else '[]'::jsonb end);
end $$;

create or replace function public.staff_invite_v1(p_email text, p_display_name text, p_role public.staff_role, p_branch_ids uuid[]) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('staff.manage'); v_t uuid := app.current_tenant_id();
  v_email text := lower(trim(p_email)); v_ids uuid[]; v_id uuid;
begin
  if p_role = 'owner' and app.staff_role_now() <> 'owner' then raise exception 'only_owners_can_invite_owners' using errcode = '42501'; end if;
  v_ids := app.check_branch_ids(v_t, p_branch_ids);
  if p_role <> 'owner' and cardinality(v_ids) = 0 then raise exception 'pick_at_least_one_branch' using errcode = '22023'; end if;
  if exists (select 1 from public.staff s join auth.users u on u.id = s.user_id where s.tenant_id = v_t and lower(u.email) = v_email) then
    raise exception 'already_a_user_in_this_store' using errcode = '23505';
  end if;
  update public.staff_invitations set revoked_at = now()
   where tenant_id = v_t and lower(email) = v_email and accepted_at is null and revoked_at is null and expires_at <= now();
  insert into public.staff_invitations(tenant_id, email, display_name, role, branch_ids, invited_by)
  values (v_t, v_email, trim(p_display_name), p_role, v_ids, v_me) returning id into v_id;
  perform app.audit(v_t, null, null, v_me, null, 'staff.invited', null, jsonb_build_object('email', v_email, 'role', p_role, 'branch_ids', v_ids));
  return jsonb_build_object('invitation_id', v_id, 'email', v_email, 'role', p_role);
end $$;

create or replace function public.staff_invitation_revoke_v1(p_invitation_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('staff.manage'); i public.staff_invitations;
begin
  select * into i from public.staff_invitations where id = p_invitation_id and tenant_id = app.current_tenant_id() for update;
  if not found then raise exception 'invitation_not_found' using errcode = '42501'; end if;
  if i.role = 'owner' and app.staff_role_now() <> 'owner' then raise exception 'only_owners_can_change_owners' using errcode = '42501'; end if;
  update public.staff_invitations set revoked_at = now() where id = i.id and accepted_at is null;
  perform app.audit(i.tenant_id, null, null, v_me, null, 'staff.invitation_revoked', null, jsonb_build_object('email', i.email));
  return jsonb_build_object('invitation_id', i.id, 'revoked', true);
end $$;

create or replace function public.invitation_accept_v1(p_invitation_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare i public.staff_invitations; v_email text := app.auth_email(); v_s uuid; v_b uuid;
begin
  if v_email is null then raise exception 'confirm_your_email_first' using errcode = '42501'; end if;
  if exists (select 1 from public.staff where user_id = auth.uid()) then raise exception 'account_already_belongs_to_a_store' using errcode = '23505'; end if;
  select * into i from public.staff_invitations where id = p_invitation_id for update;
  if not found or lower(i.email) <> v_email or i.accepted_at is not null or i.revoked_at is not null or i.expires_at <= now() then
    raise exception 'invitation_not_valid' using errcode = '42501';
  end if;
  insert into public.staff(tenant_id, user_id, display_name, role) values (i.tenant_id, auth.uid(), i.display_name, i.role) returning id into v_s;
  foreach v_b in array i.branch_ids loop
    insert into public.staff_branches(tenant_id, staff_id, branch_id) values (i.tenant_id, v_s, v_b) on conflict do nothing;
  end loop;
  update public.staff_invitations set accepted_at = now(), accepted_staff_id = v_s where id = i.id;
  perform app.audit(i.tenant_id, null, null, v_s, i.invited_by, 'staff.joined', null, jsonb_build_object('role', i.role));
  return jsonb_build_object('staff_id', v_s, 'tenant_id', i.tenant_id);
end $$;

create or replace function public.staff_update_v1(p_staff_id uuid, p_display_name text, p_role public.staff_role, p_active boolean, p_branch_ids uuid[]) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('staff.manage'); v_t uuid := app.current_tenant_id(); s public.staff; v_ids uuid[]; v_b uuid;
begin
  select * into s from public.staff where id = p_staff_id and tenant_id = v_t for update;
  if not found then raise exception 'user_not_found' using errcode = '42501'; end if;
  if (s.role = 'owner' or p_role = 'owner') and app.staff_role_now() <> 'owner' then raise exception 'only_owners_can_change_owners' using errcode = '42501'; end if;
  if s.id = v_me and (p_role is distinct from s.role or p_active is distinct from s.active) then
    raise exception 'you_cannot_change_your_own_role_or_access' using errcode = '42501';
  end if;
  if s.role = 'owner' and (p_role <> 'owner' or not p_active)
     and not exists (select 1 from public.staff o where o.tenant_id = v_t and o.role = 'owner' and o.active and o.id <> s.id) then
    raise exception 'store_needs_at_least_one_active_owner' using errcode = '42501';
  end if;
  v_ids := app.check_branch_ids(v_t, p_branch_ids);
  if p_role <> 'owner' and p_active and cardinality(v_ids) = 0 then raise exception 'pick_at_least_one_branch' using errcode = '22023'; end if;
  update public.staff set display_name = coalesce(nullif(trim(p_display_name), ''), display_name), role = p_role, active = p_active where id = s.id;
  delete from public.staff_branches where staff_id = s.id;
  foreach v_b in array v_ids loop
    insert into public.staff_branches(tenant_id, staff_id, branch_id) values (v_t, s.id, v_b);
  end loop;
  perform app.audit(v_t, null, null, v_me, null, 'staff.updated', null,
    jsonb_build_object('staff_id', s.id, 'from', jsonb_build_object('role', s.role, 'active', s.active), 'to', jsonb_build_object('role', p_role, 'active', p_active), 'branch_ids', v_ids));
  return jsonb_build_object('staff_id', s.id, 'role', p_role, 'active', p_active);
end $$;

create or replace function public.role_permissions_set_v1(p_role public.staff_role, p_permissions text[]) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('settings.manage'); v_t uuid := app.current_tenant_id(); v_bad text;
begin
  if p_role = 'owner' then raise exception 'owners_always_have_every_permission' using errcode = '22023'; end if;
  select x into v_bad from unnest(coalesce(p_permissions, '{}')) x
   where not exists (select 1 from public.permissions p where p.code = x and not p.owner_only) limit 1;
  if v_bad is not null then raise exception 'permission_not_assignable: %', v_bad using errcode = '22023'; end if;
  delete from public.role_permissions where tenant_id = v_t and role = p_role;
  insert into public.role_permissions(tenant_id, role, permission) select distinct v_t, p_role, x from unnest(coalesce(p_permissions, '{}')) x;
  perform app.audit(v_t, null, null, v_me, null, 'roles.permissions_changed', null, jsonb_build_object('role', p_role, 'permissions', p_permissions));
  return jsonb_build_object('role', p_role, 'permissions', to_jsonb(coalesce(p_permissions, '{}')));
end $$;

-- ---------- items ----------
create or replace function public.catalog_admin_list_v1(p_branch_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_t uuid := app.current_tenant_id();
begin
  if v_t is null then raise exception 'not_staff' using errcode = '42501'; end if;
  if p_branch_id is not null and not app.can_access_branch(p_branch_id) then raise exception 'branch_not_found' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
        'variant_id', v.id, 'product_id', p.id, 'name', p.name, 'sku', v.sku, 'unit', v.unit,
        'price_centavos', v.price_centavos, 'tax_code_id', v.tax_code_id, 'category_id', p.category_id,
        'archived', v.deleted_at is not null,
        'barcodes', (select coalesce(jsonb_agg(b.barcode order by b.barcode), '[]') from public.product_barcodes b where b.variant_id = v.id),
        'stock', (select ib.qty from public.inventory_balances ib join public.locations l on l.id = ib.location_id
                   where ib.variant_id = v.id and l.branch_id = p_branch_id and l.kind = 'sellable')) order by p.name), '[]')
       from public.product_variants v join public.products p on p.id = v.product_id where v.tenant_id = v_t),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name), '[]')
                     from public.categories c where c.tenant_id = v_t and c.deleted_at is null),
    'tax_codes', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'code', x.code, 'name', x.name, 'treatment', x.treatment, 'rate_bp', x.rate_bp) order by x.code), '[]')
                    from public.tax_codes x where x.tenant_id = v_t and x.deleted_at is null));
end $$;

create or replace function public.category_save_v1(p_category_id uuid, p_name text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('catalog.manage'); v_t uuid := app.current_tenant_id(); v_id uuid;
begin
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'name_required' using errcode = '22023'; end if;
  if p_category_id is null then
    insert into public.categories(tenant_id, name, sort_order)
    values (v_t, trim(p_name), coalesce((select max(sort_order) + 1 from public.categories where tenant_id = v_t), 1)) returning id into v_id;
  else
    update public.categories set name = trim(p_name) where id = p_category_id and tenant_id = v_t returning id into v_id;
    if v_id is null then raise exception 'category_not_found' using errcode = '42501'; end if;
  end if;
  perform app.audit(v_t, null, null, v_me, null, 'catalog.category_saved', null, jsonb_build_object('id', v_id, 'name', p_name));
  return jsonb_build_object('category_id', v_id);
end $$;

-- p: {variant_id?, name, category_id?, sku, unit, tax_code_id, price_centavos, barcodes:[...]}
create or replace function public.item_save_v1(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_me uuid := app.require_permission('catalog.manage'); v_t uuid := app.current_tenant_id();
  v public.product_variants; v_prod uuid; v_var uuid := (p->>'variant_id')::uuid;
  v_name text := trim(coalesce(p->>'name', '')); v_sku text := upper(trim(coalesce(p->>'sku', '')));
  v_price bigint := (p->>'price_centavos')::bigint; v_tax uuid := (p->>'tax_code_id')::uuid; v_cat uuid := (p->>'category_id')::uuid;
  v_unit text := coalesce(nullif(trim(p->>'unit'), ''), 'pc'); v_bc text; v_bcs text[];
begin
  if length(v_name) = 0 then raise exception 'name_required' using errcode = '22023'; end if;
  if v_sku !~ '^[A-Z0-9._-]{1,40}$' then raise exception 'sku_letters_numbers_dash_dot_only' using errcode = '22023'; end if;
  if v_price is null or v_price < 0 then raise exception 'price_required' using errcode = '22023'; end if;
  if not exists (select 1 from public.tax_codes where id = v_tax and tenant_id = v_t and deleted_at is null) then raise exception 'tax_code_not_found' using errcode = '22023'; end if;
  if v_cat is not null and not exists (select 1 from public.categories where id = v_cat and tenant_id = v_t) then raise exception 'category_not_found' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct trim(x)), '{}') into v_bcs from jsonb_array_elements_text(coalesce(p->'barcodes', '[]')) x where trim(x) <> '';
  if exists (select 1 from public.product_variants x where x.tenant_id = v_t and x.sku = v_sku and x.id is distinct from v_var) then
    raise exception 'sku_already_used' using errcode = '23505';
  end if;
  select b.barcode into v_bc from public.product_barcodes b
   where b.tenant_id = v_t and b.barcode = any(v_bcs) and b.variant_id is distinct from v_var limit 1;
  if v_bc is not null then raise exception 'barcode_already_used: %', v_bc using errcode = '23505'; end if;

  if v_var is null then
    insert into public.products(tenant_id, category_id, name) values (v_t, v_cat, v_name) returning id into v_prod;
    insert into public.product_variants(tenant_id, product_id, sku, unit, tax_code_id, price_centavos)
    values (v_t, v_prod, v_sku, v_unit, v_tax, v_price) returning id into v_var;
    perform app.audit(v_t, null, null, v_me, null, 'catalog.item_created', null, jsonb_build_object('variant_id', v_var, 'sku', v_sku, 'price', v_price));
  else
    select * into v from public.product_variants where id = v_var and tenant_id = v_t for update;
    if not found then raise exception 'item_not_found' using errcode = '42501'; end if;
    update public.products set name = v_name, category_id = v_cat where id = v.product_id;
    update public.product_variants set sku = v_sku, unit = v_unit, tax_code_id = v_tax, price_centavos = v_price where id = v_var;
    perform app.audit(v_t, null, null, v_me, null, 'catalog.item_updated', null,
      jsonb_build_object('variant_id', v_var, 'sku', v_sku, 'price_from', v.price_centavos, 'price_to', v_price, 'tax_from', v.tax_code_id, 'tax_to', v_tax));
  end if;

  delete from public.product_barcodes where variant_id = v_var and not (barcode = any(v_bcs));
  insert into public.product_barcodes(tenant_id, variant_id, barcode)
  select v_t, v_var, x from unnest(v_bcs) x
   where not exists (select 1 from public.product_barcodes b where b.variant_id = v_var and b.barcode = x);
  return jsonb_build_object('variant_id', v_var);
end $$;

create or replace function public.item_archive_v1(p_variant_id uuid, p_archived boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('catalog.manage'); v_t uuid := app.current_tenant_id(); v public.product_variants;
begin
  select * into v from public.product_variants where id = p_variant_id and tenant_id = v_t for update;
  if not found then raise exception 'item_not_found' using errcode = '42501'; end if;
  update public.product_variants set deleted_at = case when p_archived then now() end where id = v.id;
  perform app.audit(v_t, null, null, v_me, null, case when p_archived then 'catalog.item_archived' else 'catalog.item_restored' end, null,
                    jsonb_build_object('variant_id', v.id, 'sku', v.sku));
  return jsonb_build_object('variant_id', v.id, 'archived', p_archived);
end $$;

create or replace function public.stock_receive_v1(p_branch_id uuid, p_variant_id uuid, p_qty numeric, p_reference text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_me uuid := app.require_permission('stock.receive'); v_t uuid := app.current_tenant_id(); v_loc uuid; v_bal numeric;
begin
  if p_qty is null or p_qty <= 0 or p_qty <> trunc(p_qty) then raise exception 'quantity_must_be_a_whole_number_above_zero' using errcode = '22023'; end if;
  if not app.can_access_branch(p_branch_id) then raise exception 'branch_not_found' using errcode = '42501'; end if;
  if not exists (select 1 from public.product_variants where id = p_variant_id and tenant_id = v_t) then raise exception 'item_not_found' using errcode = '42501'; end if;
  select id into v_loc from public.locations where tenant_id = v_t and branch_id = p_branch_id and kind = 'sellable';
  v_bal := app.post_movement(v_t, p_branch_id, v_loc, p_variant_id, 'stock_receipt', p_qty, 'stock_receipt', null,
                             nullif(trim(p_reference), ''), v_me, null, now());
  perform app.audit(v_t, p_branch_id, null, v_me, null, 'stock.received', p_reference, jsonb_build_object('variant_id', p_variant_id, 'qty', p_qty));
  return jsonb_build_object('variant_id', p_variant_id, 'on_hand', v_bal);
end $$;

-- ---------- privileges ----------
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function app.current_staff_id(), app.current_tenant_id(), app.staff_role_now(),
  app.can_access_branch(uuid), app.is_manager(), app.has_permission(text) to authenticated;
do $$ declare f text; begin
  foreach f in array array['my_profile_v1()','store_create_v1(text,text,text,text)','staff_list_v1()',
    'staff_invite_v1(text,text,public.staff_role,uuid[])','staff_invitation_revoke_v1(uuid)','invitation_accept_v1(uuid)',
    'staff_update_v1(uuid,text,public.staff_role,boolean,uuid[])','role_permissions_set_v1(public.staff_role,text[])',
    'catalog_admin_list_v1(uuid)','category_save_v1(uuid,text)','item_save_v1(jsonb)','item_archive_v1(uuid,boolean)',
    'stock_receive_v1(uuid,uuid,numeric,text)','create_enrollment_code_v1(uuid,text)','revoke_device_v1(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
