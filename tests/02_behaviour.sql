-- Behaviour of the six DFD processes, the roles, and the safety rules.
\set ON_ERROR_STOP on
create temp table _r (ok boolean, label text);

-- run as superuser; records PASS/FAIL
create function pg_temp.ok(c boolean, label text) returns void language plpgsql as $$
begin
  if c is true then raise notice 'PASS  %', label; else raise exception 'FAIL  %', label; end if;
end $$;

-- run sql as a user; must raise an error (optionally containing msg)
create function pg_temp.fails(u uuid, sql text, label text, msg text default '') returns void language plpgsql as $$
declare e text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute 'set role authenticated';
  begin
    execute sql; execute 'reset role';
    raise exception 'FAIL  % (no error raised)', label;
  exception when others then
    e := sqlerrm; execute 'reset role';
    if e like 'FAIL  %' then raise; end if;
    if msg <> '' and position(msg in e) = 0 then raise exception 'FAIL  % (wrong error: %)', label, e; end if;
    raise notice 'PASS  % [%]', label, left(e, 70);
  end;
end $$;

-- run any statement as a user (for void functions)
create function pg_temp.run(u uuid, sql text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute 'set role authenticated';
  begin execute sql; exception when others then execute 'reset role'; raise; end;
  execute 'reset role';
end $$;

-- rows a write statement actually changed, as a user (row-level security hides rows instead of raising)
create function pg_temp.changed(u uuid, sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute 'set role authenticated';
  begin execute sql; get diagnostics n = row_count; exception when others then execute 'reset role'; raise; end;
  execute 'reset role';
  return n;
end $$;

-- run a select returning jsonb as a user
create function pg_temp.call(u uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute 'set role authenticated';
  begin execute sql into r; exception when others then execute 'reset role'; raise; end;
  execute 'reset role';
  return r;
end $$;

-- row count visible to a user (tests row-level security)
create function pg_temp.visible(u uuid, rel text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', coalesce(u::text, ''), false);
  execute 'set role authenticated';
  begin execute 'select count(*) from ' || rel into n; exception when others then execute 'reset role'; raise; end;
  execute 'reset role';
  return n;
end $$;

create function pg_temp.oh(nm text) returns numeric language sql as $$
  select quantity_on_hand from public.inventory_item where item_name = nm $$;
create function pg_temp.iid(nm text) returns int language sql as $$
  select item_id from public.inventory_item where item_name = nm $$;

-- ------------------------------------------------------------------ people
insert into auth.users (id, email) values
 ('a0000000-0000-4000-8000-000000000001', 'admin@t'), ('a0000000-0000-4000-8000-000000000002', 'mgr@t'),
 ('a0000000-0000-4000-8000-000000000003', 'staff@t'), ('a0000000-0000-4000-8000-000000000004', 'newbie@t');
select pg_temp.ok((select bool_and(role = 'staff' and not is_active) from public.user_account), 'new sign-ups arrive as INACTIVE staff');
update public.user_account set role = 'admin',   is_active = true where email = 'admin@t';
update public.user_account set role = 'manager', is_active = true where email = 'mgr@t';
update public.user_account set role = 'staff',   is_active = true where email = 'staff@t';
\set A '''a0000000-0000-4000-8000-000000000001'''
\set M '''a0000000-0000-4000-8000-000000000002'''
\set S '''a0000000-0000-4000-8000-000000000003'''
\set N '''a0000000-0000-4000-8000-000000000004'''

-- ------------------------------------------------------------------ seed
select pg_temp.ok((select count(*) from public.inventory_item) = 52, 'seed: 52 inventory items (45 bought + 7 sauces)');
select pg_temp.ok((select count(*) from public.recipe where recipe_type = 'menu') = 16 and (select count(*) from public.recipe where recipe_type = 'sauce') = 7, 'seed: 16 menu recipes + 7 sauce recipes');
select pg_temp.ok((select count(*) from public.supplier_sku) = 72 and (select count(*) from public.supplier_sku where item_id is not null) = 0, 'seed: 72 SKUs, every one UNMATCHED');
select pg_temp.ok((select bool_and(quantity_on_hand = 0) from public.inventory_item) and (select count(*) from public.stock_transaction) = 0, 'seed: all stock starts at zero');

-- ------------------------------------------------------------------ access
select pg_temp.ok(pg_temp.visible(:N, 'public.inventory_item') = 0, 'inactive user sees no inventory');
select pg_temp.fails(:N, 'select public.record_waste(1, 1, ''x'')', 'inactive user cannot log waste', 'not allowed');
select pg_temp.ok(pg_temp.visible(:S, 'public.inventory_item') = 52, 'staff can read inventory');
select pg_temp.ok(pg_temp.visible(:S, 'public.user_account') = 1, 'staff sees only their own account row');
select pg_temp.ok(pg_temp.visible(:A, 'public.user_account') = 4, 'admin sees every account');
select pg_temp.fails(:S, 'select public.record_sales(''f'', ''[]'')', 'staff cannot import sales', 'needs manager');
select pg_temp.fails(:S, 'select public.record_delivery(''f'', ''[]'')', 'staff cannot import deliveries', 'needs manager');
select pg_temp.ok(pg_temp.changed(:S, 'update public.inventory_item set par_level = 5') = 0 and pg_temp.changed(:S, 'delete from public.recipe') = 0, 'staff cannot edit or delete master data (0 rows changed)');
select pg_temp.fails(:S, 'insert into public.stock_transaction (item_id,user_id,transaction_type,quantity_change) values (1,''a0000000-0000-4000-8000-000000000003'',''waste'',-1)', 'nobody can insert into the ledger directly');
select pg_temp.fails(:M, 'update public.inventory_item set quantity_on_hand = 999 where item_id = 1', 'even a manager cannot type a stock number', 'maintained by stock transactions');
select pg_temp.fails(:M, 'insert into public.inventory_item (item_name, unit_of_measure, quantity_on_hand) values (''X'',''oz'',5)', 'new items cannot start with stock', 'start at 0');
select pg_temp.fails(:M, 'select public.set_user(''a0000000-0000-4000-8000-000000000004'', ''staff'', true)', 'manager cannot manage accounts', 'needs admin');
select pg_temp.ok(pg_temp.visible(null, 'public.inventory_item') = 0, 'no login = no data');
do $$ begin
  begin execute 'set role anon'; perform count(*) from public.inventory_item; execute 'reset role'; raise exception 'FAIL anon read';
  exception when insufficient_privilege then execute 'reset role'; raise notice 'PASS  anon key cannot read anything'; end;
end $$;
select pg_temp.fails(:M, 'update public.supplier_sku set item_id = 1 where sku_id = 1', 'a SKU with an item but no conversion is rejected', 'check');
select pg_temp.fails(:M, format('insert into public.recipe_ingredient (recipe_id,item_id,quantity_used,unit_of_measure) values (1,%s,1,''lb'')', pg_temp.iid('Turkey')), 'recipe line in the wrong unit is rejected', 'does not match');

-- ------------------------------------------------------------------ process 4: master data
\i supabase/apply_mapping_suggestions.sql
select pg_temp.ok((select count(*) from public.supplier_sku where item_id is not null) = 31, 'apply_mapping_suggestions confirms exactly the 31 convertible SKUs');
select pg_temp.ok((select count(*) from public.v_unmatched_items) = 41, 'unmatched queue: 41 SKUs left (10 need a measurement, 31 not in any recipe)');
select pg_temp.ok((select units_per_pack from public.supplier_sku where supplier_sku_code = '9633650') = 150, 'sourdough: 150 slices per case');
select pg_temp.ok((select units_per_pack from public.supplier_sku where supplier_sku_code = '2565976') = 16, 'catch-weight turkey: 16 oz per lb');
select pg_temp.run(:M, format('select public.confirm_sku(''4332003'', %s, 400)', pg_temp.iid('Onion (fresh)')));
select pg_temp.ok((select item_id from public.supplier_sku where supplier_sku_code = '4332003') = pg_temp.iid('Onion (fresh)'), 'manager can confirm a SKU by hand (confirm_sku)');
select pg_temp.run(:M, format('select public.confirm_sku(''4332003'', %s, 800)', pg_temp.iid('Onion (fresh)')));   -- put it back to a sane value
select pg_temp.fails(:M, 'select public.confirm_sku(''nope'', 1, 1)', 'confirm_sku rejects an unknown SKU', 'not found');
select pg_temp.fails(:S, 'select public.confirm_sku(''4332003'', 1, 1)', 'staff cannot confirm SKUs', 'needs manager');
select pg_temp.run(:A, 'select public.set_user(''a0000000-0000-4000-8000-000000000004'', ''staff'', true, ''New Hire'')');
select pg_temp.ok((select is_active and full_name = 'New Hire' from public.user_account where email = 'newbie@t'), 'admin activates a new account');
select pg_temp.run(:A, 'select public.set_user(''a0000000-0000-4000-8000-000000000004'', ''staff'', false)');
select pg_temp.fails(:A, 'select public.set_user(''a0000000-0000-4000-8000-000000000001'', ''staff'', true)', 'the last active admin cannot be demoted', 'at least one active admin');

-- ------------------------------------------------------------------ process 2: Record Deliveries
-- fixture: invoice 2799992 style lines. 14.5 = shipped weight in lb of a catch-weight turkey.
\set DEL '[{"sku":"1000419","qty":2,"unit_cost":53.39},{"sku":"2565976","qty":14.5,"unit_cost":7.85},{"sku":"1333970","qty":1,"unit_cost":74.8},{"sku":"6199833","qty":1,"unit_cost":40},{"sku":"9999999","qty":3,"unit_cost":12.5},{"sku":"9633650","qty":0}]'
select pg_temp.call(:M, format('select public.record_delivery(%L, %L)', 'inv-test-1', :'DEL')) as d \gset
select pg_temp.ok(pg_temp.oh('Ciabatta Roll') = 70, 'delivery: 2 cases x 35 = 70 rolls');
select pg_temp.ok(pg_temp.oh('Turkey') = 232, 'delivery: catch-weight 14.5 lb x 16 = 232 oz');
select pg_temp.ok(pg_temp.oh('Oil') = 512, 'delivery: 1 case oil = 512 oz');
select pg_temp.ok(pg_temp.oh('Pickles') = 0, 'delivery: an unmatched SKU (pickles) moves no stock');
select pg_temp.ok(pg_temp.oh('Annie''s Bakery Sourdough') = 0, 'delivery: 0 shipped = 0 stock (short shipment)');
select pg_temp.ok((:'d'::jsonb -> 'new_skus') = '["9999999"]', 'delivery: a brand-new SKU is added to the catalog');
select pg_temp.ok((:'d'::jsonb -> 'unmatched') = '["6199833", "9999999"]', 'delivery: Unmatched Item Notice lists the SKUs that did nothing');
select pg_temp.ok((select last_unit_cost from public.supplier_sku where supplier_sku_code = '2565976') = 7.85, 'delivery: last_unit_cost updated from the invoice');
select pg_temp.ok((select count(*) from public.v_unmatched_items where supplier_sku_code = '9999999') = 1, 'new SKU shows in v_unmatched_items');
select pg_temp.ok((pg_temp.call(:M, format('select public.record_delivery(%L, %L)', 'inv-test-1', :'DEL')) ->> 'status') = 'already_applied' and pg_temp.oh('Ciabatta Roll') = 70, 'delivery: re-importing the same file changes nothing');
select pg_temp.fails(:M, 'select public.record_delivery('''', ''[]'')', 'delivery: source_file is required', 'source_file is required');
select pg_temp.fails(:M, 'select public.record_delivery(''x'', ''[{"sku":"1000419","qty":-1}]'')', 'delivery: negative quantity rejected', 'negative');

-- ------------------------------------------------------------------ process 1: Record Sales Usage
select pg_temp.call(:M, 'select public.record_sales(''toast-1'', ''[{"toast_item":" the big fun ","qty":2},{"toast_item":"The Big Fun","qty":1},{"toast_item":"Mystery Special","qty":4}]'')') as s \gset
select pg_temp.ok(pg_temp.oh('Ciabatta Roll') = 67, 'sales: 3 Big Funs (two lines, odd case/spaces) use 3 rolls');
select pg_temp.ok(pg_temp.oh('Turkey') = 223, 'sales: 3 x 3 oz turkey');
select pg_temp.ok(pg_temp.oh('Chipotle Aioli') = -6, 'sales: sauce stock may go negative (6 oz with none made)');
select pg_temp.ok((:'s'::jsonb -> 'unmatched') = '["Mystery Special"]' and (:'s'::jsonb ->> 'items_matched') = '1', 'sales: unknown Toast item returned as an Unmatched Item Notice');
select pg_temp.ok((select count(*) from public.v_negative_stock where item_name = 'Chipotle Aioli') = 1, 'negative stock is reported');
select pg_temp.ok((pg_temp.call(:M, 'select public.record_sales(''toast-1'', ''[{"toast_item":"The Big Fun","qty":99}]'')') ->> 'status') = 'already_applied' and pg_temp.oh('Ciabatta Roll') = 67, 'sales: same file twice is ignored');
select pg_temp.fails(:M, 'select public.record_sales(''toast-bad'', ''[{"toast_item":"The Big Fun","qty":0}]'')', 'sales: zero quantity rejected', 'above zero');
select pg_temp.ok((select count(*) from public.stock_transaction where source_file = 'toast-bad') = 0, 'sales: a rejected file leaves no partial rows');
select pg_temp.call(:M, 'select public.reverse_import(''toast-1'')') as rv \gset
select pg_temp.ok(pg_temp.oh('Ciabatta Roll') = 70 and pg_temp.oh('Turkey') = 232 and pg_temp.oh('Chipotle Aioli') = 0, 'reverse_import: stock restored by opposite rows');
select pg_temp.ok((pg_temp.call(:M, 'select public.reverse_import(''toast-1'')') ->> 'status') = 'already_reversed', 'reverse_import: cannot reverse twice');
select pg_temp.fails(:M, 'select public.reverse_import(''no-such-file'')', 'reverse_import: unknown file rejected', 'no transactions');
select pg_temp.run(:M, 'select public.record_sales(''toast-2'', ''[{"toast_item":"Ham and Brie","qty":2}]'')');
select pg_temp.ok((select count(*) from public.stock_transaction where source_file = 'toast-2' and transaction_type = 'sale' and recipe_id is not null) = 7, 'sales: 2 Ham and Brie = one ledger row per recipe line (7), each carrying its recipe');

-- ------------------------------------------------------------------ process 3: Waste, Prep, Count
select pg_temp.call(:S, 'select public.record_waste(' || pg_temp.iid('Arugula') || ', 3, ''wilted'')') as w \gset
select pg_temp.ok((:'w'::jsonb ->> 'quantity_on_hand')::numeric = -4 and pg_temp.oh('Arugula') = -4, 'waste: staff logs 3 oz (after 1 oz sold), gets Updated Stock Levels back');
select pg_temp.fails(:S, 'select public.record_waste(1, 2, '''')', 'waste: a reason is required', 'say why');
select pg_temp.fails(:S, 'select public.record_waste(1, -2, ''x'')', 'waste: quantity must be positive', 'above zero');
select pg_temp.ok((select count(*) from public.v_waste_log where reason = 'wilted' and quantity_wasted = 3) = 1, 'v_waste_log shows it');

select pg_temp.call(:S, 'select public.record_prep(' || (select recipe_id from public.recipe where recipe_name = 'Red Pepper Aioli') || ', 1)') as pr \gset
select pg_temp.ok(pg_temp.oh('Red Pepper Aioli') = 124, 'prep: one batch adds 128 oz of the sauce (-4 oz already sold)');
select pg_temp.ok(pg_temp.oh('Mayonnaise') = -128 and pg_temp.oh('Roasted Red Peppers') = -28 and pg_temp.oh('Garlic (minced)') = -1, 'prep: and consumes its ingredients');
select pg_temp.fails(:S, 'select public.record_prep((select recipe_id from public.recipe where recipe_name = ''The Big Fun''), 1)', 'prep: only sauce recipes can be prepped', 'not an active sauce');

-- first count = opening count; second count shows shrinkage
select pg_temp.run(:S, format('select public.record_counts(''[{"item_id":%s,"counted":40}]'', ''count-1'')', pg_temp.iid('Ciabatta Roll')));
select pg_temp.ok(pg_temp.oh('Ciabatta Roll') = 40, 'count: stock is set to what was counted');
select pg_temp.ok((select quantity_change from public.stock_transaction where source_file = 'count-1') = -28, 'count: ledger row holds the difference (40 counted - 68 expected)');
select pg_temp.ok((select count(*) from public.v_count_variance) = 0, 'count: the first count is an opening count, not shrinkage');
select pg_temp.run(:S, format('select public.record_counts(''[{"item_id":%s,"counted":38}]'', ''count-2'')', pg_temp.iid('Ciabatta Roll')));
select pg_temp.ok((select variance from public.v_count_variance) = -2 and (select variance_cost from public.v_count_variance) = round(-2 * 53.39 / 35, 2), 'count: the second count reports -2 rolls of shrinkage, priced');
select pg_temp.ok((pg_temp.call(:S, format('select public.record_counts(''[{"item_id":%s,"counted":1}]'', ''count-2'')', pg_temp.iid('Ciabatta Roll'))) ->> 'status') = 'already_applied' and pg_temp.oh('Ciabatta Roll') = 38, 'count: same count file twice is ignored');
select pg_temp.fails(:S, 'select public.record_counts(''[{"item_id":1,"counted":1},{"item_id":1,"counted":2}]'')', 'count: an item twice in one count is rejected', 'twice');
select pg_temp.fails(:S, 'select public.record_counts(''[{"item_id":99999,"counted":1}]'')', 'count: unknown item rejected', 'unknown item');
select pg_temp.fails(:S, 'select public.record_counts(''[{"item_id":1,"counted":-1}]'')', 'count: negative count rejected', 'zero or more');

-- ------------------------------------------------------------------ process 6: Reconciliation
select pg_temp.ok(pg_temp.visible(:M, 'public.reconcile_stock()') = 0, 'reconcile: cache equals the ledger after all of the above');
do $$ begin
  perform set_config('app.ledger_write', '1', false);
  update public.inventory_item set quantity_on_hand = quantity_on_hand + 5 where item_name = 'Basil (fresh)';
  perform set_config('app.ledger_write', '', false);
end $$;
select pg_temp.ok(pg_temp.call(:M, 'select jsonb_agg(drift) from public.reconcile_stock()') = '[5]', 'reconcile: tampering with the cache is detected (drift 5)');
do $$ begin
  perform set_config('app.ledger_write', '1', false);
  update public.inventory_item set quantity_on_hand = quantity_on_hand - 5 where item_name = 'Basil (fresh)';
  perform set_config('app.ledger_write', '', false);
end $$;
do $$ begin
  begin update public.stock_transaction set quantity_change = 0 where transaction_id = 1; raise exception 'FAIL edit';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS  ledger rows cannot be edited, even by the database owner'; end;
  begin delete from public.stock_transaction where transaction_id = 1; raise exception 'FAIL delete';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS  ledger rows cannot be deleted'; end;
  begin truncate public.stock_transaction; raise exception 'FAIL truncate';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS  ledger cannot be truncated'; end;
end $$;
select pg_temp.fails(:S, 'select * from public.reconcile_stock()', 'reconcile: staff cannot run it', 'needs manager');

-- ------------------------------------------------------------------ process 5: Monitor Stock and Report
select pg_temp.run(:M, format('update public.inventory_item set par_level = 50, reorder_quantity = 70 where item_id = %s', pg_temp.iid('Ciabatta Roll')));
select pg_temp.run(:M, format('update public.inventory_item set par_level = 10 where item_id = %s', pg_temp.iid('Tempeh')));
select pg_temp.ok((select count(*) from public.v_low_stock) = 2, 'low stock: items at or under par are flagged (rolls 38<=50, tempeh 0<=10)');
select pg_temp.ok((select packs_to_order from public.v_reorder_suggestions where item_name = 'Ciabatta Roll') = 2
              and (select est_cost from public.v_reorder_suggestions where item_name = 'Ciabatta Roll') = 106.78
              and (select supplier_sku_code from public.v_reorder_suggestions where item_name = 'Ciabatta Roll') = '1000419', 'reorder: 70 rolls = 2 cases of SKU 1000419 = $106.78');
select pg_temp.ok((select supplier_sku_code from public.v_reorder_suggestions where item_name = 'Tempeh') is null, 'reorder: an item with no matched SKU still shows, with no SKU to order');
select pg_temp.ok(pg_temp.visible(:S, 'public.v_low_stock') = 2, 'staff can see the alerts (views respect row-level security)');

-- ------------------------------------------------------------------ the diagram's relationships
select pg_temp.fails(:M, 'delete from public.inventory_item where item_name = ''Ciabatta Roll''', 'an item with history cannot be deleted (deactivate it)', 'foreign key');
select pg_temp.run(:M, 'update public.inventory_item set is_active = false where item_name = ''Pistachios''');
select pg_temp.ok(true, 'an item can be deactivated instead');
select pg_temp.fails(:M, 'insert into public.supplier_sku (supplier_id, supplier_sku_code) values (1, ''1000419'')', 'the same SKU cannot be listed twice for a supplier', 'unique');
select 'ALL CHECKS PASSED' as result \gset
\echo
do $$ begin raise notice 'ALL CHECKS PASSED'; end $$;
