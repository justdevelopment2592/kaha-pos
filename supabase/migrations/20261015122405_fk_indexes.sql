-- Cover remaining foreign keys (advisor 0001).
create index devices_enrolled_by_idx          on public.devices(tenant_id, enrolled_by);
create index devices_revoked_by_idx           on public.devices(tenant_id, revoked_by);
create index enrollment_codes_created_by_idx  on public.enrollment_codes(tenant_id, created_by);
create index enrollment_codes_used_device_idx on public.enrollment_codes(used_by_device);
create index inventory_balances_location_idx  on public.inventory_balances(tenant_id, location_id);
create index shifts_device_idx                on public.shifts(tenant_id, device_id);
create index staff_branches_staff_idx         on public.staff_branches(tenant_id, staff_id);
