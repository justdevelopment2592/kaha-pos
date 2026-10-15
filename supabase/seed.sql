-- Kaha POS · demo merchant. Safe to run on a fresh database only.
do $$
declare
  t uuid := '11111111-1111-4111-8111-111111111111';
  b1 uuid := '22222222-2222-4222-8222-222222222201';
  b2 uuid := '22222222-2222-4222-8222-222222222202';
  tv uuid; te uuid; c uuid; p uuid; v uuid; loc uuid; r record;
begin
  insert into public.tenants(id, name) values (t, 'Tindahan Demo Trading');
  insert into public.branches(id, tenant_id, code, name) values (b1, t, 'CR', 'Calle Real Branch'), (b2, t, 'PB', 'Poblacion Branch');
  insert into public.locations(tenant_id, branch_id, kind, name)
    select t, b, k, n from (values (b1,'sellable'::public.location_kind,'Shelf'),(b1,'damaged','Damaged / hold'),(b1,'in_transit','In transit'),
                                   (b2,'sellable','Shelf'),(b2,'damaged','Damaged / hold'),(b2,'in_transit','In transit')) x(b,k,n);
  insert into public.tax_codes(tenant_id, code, name, treatment, rate_bp) values (t,'V12','VATable 12%','vatable',1200) returning id into tv;
  insert into public.tax_codes(tenant_id, code, name, treatment, rate_bp) values (t,'EX','VAT-exempt (demo assumption)','exempt',0) returning id into te;
  insert into public.tax_codes(tenant_id, code, name, treatment, rate_bp) values (t,'ZR','Zero-rated','zero_rated',0);

  for r in select * from (values
    (1,'Noodles & canned'),(2,'Beverages'),(3,'Snacks'),(4,'Rice & staples'),(5,'Household'),(6,'Personal care')) x(sort, name) loop
    insert into public.categories(tenant_id, name, sort_order) values (t, r.name, r.sort);
  end loop;

  select id into loc from public.locations where branch_id = b1 and kind = 'sellable';
  for r in select * from (values
    ('NDL-001','Pancit canton, calamansi 80g','Noodles & canned',1650,'V','4800016644221','pc',120),
    ('NDL-002','Instant mami, beef 55g','Noodles & canned',1100,'V','4800016644238','pc',80),
    ('CAN-001','Corned beef 150g','Noodles & canned',4475,'V','4800110010235','can',24),
    ('CAN-002','Sardines in tomato sauce 155g','Noodles & canned',2650,'V','4800194104042','can',40),
    ('CAN-003','Meat loaf 150g','Noodles & canned',2875,'V','4800110010440','can',18),
    ('DRK-001','Cola 1.5L','Beverages',8500,'V','4801981116072','btl',30),
    ('DRK-002','Bottled water 500ml','Beverages',1500,'V','4800049720112','btl',96),
    ('DRK-003','3-in-1 coffee, 10 sachets','Beverages',11800,'V','4800361385021','pack',15),
    ('DRK-004','Calamansi juice 1L','Beverages',7200,'V','4800024560019','btl',12),
    ('DRK-005','Evaporated milk 370ml','Beverages',4250,'V','4800092110014','can',36),
    ('SNK-001','Cheese crackers, 10 packs','Snacks',6400,'V','4800092330212','pack',20),
    ('SNK-002','Banana chips 100g','Snacks',3500,'V','4806501700125','pack',14),
    ('SNK-003','Chocolate wafer stick','Snacks',900,'V','4800194117202','pc',150),
    ('SNK-004','Peanuts, garlic 100g','Snacks',3200,'V','4800024555213','pack',22),
    ('RIC-001','Well-milled rice, 1kg','Rice & staples',5200,'E','2000000000015','kg-bag',50),
    ('RIC-002','Fresh eggs, tray of 12','Rice & staples',10800,'E','2000000000022','tray',8),
    ('RIC-003','Brown sugar 1kg','Rice & staples',8600,'V','4800047100114','bag',16),
    ('RIC-004','Iodized salt 500g','Rice & staples',2200,'V','4800047100220','bag',30),
    ('RIC-005','Cooking oil 1L','Rice & staples',12500,'V','4800047820017','btl',10),
    ('HOM-001','Dishwashing liquid 250ml','Household',4950,'V','4800888136058','btl',12),
    ('HOM-002','Laundry powder 1kg','Household',13900,'V','4800888192016','bag',9),
    ('HOM-003','Bath soap 90g','Personal care',3850,'V','4800888180012','pc',40),
    ('CAR-001','Shampoo sachet, 12-pack','Personal care',6600,'V','4800888174011','pack',25),
    ('CAR-002','Toothpaste 100ml','Personal care',8900,'V','4800888120019','tube',2)
  ) x(sku, name, cat, price, tax, barcode, unit, stock) loop
    select id into c from public.categories where tenant_id = t and name = r.cat;
    insert into public.products(tenant_id, category_id, name) values (t, c, r.name) returning id into p;
    insert into public.product_variants(tenant_id, product_id, sku, unit, tax_code_id, price_centavos)
      values (t, p, r.sku, r.unit, case when r.tax = 'E' then te else tv end, r.price) returning id into v;
    insert into public.product_barcodes(tenant_id, variant_id, barcode) values (t, v, r.barcode);
    perform app.post_movement(t, b1, loc, v, 'opening_balance', r.stock, 'seed', null, 'Demo opening balance', null, null, now());
  end loop;
end $$;
