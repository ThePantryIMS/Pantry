-- One-time data fix: make recipe.toast_menu_item match how Toast prints these items
-- (from the 2026-11-16 Items.csv export). record_sales matches on
-- lower(btrim(toast_menu_item)), so spelling, "&" vs "and", and a leading "The" all matter.
-- Run in the Supabase SQL Editor. Safe to re-run.

update public.recipe set toast_menu_item = 'Big Fun'            where recipe_name = 'The Big Fun'                and recipe_type = 'menu';
update public.recipe set toast_menu_item = 'The Velvet Italian' where recipe_name = 'Velvet Italian'             and recipe_type = 'menu';
update public.recipe set toast_menu_item = 'Ham & Brie Press'   where recipe_name = 'Ham and Brie'              and recipe_type = 'menu';
update public.recipe set toast_menu_item = 'Pesto GRCHZ'        where recipe_name = 'Pesto Grilled Cheese'       and recipe_type = 'menu';
update public.recipe set toast_menu_item = 'Chimmi GRCHZ'       where recipe_name = 'Chimmi Grilled Cheese'      and recipe_type = 'menu';
update public.recipe set toast_menu_item = 'Granny Smith GRCHZ' where recipe_name = 'Granny Smith Grilled Cheese' and recipe_type = 'menu';
-- Assumption (owner's guess): plain "Grill Chz" in Toast is the Children's Grilled Cheese.
update public.recipe set toast_menu_item = 'Grill Chz'          where recipe_name = 'Children''s Grilled Cheese' and recipe_type = 'menu';

-- Check: should list all seven with their new Toast names.
select recipe_name, toast_menu_item
  from public.recipe
 where recipe_type = 'menu'
 order by recipe_name;
