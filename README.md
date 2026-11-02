# The Pantry: database

Supabase (Postgres) database for The Office's inventory system, built to match the three project diagrams:
**Context Diagram**, **Level 0 DFD** (6 processes) and **ERD** (7 tables). `tests/01_erd_conformance.sql` checks
every table, column, type, key and nullability against the ERD and fails on any difference.

```
supabase/migrations/0001_pantry_schema.sql     the 7 ERD tables
supabase/migrations/0002_pantry_processes.sql  the 6 DFD processes (functions, trigger, views) + access rules
supabase/seed.sql                              The Office's menu, recipes, sauces and 72 US Foods SKUs (GENERATED)
supabase/apply_mapping_suggestions.sql         run AFTER you review the sheet: confirms the 31 SKUs I could convert (GENERATED)
data/us_foods_mapping_review.xlsx              the sheet to review and fill in
data/us_foods_item_mapping.csv                 same data, plain CSV
data/notes_not_in_database.csv                 estimates and notes the ERD has no column for
tools/build_seed.py, build_review_xlsx.py      the single source for the generated files: edit there, re-run
tests/run.sh                                   ERD check + behaviour tests (needs local Postgres 15+)
archive/v1-multitenant/                        the first, multi-business build, kept for reference only
```

## Diagram to database

| Diagram | Implemented as |
|---|---|
| D1 Inventory Items | `inventory_item` |
| D2 Recipes | `recipe` (`recipe_type` = `menu` or `sauce`), `recipe_ingredient` |
| D3 Stock Transactions | `stock_transaction`: append-only ledger |
| D4 User Accounts | `user_account` (`user_id` is the Supabase login) |
| D5 Supplier / SKU (ERD only) | `supplier`, `supplier_sku` |
| 1 Record Sales Usage | `record_sales(source_file, lines)` |
| 2 Record Deliveries | `record_delivery(source_file, lines)` |
| 3 Record Waste and Prep | `record_waste`, `record_prep`, `record_counts` |
| 4 Maintain Master Data | table edits (managers) + `confirm_sku`, `set_user` (admins) |
| 5 Monitor Stock and Report | `v_low_stock`, `v_reorder_suggestions`, `v_unmatched_items`, `v_negative_stock`, `v_waste_log`, `v_count_variance` |
| 6 Reconciliation | trigger `stock_transaction_apply` (applies each new transaction to `quantity_on_hand`) + `reconcile_stock()` |
| Unmatched Item Notice | returned by `record_sales` (unknown Toast names) and `record_delivery`; SKUs also wait in `v_unmatched_items` |
| Updated Stock Levels | returned by `record_waste`, `record_prep`, `record_counts` |
| Account Status | `user_account.is_active` |

Everything is called as `supabase.rpc('record_waste', {...})` from the front end. Nobody can insert into `stock_transaction` directly.

## Where the diagrams disagree, and what I did

- **Data store numbering.** The logical DFD draws four stores. The physical DFD has five: D1 items, D2 recipes, D3 transactions, D4 suppliers + SKU map, D5 `auth.users`. The ERD labels them D4 = user_account and D5 = supplier/SKU, the reverse of the physical DFD. The database follows the ERD's table names; relabel one of the diagrams so D4/D5 agree.
- **Names.** The physical DFD says `items, recipes, transactions, suppliers, sku_map`; the database uses the ERD's `inventory_item, recipe, stock_transaction, supplier, supplier_sku`. `user_account` is the profile row (role, active flag) for each `auth.users` login.
- **Not built yet:** parsing the Toast and MOXē CSV files (the functions take parsed rows), and the physical diagram's "Discrepancy Alert" on deliveries.
- **One deliberate departure from the ERD:** `supplier_sku.item_id` and `units_per_pack` may be NULL. NULL means "seen on an invoice, not matched yet". That is what remembers the Unmatched Item Notice between deliveries. Everything else is exactly as drawn.

## What the diagrams do not have, so the database does not either

The first build had more. Dropped because the ERD has no place for it:

- **Multiple businesses** (`org_id`, memberships). One restaurant per database. To sell it later, run one Supabase project per customer, or add a tenant column in a later migration.
- **Manager approval of counts, invoice totals check, credits and surcharges, cost history, purchase orders, ordered vs shipped.** `record_delivery` records what shipped, and `last_unit_cost` keeps only the latest price.
- **Per-ingredient cost, count frequency, estimate flags, brand, mapping status and notes.** Cost is now worked out from `supplier_sku` (price per pack / units per pack). Notes and estimates are in `data/notes_not_in_database.csv` and the review sheet.
- **Auto-making sauce components.** `record_prep` logs one sauce batch; a sauce made from another sauce (basil aioli uses basil pesto) takes its pesto from stock, so log the pesto batch too.

The shrinkage and maintenance concerns are still covered with what the ERD has: counts (`transaction_type = 'count'`) store the difference from expected stock, and `v_count_variance` prices it; waste needs a reason (`notes`); `reconcile_stock()` proves the stock numbers equal the ledger.

## First-time setup

1. Create a Supabase project **under the restaurant's account**, so it outlives anyone's graduation.
2. SQL editor: run `0001_pantry_schema.sql`, `0002_pantry_processes.sql`, then `seed.sql`.
3. Sign up through the app (or Authentication > Add user). New accounts are **inactive staff** until an admin switches them on. Make yourself the first admin:
   ```sql
   update public.user_account set role = 'admin', is_active = true where email = 'you@example.com';
   ```
4. Review `data/us_foods_mapping_review.xlsx`, then run `apply_mapping_suggestions.sql` (edit out any line you disagreed with). Confirm the amber ones later with `confirm_sku('4332003', <item_id>, 800)`.
5. Do an **opening count** with `record_counts`. Stock starts at zero on purpose.
6. Set `par_level` and `reorder_quantity` on items you reorder.

## Rules that protect the numbers

- Stock changes only through `stock_transaction`. `quantity_on_hand` cannot be typed in, not even by a manager; mistakes are fixed with `reverse_import(source_file)` or a new count, never an edit or delete.
- Every import needs a `source_file` name. Importing the same name twice does nothing. To retry lines that were unmatched, import just those lines under a **new** name.
- A SKU moves stock only once it has an item and a conversion. Catch-weight meats are entered as **shipped pounds** (`units_per_pack` = ounces per lb).
- Stock may go negative on purpose. A negative number means recipes, deliveries and counts disagree: see `v_negative_stock`.
- Roles: **staff** log waste, prep and counts. **managers** import sales/deliveries, edit master data, confirm SKUs. **admins** do all that plus manage accounts (`set_user`); there is always at least one active admin.

## Routine

| When | Who | What |
|---|---|---|
| After each delivery (Mon/Thu) | manager | `record_delivery`, then look at `v_unmatched_items` |
| Daily/weekly | manager | `record_sales` from the Toast export; fix any unmatched names (set `recipe.toast_menu_item`) |
| Weekly | staff | `record_counts` on proteins, cheese, bread; manager checks `v_count_variance` |
| Any time | manager | `select * from reconcile_stock()` (empty = healthy), `v_low_stock`, `v_reorder_suggestions` |

## Maintenance

- **Backups:** do not rely on the free tier. Schedule a `pg_dump` (for example a weekly GitHub Actions job) and check Supabase's plan terms on backups and on pausing inactive projects.
- **Changes:** add a new numbered migration; never edit one that has already run.
- **Test:** `PGHOST=/tmp PGPORT=54329 ./tests/run.sh` should end with `ALL CHECKS PASSED`.
