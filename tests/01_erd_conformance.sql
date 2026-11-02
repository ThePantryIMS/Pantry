-- Does the database match "The Pantry: Entity Relationship Diagram" exactly?
-- Expected list below was transcribed from the diagram. Any extra or missing column/key fails.
create temp table erd (tbl text, col text, typ text, is_pk boolean, fk_to text, nullable boolean);
insert into erd values
 ('supplier','supplier_id','integer',true,null,false),
 ('supplier','supplier_name','character varying(100)',false,null,false),
 ('supplier','rep_name','character varying(100)',false,null,true),
 ('supplier','phone','character varying(20)',false,null,true),
 ('supplier','email','character varying(100)',false,null,true),
 ('supplier_sku','sku_id','integer',true,null,false),
 ('supplier_sku','supplier_id','integer',false,'supplier',false),
 ('supplier_sku','item_id','integer',false,'inventory_item',true),       -- deviation 1: NULL = unmatched
 ('supplier_sku','supplier_sku_code','character varying(30)',false,null,false),
 ('supplier_sku','pack_description','character varying(60)',false,null,true),
 ('supplier_sku','units_per_pack','numeric(8,2)',false,null,true),
 ('supplier_sku','last_unit_cost','numeric(8,2)',false,null,true),
 ('inventory_item','item_id','integer',true,null,false),
 ('inventory_item','item_name','character varying(100)',false,null,false),
 ('inventory_item','category','character varying(40)',false,null,true),
 ('inventory_item','unit_of_measure','character varying(20)',false,null,false),
 ('inventory_item','quantity_on_hand','numeric(10,2)',false,null,false),
 ('inventory_item','par_level','numeric(10,2)',false,null,true),
 ('inventory_item','reorder_quantity','numeric(10,2)',false,null,true),
 ('inventory_item','is_active','boolean',false,null,false),
 ('recipe','recipe_id','integer',true,null,false),
 ('recipe','recipe_name','character varying(100)',false,null,false),
 ('recipe','recipe_type','character varying(10)',false,null,false),
 ('recipe','toast_menu_item','character varying(100)',false,null,true),
 ('recipe','yield_quantity','numeric(8,2)',false,null,false),
 ('recipe','is_active','boolean',false,null,false),
 ('recipe_ingredient','recipe_id','integer',true,'recipe',false),
 ('recipe_ingredient','item_id','integer',true,'inventory_item',false),
 ('recipe_ingredient','quantity_used','numeric(8,3)',false,null,false),
 ('recipe_ingredient','unit_of_measure','character varying(20)',false,null,false),
 ('user_account','user_id','uuid',true,null,false),
 ('user_account','full_name','character varying(100)',false,null,true),
 ('user_account','email','character varying(100)',false,null,true),
 ('user_account','role','character varying(20)',false,null,false),
 ('user_account','is_active','boolean',false,null,false),
 ('user_account','created_at','timestamp with time zone',false,null,false),
 ('stock_transaction','transaction_id','integer',true,null,false),
 ('stock_transaction','item_id','integer',false,'inventory_item',false),
 ('stock_transaction','user_id','uuid',false,'user_account',false),
 ('stock_transaction','recipe_id','integer',false,'recipe',true),
 ('stock_transaction','transaction_type','character varying(20)',false,null,false),
 ('stock_transaction','quantity_change','numeric(10,2)',false,null,false),
 ('stock_transaction','transaction_at','timestamp with time zone',false,null,false),
 ('stock_transaction','source_file','character varying(120)',false,null,true),
 ('stock_transaction','notes','text',false,null,true);

create temp view actual as
select c.relname::text as tbl, a.attname::text as col, format_type(a.atttypid, a.atttypmod) as typ,
       coalesce((select bool_or(a.attnum = any(k.conkey)) from pg_constraint k where k.conrelid = c.oid and k.contype = 'p'), false) as is_pk,
       (select cf.relname::text from pg_constraint k join pg_class cf on cf.oid = k.confrelid
         where k.conrelid = c.oid and k.contype = 'f' and k.conkey = array[a.attnum]
           and cf.relname <> 'users') as fk_to,
       not a.attnotnull as nullable
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
 where n.nspname = 'public' and c.relkind = 'r';

do $$
declare r record; n int := 0; bad int := 0;
begin
  -- exactly 7 tables
  if (select count(distinct tbl) from actual) <> 7 then
    raise exception 'FAIL: expected 7 tables, found %', (select string_agg(distinct tbl, ',') from actual);
  end if;
  for r in
    select coalesce(e.tbl, a.tbl) t, coalesce(e.col, a.col) c, e.typ et, a.typ at, e.is_pk epk, a.is_pk apk,
           e.fk_to efk, a.fk_to afk, e.nullable en, a.nullable an
      from erd e full join actual a on a.tbl = e.tbl and a.col = e.col
     where e.col is null or a.col is null or e.typ is distinct from a.typ or e.is_pk is distinct from a.is_pk
        or e.fk_to is distinct from a.fk_to or e.nullable is distinct from a.nullable
  loop
    bad := bad + 1;
    raise notice 'MISMATCH %.%  erd=(% pk=% fk=% null=%) db=(% pk=% fk=% null=%)', r.t, r.c, r.et, r.epk, r.efk, r.en, r.at, r.apk, r.afk, r.an;
  end loop;
  select count(*) into n from erd;
  if bad > 0 then raise exception 'FAIL: % column(s) differ from the ERD', bad; end if;
  raise notice 'PASS  ERD conformance: 7 tables, % columns, all types / keys / nullability match', n;
end $$;
