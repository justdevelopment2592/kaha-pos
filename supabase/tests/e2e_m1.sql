-- Kaha POS · M1 end-to-end check. Runs as real roles, then rolls back on purpose:
-- the final RAISE carries the results and undoes every write.
do $$
declare
  t   uuid := '11111111-1111-4111-8111-111111111111';
  b1  uuid := '22222222-2222-4222-8222-222222222201';
  tb  uuid := gen_random_uuid(); bb uuid := gen_random_uuid();
  u_owner uuid := gen_random_uuid(); u_cash uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  s_owner uuid; s_cash uuid;
  v_canton uuid; v_cola uuid; v_rice uuid; v_corned uuid; v_tooth uuid;
  r jsonb; enr jsonb; dev uuid; sec text; ser uuid; boot jsonb; code text;
  shift uuid := gen_random_uuid(); sale1 uuid := gen_random_uuid(); sale2 uuid := gen_random_uuid();
  c_open uuid := gen_random_uuid(); c_s1 uuid := gen_random_uuid(); c_s2 uuid := gen_random_uuid();
  c_bad uuid := gen_random_uuid(); c_dupinv uuid := gen_random_uuid(); c_close uuid := gen_random_uuid();
  cmd_open jsonb; a_prod uuid; a_tax uuid; cmd_s1 jsonb; cmd_s2 jsonb; out jsonb; res jsonb := '{}'; n bigint; msg text; ok boolean;
begin
  -- fixtures (as admin)
  insert into auth.users(id, email, aud, role) values
    (u_owner, 'owner.test@kaha.local', 'authenticated', 'authenticated'),
    (u_cash,  'cashier.test@kaha.local', 'authenticated', 'authenticated'),
    (u_out,   'outsider.test@kaha.local', 'authenticated', 'authenticated');
  s_owner := app.dev_attach_user('owner.test@kaha.local', t, 'owner', 'Test Owner');
  s_cash  := app.dev_attach_user('cashier.test@kaha.local', t, 'cashier', 'Test Cashier');
  insert into public.tenants(id, name) values (tb, 'Other Store');
  insert into public.branches(id, tenant_id, code, name) values (bb, tb, 'XX', 'Other Branch');
  perform app.dev_attach_user('outsider.test@kaha.local', tb, 'owner', 'Outsider');
  select id into v_canton from public.product_variants where sku = 'NDL-001';
  select id into v_cola   from public.product_variants where sku = 'DRK-001';
  select id into v_rice   from public.product_variants where sku = 'RIC-001';
  select id into v_corned from public.product_variants where sku = 'CAN-001';
  select id into v_tooth  from public.product_variants where sku = 'CAR-002';
  select product_id, tax_code_id into a_prod, a_tax from public.product_variants where sku = 'NDL-001';

  -- 1. owner creates an enrollment code
  perform set_config('request.jwt.claims', json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  code := (public.create_enrollment_code_v1(b1, 'T09'))->>'code';
  res := res || jsonb_build_object('01_code_created', code is not null);

  -- 2. cashier cannot create codes
  perform set_config('request.jwt.claims', json_build_object('sub', u_cash, 'role', 'authenticated')::text, true);
  begin perform public.create_enrollment_code_v1(b1, 'T08'); res := res || '{"02_cashier_code_blocked":false}';
  exception when others then res := res || '{"02_cashier_code_blocked":true}'; end;

  -- 3. cashier enrolls the device; code is single-use
  enr := public.enroll_device_v1(code, 'Test tablet', '0.1.0');
  dev := (enr->>'device_id')::uuid; sec := enr->>'device_secret'; ser := (enr#>>'{invoice_series,id}')::uuid;
  res := res || jsonb_build_object('03_enrolled_series', enr#>>'{invoice_series,prefix}');
  begin perform public.enroll_device_v1(code); res := res || '{"04_code_reuse_blocked":false}';
  exception when others then res := res || '{"04_code_reuse_blocked":true}'; end;

  -- 4. bootstrap
  boot := public.bootstrap_v1(dev, sec);
  res := res || jsonb_build_object('05_bootstrap_variants', jsonb_array_length(boot->'variants'), '05_bootstrap_cursor', boot->>'cursor' is not null);
  begin perform public.bootstrap_v1(dev, 'wrong-secret'); res := res || '{"06_bad_secret_blocked":false}';
  exception when others then res := res || '{"06_bad_secret_blocked":true}'; end;

  -- 5. push: open shift + fixture F-001 sale (20% discount, split e-wallet + cash)
  cmd_open := jsonb_build_object('command_id', c_open, 'schema_version', 1, 'type', 'shift.open', 'aggregate_id', shift, 'local_sequence', 1,
    'payload', jsonb_build_object('shift_id', shift, 'staff_id', s_cash, 'opening_float', 200000, 'opened_at', now(), 'business_date', current_date));
  cmd_s1 := jsonb_build_object('command_id', c_s1, 'schema_version', 1, 'type', 'sale.complete', 'aggregate_id', sale1, 'local_sequence', 2,
    'payload', jsonb_build_object('sale_id', sale1, 'ref', 'S-TEST01', 'shift_id', shift, 'staff_id', s_cash, 'occurred_at', now(), 'business_date', current_date,
      'invoice_series_id', ser, 'invoice_number', 1, 'discount_info', jsonb_build_object('type','pct','value',20,'approved_by', s_owner),
      'lines', jsonb_build_array(
        jsonb_build_object('line_no',1,'variant_id',v_canton,'sku','NDL-001','name','Pancit canton','unit','pc','unit_price',1650,'qty',2,'tax_treatment','vatable','tax_rate_bp',1200,'gross',3300,'discount',660,'net',2640,'vat',283),
        jsonb_build_object('line_no',2,'variant_id',v_cola,'sku','DRK-001','name','Cola 1.5L','unit','btl','unit_price',8500,'qty',1,'tax_treatment','vatable','tax_rate_bp',1200,'gross',8500,'discount',1700,'net',6800,'vat',729),
        jsonb_build_object('line_no',3,'variant_id',v_rice,'sku','RIC-001','name','Rice 1kg','unit','kg-bag','unit_price',5200,'qty',1,'tax_treatment','exempt','tax_rate_bp',0,'gross',5200,'discount',1040,'net',4160,'vat',0),
        jsonb_build_object('line_no',4,'variant_id',v_corned,'sku','CAN-001','name','Corned beef','unit','can','unit_price',4475,'qty',1,'tax_treatment','vatable','tax_rate_bp',1200,'gross',4475,'discount',895,'net',3580,'vat',384)),
      'totals', jsonb_build_object('gross',21475,'discount',4295,'payable',17180,'vat',1396,'vatable_sales',11624,'exempt_sales',4160,'zero_rated_sales',0,'non_vat_sales',0),
      'payments', jsonb_build_array(
        jsonb_build_object('id', gen_random_uuid(), 'method','ewallet_manual','amount',5000,'reference','10293847','verified_by', s_cash),
        jsonb_build_object('id', gen_random_uuid(), 'method','cash','amount',12180,'tendered',50000,'change_given',37820))));
  -- oversold: toothpaste x3 with 2 on hand
  cmd_s2 := jsonb_build_object('command_id', c_s2, 'schema_version', 1, 'type', 'sale.complete', 'aggregate_id', sale2, 'local_sequence', 3,
    'payload', jsonb_build_object('sale_id', sale2, 'ref', 'S-TEST02', 'shift_id', shift, 'staff_id', s_cash, 'occurred_at', now(), 'business_date', current_date,
      'invoice_series_id', ser, 'invoice_number', 2,
      'lines', jsonb_build_array(jsonb_build_object('line_no',1,'variant_id',v_tooth,'sku','CAR-002','name','Toothpaste','unit','tube','unit_price',8900,'qty',3,'tax_treatment','vatable','tax_rate_bp',1200,'gross',26700,'discount',0,'net',26700,'vat',2861)),
      'totals', jsonb_build_object('gross',26700,'discount',0,'payable',26700,'vat',2861,'vatable_sales',23839,'exempt_sales',0),
      'payments', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'method','cash','amount',26700,'tendered',30000,'change_given',3300))));

  out := public.sync_push_v1(dev, sec, jsonb_build_array(cmd_open, cmd_s1, cmd_s2));
  res := res || jsonb_build_object('07_push_statuses', (select jsonb_agg(o->>'status') from jsonb_array_elements(out->'outcomes') o),
                                   '07_invoice', out#>>'{outcomes,1,result,invoice_label}',
                                   '07_oversold_flagged', (out#>'{outcomes,2,result,exceptions}') @> '[{"type":"oversold"}]');

  -- 6. retry after a lost reply: same commands again
  out := public.sync_push_v1(dev, sec, jsonb_build_array(cmd_open, cmd_s1));
  res := res || jsonb_build_object('08_retry_statuses', (select jsonb_agg(o->>'status') from jsonb_array_elements(out->'outcomes') o));

  -- 7. same command id, different payload
  out := public.sync_push_v1(dev, sec, jsonb_build_array(jsonb_set(cmd_s1, '{payload,ref}', '"S-CHANGED"')));
  res := res || jsonb_build_object('09_conflict', out#>>'{outcomes,0,reason}');

  -- 8. wrong VAT is rejected and kept for review
  out := public.sync_push_v1(dev, sec, jsonb_build_array(jsonb_set(jsonb_set(jsonb_set(cmd_s1,'{command_id}',to_jsonb(c_bad)),'{payload,sale_id}',to_jsonb(gen_random_uuid())),'{payload,lines,0,vat}','999')));
  res := res || jsonb_build_object('10_bad_vat', out#>>'{outcomes,0,status}', '10_reason', out#>>'{outcomes,0,reason}');

  -- 9. reused invoice number is rejected
  out := public.sync_push_v1(dev, sec, jsonb_build_array(jsonb_set(jsonb_set(cmd_s2,'{command_id}',to_jsonb(c_dupinv)),'{payload,sale_id}',to_jsonb(gen_random_uuid()))));
  res := res || jsonb_build_object('11_dup_invoice', out#>>'{outcomes,0,reason}');

  -- 10. counts after retries: exactly one of each
  execute 'reset role';
  select count(*) into n from public.sales where id in (sale1, sale2);
  res := res || jsonb_build_object('12_sales_rows', n,
    '12_canton_stock', (select qty from public.inventory_balances where variant_id = v_canton),
    '12_tooth_stock',  (select qty from public.inventory_balances where variant_id = v_tooth),
    '12_rejected_kept', (select count(*) from public.sync_commands where command_id = c_bad and status = 'rejected'));

  -- 11. pull from the bootstrap cursor sees the stock changes, cursor advances
  perform set_config('request.jwt.claims', json_build_object('sub', u_cash, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  -- (changes made in this same transaction are not yet "committed", so the safe cursor correctly holds them back)
  out := public.sync_pull_v1(dev, sec, boot->>'cursor', 100);
  res := res || jsonb_build_object('13_pull_ok', out ? 'cursor', '13_pull_rows_now', jsonb_array_length(out->'changes'));

  -- 12. RLS as cashier
  res := res || jsonb_build_object('14_cashier_sees_sales', (select count(*) from public.sales),
                                   '14_cashier_sees_devices', (select count(*) from public.devices),
                                   '14_cashier_sees_secrets', (select count(*) from public.device_secrets));
  begin insert into public.sales(id) values (gen_random_uuid()); res := res || '{"15_direct_insert_blocked":false}';
  exception when insufficient_privilege then res := res || '{"15_direct_insert_blocked":true}'; end;
  begin execute 'truncate public.audit_logs'; res := res || '{"16_truncate_blocked":false}';
  exception when insufficient_privilege then res := res || '{"16_truncate_blocked":true}'; end;

  -- 13. shift close: expected = 200000 float + 12180 + 26700 cash = 238880; counted 100 short needs a note
  out := public.sync_push_v1(dev, sec, jsonb_build_array(jsonb_build_object('command_id', c_close, 'schema_version', 1, 'type', 'shift.close', 'aggregate_id', shift, 'local_sequence', 4,
    'payload', jsonb_build_object('shift_id', shift, 'staff_id', s_cash, 'reviewer_id', s_owner, 'counted_cash', 238780, 'note', 'Wrong change once', 'closed_at', now()))));
  res := res || jsonb_build_object('17_close', out#>'{outcomes,0,result}');

  -- 14. outsider from another merchant
  perform set_config('request.jwt.claims', json_build_object('sub', u_out, 'role', 'authenticated')::text, true);
  res := res || jsonb_build_object('18_outsider_sees_sales', (select count(*) from public.sales),
                                   '18_outsider_sees_products', (select count(*) from public.product_variants));
  begin perform public.bootstrap_v1(dev, sec); res := res || '{"19_outsider_device_blocked":false}';
  exception when others then res := res || '{"19_outsider_device_blocked":true}'; end;
  begin insert into public.product_variants(tenant_id, product_id, sku, tax_code_id, price_centavos)
        values (t, a_prod, 'HACK-1', a_tax, 1);
        res := res || '{"20_cross_tenant_write_blocked":false}';
  exception when others then res := res || '{"20_cross_tenant_write_blocked":true}'; end;

  -- 15. anonymous caller
  execute 'reset role';
  execute 'set local role anon';
  begin perform public.sync_pull_v1(dev, sec); res := res || '{"21_anon_blocked":false}';
  exception when insufficient_privilege then res := res || '{"21_anon_blocked":true}'; end;
  execute 'reset role';

  raise exception 'E2E_RESULTS %', res;
end $$;
