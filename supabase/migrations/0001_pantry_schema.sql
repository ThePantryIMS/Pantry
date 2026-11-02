-- =============================================================================
-- The Pantry: schema. Mirrors "The Pantry: Entity Relationship Diagram" exactly.
--   7 tables, same names, same columns, same types, same keys.
--   D1 inventory_item   D2 recipe + recipe_ingredient   D3 stock_transaction
--   D4 user_account     D5 supplier + supplier_sku
--
-- Deviations from the diagram (each one is deliberate and listed here):
--   1. supplier_sku.item_id and supplier_sku.units_per_pack may be NULL.
--      NULL means "seen on an invoice, not yet matched to an inventory item".
--      That is how the DFD's "Unmatched Item Notice" is remembered.
--   2. CHECK constraints, defaults and NOT NULLs the diagram does not draw.
-- Nothing is added: no extra tables, no extra columns.
-- =============================================================================

-- ---------------------------------------------------------------- D5 supplier
create table public.supplier (
  supplier_id    integer generated always as identity primary key,
  supplier_name  varchar(100) not null unique,
  rep_name       varchar(100),
  phone          varchar(20),
  email          varchar(100)
);

-- ---------------------------------------------------------------- D1 inventory
create table public.inventory_item (
  item_id           integer generated always as identity primary key,
  item_name         varchar(100) not null unique,
  category          varchar(40),
  unit_of_measure   varchar(20)  not null,
  quantity_on_hand  numeric(10,2) not null default 0,   -- maintained ONLY by process 6 (trigger)
  par_level         numeric(10,2) check (par_level is null or par_level >= 0),
  reorder_quantity  numeric(10,2) check (reorder_quantity is null or reorder_quantity > 0),
  is_active         boolean not null default true
);

-- ---------------------------------------------------------------- D5 supplier_sku
create table public.supplier_sku (
  sku_id            integer generated always as identity primary key,
  supplier_id       integer not null references public.supplier (supplier_id),
  item_id           integer references public.inventory_item (item_id),   -- NULL = unmatched
  supplier_sku_code varchar(30) not null,
  pack_description  varchar(60),
  units_per_pack    numeric(8,2) check (units_per_pack is null or units_per_pack > 0),
  last_unit_cost    numeric(8,2) check (last_unit_cost is null or last_unit_cost >= 0),
  unique (supplier_id, supplier_sku_code),
  -- a SKU is either fully matched (item + conversion) or not matched at all
  check ((item_id is null) = (units_per_pack is null))
);
create index on public.supplier_sku (item_id);

-- ---------------------------------------------------------------- D2 recipe
create table public.recipe (
  recipe_id        integer generated always as identity primary key,
  recipe_name      varchar(100) not null unique,
  recipe_type      varchar(10)  not null check (recipe_type in ('menu', 'sauce')),
  toast_menu_item  varchar(100) unique,                 -- how Toast spells it (menu recipes)
  yield_quantity   numeric(8,2) not null default 1 check (yield_quantity > 0),
  is_active        boolean not null default true
);

create table public.recipe_ingredient (
  recipe_id        integer not null references public.recipe (recipe_id) on delete cascade,
  item_id          integer not null references public.inventory_item (item_id),
  quantity_used    numeric(8,3) not null check (quantity_used > 0),
  unit_of_measure  varchar(20) not null,
  primary key (recipe_id, item_id)
);
create index on public.recipe_ingredient (item_id);

-- ---------------------------------------------------------------- D4 user_account
create table public.user_account (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  full_name   varchar(100),
  email       varchar(100),
  role        varchar(20) not null default 'staff' check (role in ('staff', 'manager', 'admin')),
  is_active   boolean not null default false,            -- an admin switches people on
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- D3 stock_transaction
-- Append-only ledger. A mistake is fixed by a reversing row, never by an edit.
create table public.stock_transaction (
  transaction_id    integer generated always as identity primary key,
  item_id           integer not null references public.inventory_item (item_id),
  user_id           uuid    not null references public.user_account (user_id),
  recipe_id         integer references public.recipe (recipe_id),
  transaction_type  varchar(20) not null
    check (transaction_type in ('sale', 'delivery', 'waste', 'prep', 'count', 'reversal')),
  quantity_change   numeric(10,2) not null,
  transaction_at    timestamptz not null default now(),
  source_file       varchar(120),
  notes             text
);
create index on public.stock_transaction (item_id, transaction_at);
create index on public.stock_transaction (source_file) where source_file is not null;
create index on public.stock_transaction (transaction_type, transaction_at);

-- A recipe line must be written in the item's own unit.
create function public.check_recipe_unit() returns trigger language plpgsql as $$
declare v_unit varchar(20);
begin
  select unit_of_measure into v_unit from public.inventory_item where item_id = new.item_id;
  if new.unit_of_measure is distinct from v_unit then
    raise exception 'recipe unit % does not match the item''s unit %', new.unit_of_measure, v_unit;
  end if;
  return new;
end $$;
create trigger recipe_ingredient_unit before insert or update on public.recipe_ingredient
  for each row execute function public.check_recipe_unit();

comment on table public.stock_transaction is 'D3. Append-only. quantity_change is in the item''s unit_of_measure: negative = stock leaves.';
comment on column public.supplier_sku.units_per_pack is 'Item units in one pack. For catch-weight SKUs (priced per lb) it is item units per LB and deliveries are entered in lb.';
comment on column public.supplier_sku.last_unit_cost is 'Price per pack as invoiced (per lb for catch-weight).';
comment on column public.inventory_item.quantity_on_hand is 'Cache of sum(stock_transaction.quantity_change). Only process 6 may write it; reconcile_stock() proves it.';
