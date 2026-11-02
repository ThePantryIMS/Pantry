-- =============================================================================
-- The Pantry: the six Level 0 DFD processes, as database functions.
--   1 Record Sales Usage      record_sales(...)
--   2 Record Deliveries       record_delivery(...)
--   3 Record Waste and Prep   record_waste(...), record_prep(...), record_counts(...)
--   4 Maintain Master Data    confirm_sku(...), set_user(...) + row-level security
--   5 Monitor Stock & Report  v_low_stock, v_reorder_suggestions, v_unmatched_items, ...
--   6 Reconciliation          trigger on stock_transaction, reconcile_stock()
-- Nothing outside these functions can add a row to stock_transaction.
-- =============================================================================
create schema if not exists app;

-- ---------------------------------------------------------------- who is calling
-- Levels: staff < manager < admin. Inactive or unknown users have no level at all.
create function app.my_role() returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select role from public.user_account where user_id = auth.uid() and is_active
$$;

create function app.has_role(p_min text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case app.my_role()
           when 'admin'   then true
           when 'manager' then p_min in ('staff', 'manager')
           when 'staff'   then p_min = 'staff'
           else false end
$$;

create function app.require_role(p_min text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not app.has_role(p_min) then
    raise exception 'not allowed: needs % access', p_min using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------- process 6: Reconciliation
-- "Applies new transactions": every ledger row moves quantity_on_hand by its quantity_change.
create function app.apply_transaction() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform set_config('app.ledger_write', '1', true);
  update public.inventory_item set quantity_on_hand = quantity_on_hand + new.quantity_change
   where item_id = new.item_id;
  perform set_config('app.ledger_write', '', true);
  return null;
end $$;
create trigger stock_transaction_apply after insert on public.stock_transaction
  for each row execute function app.apply_transaction();

-- Nobody (not even a manager through the API) may type a stock number in by hand.
create function app.guard_on_hand() returns trigger language plpgsql as $$
begin
  if new.quantity_on_hand is distinct from old.quantity_on_hand
     and coalesce(current_setting('app.ledger_write', true), '') <> '1' then
    raise exception 'quantity_on_hand is maintained by stock transactions: record a count or a reversal instead';
  end if;
  return new;
end $$;
create trigger inventory_item_guard before update on public.inventory_item
  for each row execute function app.guard_on_hand();
create function app.guard_on_hand_insert() returns trigger language plpgsql as $$
begin
  if new.quantity_on_hand <> 0 then
    raise exception 'new items start at 0: record a count to set the first quantity';
  end if;
  return new;
end $$;
create trigger inventory_item_guard_insert before insert on public.inventory_item
  for each row execute function app.guard_on_hand_insert();

-- The ledger cannot be edited or emptied.
create function app.ledger_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'stock_transaction is append-only: add a reversal instead';
end $$;
create trigger stock_transaction_no_edit before update or delete on public.stock_transaction
  for each row execute function app.ledger_immutable();
create trigger stock_transaction_no_truncate before truncate on public.stock_transaction
  for each statement execute function app.ledger_immutable();

-- Proof that the cache matches the ledger. Empty result = healthy.
create function public.reconcile_stock()
returns table (item_id integer, item_name varchar, on_hand_cached numeric, on_hand_ledger numeric, drift numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role('manager');
  return query
    select i.item_id, i.item_name, i.quantity_on_hand,
           coalesce(sum(t.quantity_change), 0)::numeric,
           (i.quantity_on_hand - coalesce(sum(t.quantity_change), 0))::numeric
      from public.inventory_item i
      left join public.stock_transaction t using (item_id)
     group by i.item_id, i.item_name, i.quantity_on_hand
    having i.quantity_on_hand <> coalesce(sum(t.quantity_change), 0);
end $$;

-- ---------------------------------------------------------------- shared helpers
create function app.check_source_file(p_source_file text) returns void language plpgsql as $$
begin
  if p_source_file is null or btrim(p_source_file) = '' then
    raise exception 'source_file is required: it is what makes an import safe to re-run';
  end if;
  if length(p_source_file) > 110 then
    raise exception 'source_file is too long (110 characters max)';
  end if;
end $$;

create function app.already_applied(p_source_file text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.stock_transaction where source_file = p_source_file)
$$;

-- ---------------------------------------------------------------- process 1: Record Sales Usage
-- p_lines: [{"toast_item": "The Big Fun", "qty": 12}, ...]
-- Each sale deducts the recipe's ingredients (scaled by quantity / yield_quantity).
-- Names that match no active menu recipe are returned as the "Unmatched Item Notice".
-- Re-running the same source_file does nothing. To retry unmatched lines after fixing
-- the recipe, import just those lines under a NEW source_file.
create function public.record_sales(p_source_file text, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_matched int := 0; v_rows int := 0; v_unmatched jsonb;
begin
  perform app.require_role('manager');
  perform app.check_source_file(p_source_file);
  if app.already_applied(p_source_file) then
    return jsonb_build_object('status', 'already_applied', 'source_file', p_source_file);
  end if;

  drop table if exists pg_temp._sales;
  create temp table _sales on commit drop as
    select lower(btrim(x.toast_item)) as k, min(btrim(x.toast_item)) as shown, sum(x.qty) as qty
      from jsonb_to_recordset(p_lines) as x(toast_item text, qty numeric)
     group by 1;
  if exists (select 1 from _sales where qty is null or qty <= 0) then
    raise exception 'every sales line needs a quantity above zero';
  end if;

  select coalesce(jsonb_agg(shown order by shown), '[]') into v_unmatched
    from _sales s
   where not exists (select 1 from public.recipe r
                      where r.recipe_type = 'menu' and r.is_active and lower(btrim(r.toast_menu_item)) = s.k);

  insert into public.stock_transaction (item_id, user_id, recipe_id, transaction_type, quantity_change, source_file, notes)
  select ri.item_id, auth.uid(), r.recipe_id, 'sale',
         -round(ri.quantity_used * s.qty / r.yield_quantity, 2), p_source_file,
         s.qty || ' x ' || r.recipe_name
    from _sales s
    join public.recipe r on r.recipe_type = 'menu' and r.is_active and lower(btrim(r.toast_menu_item)) = s.k
    join public.recipe_ingredient ri on ri.recipe_id = r.recipe_id;
  get diagnostics v_rows = row_count;
  select count(*) into v_matched from _sales s
   where exists (select 1 from public.recipe r where r.recipe_type = 'menu' and r.is_active and lower(btrim(r.toast_menu_item)) = s.k);

  return jsonb_build_object('status', 'applied', 'source_file', p_source_file,
                            'items_matched', v_matched, 'transactions', v_rows, 'unmatched', v_unmatched);
end $$;

-- ---------------------------------------------------------------- process 2: Record Deliveries
-- p_lines: [{"sku": "1000419", "qty": 2, "unit_cost": 53.39}, ...]
-- qty = packs SHIPPED (not ordered). For catch-weight SKUs qty is the shipped weight in lb.
-- A SKU that is not confirmed (no item + conversion) moves no stock; it is added to the
-- catalog if new, and returned as unmatched so a manager can confirm it.
create function public.record_delivery(p_source_file text, p_lines jsonb, p_supplier varchar default 'US Foods')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_sup int; v_rows int := 0; v_new jsonb; v_unmatched jsonb;
begin
  perform app.require_role('manager');
  perform app.check_source_file(p_source_file);
  select supplier_id into v_sup from public.supplier where supplier_name = p_supplier;
  if v_sup is null then raise exception 'unknown supplier %', p_supplier; end if;
  if app.already_applied(p_source_file) then
    return jsonb_build_object('status', 'already_applied', 'source_file', p_source_file);
  end if;

  drop table if exists pg_temp._del;
  create temp table _del on commit drop as
    select btrim(x.sku) as sku, sum(x.qty) as qty, max(x.unit_cost) as unit_cost
      from jsonb_to_recordset(p_lines) as x(sku text, qty numeric, unit_cost numeric)
     group by btrim(x.sku);
  if exists (select 1 from _del where qty is null or qty < 0) then
    raise exception 'delivery quantities cannot be negative: reverse the import instead';
  end if;

  -- brand-new SKUs go into the unmatched queue
  with ins as (
    insert into public.supplier_sku (supplier_id, supplier_sku_code, last_unit_cost)
    select v_sup, d.sku, d.unit_cost from _del d
     where not exists (select 1 from public.supplier_sku k where k.supplier_id = v_sup and k.supplier_sku_code = d.sku)
    returning supplier_sku_code)
  select coalesce(jsonb_agg(supplier_sku_code), '[]') into v_new from ins;

  insert into public.stock_transaction (item_id, user_id, transaction_type, quantity_change, source_file, notes)
  select k.item_id, auth.uid(), 'delivery', round(d.qty * k.units_per_pack, 2), p_source_file,
         'SKU ' || d.sku || ' x ' || d.qty
    from _del d
    join public.supplier_sku k on k.supplier_id = v_sup and k.supplier_sku_code = d.sku
   where k.item_id is not null and d.qty > 0;
  get diagnostics v_rows = row_count;

  update public.supplier_sku k set last_unit_cost = d.unit_cost
    from _del d
   where k.supplier_id = v_sup and k.supplier_sku_code = d.sku and d.unit_cost is not null;

  select coalesce(jsonb_agg(d.sku order by d.sku), '[]') into v_unmatched
    from _del d join public.supplier_sku k on k.supplier_id = v_sup and k.supplier_sku_code = d.sku
   where k.item_id is null;

  return jsonb_build_object('status', 'applied', 'source_file', p_source_file,
                            'transactions', v_rows, 'new_skus', v_new, 'unmatched', v_unmatched);
end $$;

-- ---------------------------------------------------------------- process 3: Waste, Prep, Count
create function public.record_waste(p_item_id integer, p_qty numeric, p_notes text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_on_hand numeric;
begin
  perform app.require_role('staff');
  if p_qty is null or p_qty <= 0 then raise exception 'waste quantity must be above zero'; end if;
  if p_notes is null or btrim(p_notes) = '' then raise exception 'say why (spoiled, dropped, comped, ...)'; end if;
  insert into public.stock_transaction (item_id, user_id, transaction_type, quantity_change, notes)
  values (p_item_id, auth.uid(), 'waste', -round(p_qty, 2), p_notes);
  select quantity_on_hand into v_on_hand from public.inventory_item where item_id = p_item_id;
  return jsonb_build_object('item_id', p_item_id, 'quantity_on_hand', v_on_hand);
end $$;

-- Log a batch of a sauce: its ingredients leave stock, the sauce itself enters stock.
-- The sauce's inventory item is the one named exactly like the recipe.
create function public.record_prep(p_recipe_id integer, p_batches numeric default 1, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_r public.recipe; v_item int; v_on_hand numeric;
begin
  perform app.require_role('staff');
  if p_batches is null or p_batches <= 0 then raise exception 'batches must be above zero'; end if;
  select * into v_r from public.recipe where recipe_id = p_recipe_id and recipe_type = 'sauce' and is_active;
  if not found then raise exception 'recipe % is not an active sauce recipe', p_recipe_id; end if;
  select item_id into v_item from public.inventory_item where item_name = v_r.recipe_name;
  if v_item is null then raise exception 'no inventory item named "%" to receive the batch', v_r.recipe_name; end if;

  insert into public.stock_transaction (item_id, user_id, recipe_id, transaction_type, quantity_change, notes)
  select ri.item_id, auth.uid(), v_r.recipe_id, 'prep', -round(ri.quantity_used * p_batches, 2),
         coalesce(p_notes, p_batches || ' batch of ' || v_r.recipe_name)
    from public.recipe_ingredient ri where ri.recipe_id = v_r.recipe_id;
  insert into public.stock_transaction (item_id, user_id, recipe_id, transaction_type, quantity_change, notes)
  values (v_item, auth.uid(), v_r.recipe_id, 'prep', round(v_r.yield_quantity * p_batches, 2),
          coalesce(p_notes, p_batches || ' batch of ' || v_r.recipe_name));
  select quantity_on_hand into v_on_hand from public.inventory_item where item_id = v_item;
  return jsonb_build_object('item_id', v_item, 'item_name', v_r.recipe_name, 'quantity_on_hand', v_on_hand);
end $$;

-- A count states what is on the shelf. The row records the difference from what the system
-- expected, so shrinkage is visible. Counting is allowed to go negative->positive etc.
-- p_lines: [{"item_id": 3, "counted": 12.5}, ...]
create function public.record_counts(p_lines jsonb, p_source_file text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  perform app.require_role('staff');
  if p_source_file is not null then
    perform app.check_source_file(p_source_file);
    if app.already_applied(p_source_file) then
      return jsonb_build_object('status', 'already_applied', 'source_file', p_source_file);
    end if;
  end if;
  if exists (select 1 from jsonb_to_recordset(p_lines) as x(item_id int, counted numeric)
              where x.item_id is null or x.counted is null or x.counted < 0) then
    raise exception 'every count line needs an item_id and a counted quantity of zero or more';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_lines) as x(item_id int, counted numeric)
              group by x.item_id having count(*) > 1) then
    raise exception 'an item appears twice in this count';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_lines) as x(item_id int, counted numeric)
              where not exists (select 1 from public.inventory_item i where i.item_id = x.item_id)) then
    raise exception 'count contains an unknown item_id';
  end if;

  insert into public.stock_transaction (item_id, user_id, transaction_type, quantity_change, source_file, notes)
  select i.item_id, auth.uid(), 'count', round(x.counted, 2) - i.quantity_on_hand, p_source_file,
         coalesce(p_notes, 'counted ' || round(x.counted, 2) || ', system had ' || i.quantity_on_hand)
    from jsonb_to_recordset(p_lines) as x(item_id int, counted numeric)
    join public.inventory_item i using (item_id);
  get diagnostics v_n = row_count;

  return jsonb_build_object('status', 'applied', 'items_counted', v_n,
    'updated_stock', (select coalesce(jsonb_agg(jsonb_build_object('item_id', i.item_id, 'item_name', i.item_name,
                                                                   'quantity_on_hand', i.quantity_on_hand) order by i.item_name), '[]')
                        from public.inventory_item i
                       where i.item_id in (select (e->>'item_id')::int from jsonb_array_elements(p_lines) e)));
end $$;

-- Undo a whole import (sales file, delivery, count) by writing the opposite rows.
create function public.reverse_import(p_source_file text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  perform app.require_role('manager');
  perform app.check_source_file(p_source_file);
  if exists (select 1 from public.stock_transaction where source_file = 'reversal:' || p_source_file) then
    return jsonb_build_object('status', 'already_reversed', 'source_file', p_source_file);
  end if;
  insert into public.stock_transaction (item_id, user_id, recipe_id, transaction_type, quantity_change, source_file, notes)
  select item_id, auth.uid(), recipe_id, 'reversal', -quantity_change, 'reversal:' || p_source_file,
         'reverses #' || transaction_id
    from public.stock_transaction where source_file = p_source_file and transaction_type <> 'reversal';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'no transactions found for source_file %', p_source_file; end if;
  return jsonb_build_object('status', 'reversed', 'transactions', v_n);
end $$;

-- ---------------------------------------------------------------- process 4: Maintain Master Data
-- Items, recipes, thresholds, suppliers: plain table edits, allowed by the policies below.
-- These two functions carry rules a plain edit cannot.
create function public.confirm_sku(p_sku_code varchar, p_item_id integer, p_units_per_pack numeric,
                                   p_last_unit_cost numeric default null, p_supplier varchar default 'US Foods')
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  perform app.require_role('manager');
  if p_units_per_pack is null or p_units_per_pack <= 0 then raise exception 'units_per_pack must be above zero'; end if;
  update public.supplier_sku k
     set item_id = p_item_id, units_per_pack = p_units_per_pack,
         last_unit_cost = coalesce(p_last_unit_cost, k.last_unit_cost)
    from public.supplier s
   where s.supplier_id = k.supplier_id and s.supplier_name = p_supplier and k.supplier_sku_code = p_sku_code;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'SKU % not found for supplier %', p_sku_code, p_supplier; end if;
end $$;

create function public.set_user(p_user_id uuid, p_role varchar, p_is_active boolean, p_full_name varchar default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role('admin');
  update public.user_account
     set role = p_role, is_active = p_is_active, full_name = coalesce(p_full_name, full_name)
   where user_id = p_user_id;
  if not found then raise exception 'no such user'; end if;
  if not exists (select 1 from public.user_account where role = 'admin' and is_active) then
    raise exception 'there must always be at least one active admin';
  end if;
end $$;

-- Every new sign-up gets an INACTIVE staff account until an admin switches it on.
create function app.new_user() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.user_account (user_id, email) values (new.id, new.email) on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function app.new_user();

-- ---------------------------------------------------------------- process 5: Monitor Stock and Report
create view public.v_item_cost with (security_invoker = true) as
  select item_id, min(last_unit_cost / units_per_pack) as unit_cost
    from public.supplier_sku
   where item_id is not null and last_unit_cost is not null
   group by item_id;

-- Low-Stock Alerts
create view public.v_low_stock with (security_invoker = true) as
  select item_id, item_name, category, unit_of_measure, quantity_on_hand, par_level, reorder_quantity
    from public.inventory_item
   where is_active and par_level is not null and quantity_on_hand <= par_level;

-- Reorder Suggestions: what to order, from the cheapest matched SKU
create view public.v_reorder_suggestions with (security_invoker = true) as
  select l.item_id, l.item_name, l.quantity_on_hand, l.par_level, l.unit_of_measure,
         k.supplier_sku_code, k.pack_description,
         ceil(coalesce(l.reorder_quantity, l.par_level - l.quantity_on_hand) / k.units_per_pack)::int as packs_to_order,
         round(ceil(coalesce(l.reorder_quantity, l.par_level - l.quantity_on_hand) / k.units_per_pack) * k.last_unit_cost, 2) as est_cost
    from public.v_low_stock l
    left join lateral (
      select * from public.supplier_sku s
       where s.item_id = l.item_id
       order by s.last_unit_cost / s.units_per_pack nulls last, s.sku_id limit 1) k on true;

-- Unmatched Item Notice (SKUs): invoice products nobody has matched yet
create view public.v_unmatched_items with (security_invoker = true) as
  select k.sku_id, s.supplier_name, k.supplier_sku_code, k.pack_description, k.last_unit_cost
    from public.supplier_sku k join public.supplier s using (supplier_id)
   where k.item_id is null;

-- Stock below zero means recipes, deliveries and counts disagree
create view public.v_negative_stock with (security_invoker = true) as
  select item_id, item_name, unit_of_measure, quantity_on_hand
    from public.inventory_item where is_active and quantity_on_hand < 0;

create view public.v_waste_log with (security_invoker = true) as
  select t.transaction_at, i.item_name, -t.quantity_change as quantity_wasted, i.unit_of_measure,
         round(-t.quantity_change * c.unit_cost, 2) as est_cost, t.notes as reason, u.full_name as logged_by
    from public.stock_transaction t
    join public.inventory_item i using (item_id)
    join public.user_account u using (user_id)
    left join public.v_item_cost c using (item_id)
   where t.transaction_type = 'waste';

-- Shrinkage: what each count found versus what the system expected.
-- An item's first count is its opening count and is not counted as shrinkage.
create view public.v_count_variance with (security_invoker = true) as
  select * from (
    select t.transaction_at, i.item_name, i.unit_of_measure, t.quantity_change as variance,
           round(t.quantity_change * c.unit_cost, 2) as variance_cost, t.notes, t.source_file,
           row_number() over (partition by t.item_id order by t.transaction_id) as count_no
      from public.stock_transaction t
      join public.inventory_item i using (item_id)
      left join public.v_item_cost c using (item_id)
     where t.transaction_type = 'count') x
   where count_no > 1;

-- ---------------------------------------------------------------- access (Supabase roles)
alter table public.supplier          enable row level security;
alter table public.supplier_sku      enable row level security;
alter table public.inventory_item    enable row level security;
alter table public.recipe            enable row level security;
alter table public.recipe_ingredient enable row level security;
alter table public.stock_transaction enable row level security;
alter table public.user_account      enable row level security;

-- everyone active can read the shared data
create policy read_all on public.supplier          for select to authenticated using (app.has_role('staff'));
create policy read_all on public.supplier_sku      for select to authenticated using (app.has_role('staff'));
create policy read_all on public.inventory_item    for select to authenticated using (app.has_role('staff'));
create policy read_all on public.recipe            for select to authenticated using (app.has_role('staff'));
create policy read_all on public.recipe_ingredient for select to authenticated using (app.has_role('staff'));
create policy read_all on public.stock_transaction for select to authenticated using (app.has_role('staff'));
-- managers (and admins) maintain master data
create policy manage on public.supplier          for all to authenticated using (app.has_role('manager')) with check (app.has_role('manager'));
create policy manage on public.supplier_sku      for all to authenticated using (app.has_role('manager')) with check (app.has_role('manager'));
create policy manage on public.inventory_item    for all to authenticated using (app.has_role('manager')) with check (app.has_role('manager'));
create policy manage on public.recipe            for all to authenticated using (app.has_role('manager')) with check (app.has_role('manager'));
create policy manage on public.recipe_ingredient for all to authenticated using (app.has_role('manager')) with check (app.has_role('manager'));
-- accounts: see your own row; admins see and edit all (and use set_user)
create policy own_or_admin on public.user_account for select to authenticated
  using (user_id = auth.uid() or app.has_role('admin'));
create policy admin_edit on public.user_account for update to authenticated
  using (app.has_role('admin')) with check (app.has_role('admin'));

revoke all on all tables in schema public from anon, authenticated;
grant select on public.supplier, public.supplier_sku, public.inventory_item, public.recipe,
                public.recipe_ingredient, public.stock_transaction, public.user_account to authenticated;
grant insert, update, delete on public.supplier, public.supplier_sku, public.inventory_item,
                public.recipe, public.recipe_ingredient to authenticated;
grant update (full_name, role, is_active) on public.user_account to authenticated;
grant select on public.v_item_cost, public.v_low_stock, public.v_reorder_suggestions, public.v_unmatched_items,
                public.v_negative_stock, public.v_waste_log, public.v_count_variance to authenticated;
-- identity columns need sequence rights for inserts through the API
grant usage on all sequences in schema public to authenticated;

revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app    from public, anon, authenticated;
grant usage on schema app to authenticated;
grant execute on function app.has_role(text), app.my_role() to authenticated;   -- needed by the policies
grant execute on function public.record_sales(text, jsonb), public.record_delivery(text, jsonb, varchar),
  public.record_waste(integer, numeric, text), public.record_prep(integer, numeric, text),
  public.record_counts(jsonb, text, text), public.reverse_import(text), public.reconcile_stock(),
  public.confirm_sku(varchar, integer, numeric, numeric, varchar), public.set_user(uuid, varchar, boolean, varchar)
  to authenticated;
