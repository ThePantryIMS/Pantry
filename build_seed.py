#!/usr/bin/env python3
"""
Builds, for the 7-table Pantry schema (see the ERD):
  supabase/seed.sql                     suppliers, items, recipes, SKUs (all UNMATCHED)
  supabase/apply_mapping_suggestions.sql  optional: confirms the SKUs I could convert from the invoices
  data/us_foods_item_mapping.csv        the review sheet source
  data/notes_not_in_database.csv        estimates and notes the ERD has no column for

Sources
  * menu, recipes, sauces ........ "Office Recipes.docx" + inventory-demo-v2.html
  * SKUs, pack sizes, prices ..... 10 photographed US Foods invoices (ship dates
                                   07/30, 08/03, 08/13, 09/03, 09/14, 09/24,
                                   09/28, 09/30, 10/01, 10/05 of 2026)

Nothing here is confirmed by a person. Every supplier item is seeded as
'suggested' / 'needs_input' / 'unmapped' so NO invoice line can move stock
until someone confirms it.

Run:  python3 tools/build_seed.py
"""
import csv
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUPPLIER = "US Foods"

# ----------------------------------------------------------------------------
# Ingredients: (name, kind, category, unit, cost, cost_source, cost_date, pack_note, prep_yield)
# cost_source 'invoice' = derived from an invoice line I could verify by
# weight x price; everything else is the old demo placeholder.
# ----------------------------------------------------------------------------
P = "placeholder"
I = "invoice"
ING = [
    # Bread
    ("Ciabatta Roll", "ingredient", "Bread", "roll", 1.5254, I, "2026-09-24", "Case = 35 rolls (US Foods 1000419)", None),
    ("Annie's Bakery Sourdough", "ingredient", "Bread", "slice", 0.3681, I, "2026-09-24", "Case = 10 loaves x 15 slices = 150 slices (US Foods 9633650)", None),
    ("Annie's Bakery Jewish Rye", "ingredient", "Bread", "slice", 0.32, P, None, "Not on any US Foods invoice photographed: bought elsewhere?", None),
    # Protein
    ("Turkey", "ingredient", "Protein", "oz", 0.4906, I, "2026-10-05", "Catch weight: case = 2 breasts, ~13-16 lb, priced per lb", None),
    ("Roast Beef", "ingredient", "Protein", "oz", 0.675, I, "2026-10-05", "Catch weight, priced per lb", None),
    ("Bacon", "ingredient", "Protein", "strip", 0.28, P, None, "Hormel 15 lb case, 13-17 slices/lb stated: strips per case is an estimate", None),
    ("Capicola", "ingredient", "Protein", "oz", 0.4725, I, "2026-09-28", "Invoice calls it 'HAM, CAPCO SMKD CKD'; catch weight", None),
    ("Ham", "ingredient", "Protein", "oz", 0.3444, I, "2026-10-05", "Honey ham, catch weight", None),
    ("Pulled Pork", "ingredient", "Protein", "oz", 0.45, P, None, "BBQ pork is packed in sauce: usable weight per case is lower than 10 lb", None),
    ("Corned Beef", "ingredient", "Protein", "oz", 0.6156, I, "2026-09-30", "Catch weight, priced per lb", None),
    ("Tempeh", "ingredient", "Protein", "oz", 0.30, P, None, "Not on any US Foods invoice photographed", None),
    ("Chicken Salad", "ingredient", "Protein", "oz", 0.40, P, None, "No recipe provided yet. Diced chicken (US Foods 1627934) is probably the base", None),
    # Cheese
    ("Gouda", "ingredient", "Cheese", "slice", 0.35, P, None, None, None),
    ("Provolone", "ingredient", "Cheese", "slice", 0.32, P, None, None, None),
    ("Mozzarella", "ingredient", "Cheese", "oz", 0.35, P, None, None, None),
    ("Swiss", "ingredient", "Cheese", "slice", 0.33, P, None, None, None),
    ("White Cheddar", "ingredient", "Cheese", "slice", 0.30, P, None, None, None),
    ("Brie", "ingredient", "Cheese", "oz", 0.75, P, None, None, None),
    ("Burrata", "ingredient", "Cheese", "oz", 0.80, P, None, None, None),
    # Produce
    ("Spring Mix", "ingredient", "Produce", "oz", 0.28, P, None, "Two SKUs possible: harvest blend 4/3 lb or spring 3/1 lb", None),
    ("Arugula", "ingredient", "Produce", "oz", 0.3570, I, "2026-10-05", "Case = 2 x 2 lb", None),
    ("Roasted Red Peppers", "ingredient", "Produce", "oz", 0.2084, I, "2026-10-05",
     "ONE product (US Foods 4326492, 12 x 28 oz cans) feeds both the sandwich topping and the red pepper aioli", None),
    ("Pickled Onions", "ingredient", "Produce", "oz", 0.25, P, None, "Made in-house from red onion? No recipe provided", None),
    ("Tomato", "ingredient", "Produce", "oz", 0.0932, I, "2026-09-28", "25 lb case; slicing loses some weight (set yield_pct after a yield test)", None),
    ("Zucchini", "ingredient", "Produce", "oz", 0.18, P, None, "Sold by the 1/2 bushel; weight not printed", None),
    ("Pickles", "ingredient", "Produce", "oz", 0.20, P, None, "Sold in a 5 gal pail; drained weight not printed", None),
    ("Onion (fresh)", "ingredient", "Produce", "oz", 0.0386, I, "2026-09-03", "50 lb bag of yellow jumbo; peeling loses weight", None),
    ("Green Apple", "ingredient", "Produce", "oz", 0.22, P, None, "Out of stock on 10/05 (ordered 1, shipped 0)", None),
    ("Sauerkraut", "ingredient", "Produce", "oz", 0.18, P, None, "Sold in a 5 gal pail; weight not printed", None),
    # Herbs & spices
    ("Basil (fresh)", "ingredient", "Herbs & Spices", "oz", 0.9781, I, "2026-10-05", "1 lb per case. Estimated: a full 1/3 pan ~= 12 oz (weigh one)", None),
    ("Tarragon (fresh)", "ingredient", "Herbs & Spices", "oz", 1.4469, I, "2026-10-05", "1 lb per case. Estimated: a full 1/3 pan ~= 8 oz (weigh one)", None),
    ("Parsley (fresh)", "ingredient", "Herbs & Spices", "oz", 0.5681, I, "2026-10-05", "Sold per 1 lb bunch. Estimated: a full 1/3 pan ~= 16 oz (weigh one)", None),
    ("Cilantro (fresh)", "ingredient", "Herbs & Spices", "oz", 0.6231, I, "2026-10-05", "Sold per 1 lb bunch. Estimated: a full 1/3 pan ~= 12 oz (weigh one)", None),
    ("Salt", "ingredient", "Herbs & Spices", "Tbs", 0.02, P, None, "Not on any US Foods invoice photographed", None),
    ("Black Pepper", "ingredient", "Herbs & Spices", "Tbs", 0.04, P, None, "Not on any US Foods invoice photographed", None),
    ("Garlic (minced)", "ingredient", "Herbs & Spices", "Tbs", 0.10, P, None, "US Foods sells it by weight (6 x 32 oz tubs); recipes use Tbs", None),
    ("Cumin", "ingredient", "Herbs & Spices", "Tbs", 0.06, P, None, "Not on any US Foods invoice photographed", None),
    ("Red Wine Vinegar", "ingredient", "Herbs & Spices", "Tbs", 0.0346, I, "2026-08-13", "4 x 1 gal case = 1,024 Tbs", None),
    ("Crushed Red Pepper", "ingredient", "Herbs & Spices", "Tbs", 0.05, P, None, "Not on any US Foods invoice photographed", None),
    # Pantry
    ("Pistachios", "ingredient", "Pantry", "oz", 0.90, P, None, "Not on any US Foods invoice photographed", None),
    ("Mayonnaise", "ingredient", "Pantry", "oz", 0.0929, I, "2026-10-05", "4 x 1 gal case, counted as fluid oz (128 per gal)", None),
    ("Brown Mustard", "ingredient", "Pantry", "oz", 0.04, P, None, "Not on any US Foods invoice photographed", None),
    ("Oil", "ingredient", "Pantry", "oz", 0.1462, I, "2026-10-05", "Canola/olive 90/10, 4 x 1 gal case, counted as fluid oz", None),
    ("Canned Chipotle Peppers (Adobo)", "ingredient", "Pantry", "can", 2.20, P, None, "Can size unknown: verify. Not on any US Foods invoice photographed", None),
    ("Thousand Island Dressing", "ingredient", "Pantry", "oz", 0.15, P, None, "No recipe provided yet. Not on any US Foods invoice photographed", None),
]

# Prepared sauces: (name, batch yield in oz)
PREPS = [
    ("Basil Pesto", 32), ("Pistachio Pesto", 32), ("Chimichurri", 64),
    ("Chipotle Aioli", 128), ("Red Pepper Aioli", 128), ("Basil Aioli", 128), ("Special Sauce", 128),
]

# Prep recipe lines: (prepared, ingredient, qty, is_estimate, note)
PREP_LINES = [
    ("Basil Pesto", "Basil (fresh)", 12, True, "full 1/3 pan: estimated 12 oz"),
    ("Basil Pesto", "Salt", 1, False, None), ("Basil Pesto", "Black Pepper", 1, False, None),
    ("Basil Pesto", "Oil", 32, False, "4 cups"), ("Basil Pesto", "Garlic (minced)", 1, False, None),
    ("Pistachio Pesto", "Tarragon (fresh)", 8, True, "full 1/3 pan: estimated 8 oz"),
    ("Pistachio Pesto", "Pistachios", 5, False, None), ("Pistachio Pesto", "Garlic (minced)", 1, False, None),
    ("Pistachio Pesto", "Oil", 32, False, "4 cups"), ("Pistachio Pesto", "Salt", 1, False, None),
    ("Chimichurri", "Parsley (fresh)", 16, True, "full 1/3 pan: estimated 16 oz"),
    ("Chimichurri", "Cilantro (fresh)", 12, True, "full 1/3 pan: estimated 12 oz"),
    ("Chimichurri", "Oil", 40, False, "5 cups"), ("Chimichurri", "Cumin", 2, False, None),
    ("Chimichurri", "Garlic (minced)", 1, False, None), ("Chimichurri", "Red Wine Vinegar", 1, False, None),
    ("Chimichurri", "Crushed Red Pepper", 1, False, None), ("Chimichurri", "Salt", 1, False, None),
    ("Chimichurri", "Black Pepper", 2, False, None),
    ("Chipotle Aioli", "Canned Chipotle Peppers (Adobo)", 1, True, "1 can: size unverified"),
    ("Chipotle Aioli", "Garlic (minced)", 1, False, None), ("Chipotle Aioli", "Mayonnaise", 128, False, "1 gallon"),
    ("Red Pepper Aioli", "Roasted Red Peppers", 28, True, "1 can = 28 oz if the 12x28 oz product is the one used"),
    ("Red Pepper Aioli", "Mayonnaise", 128, False, "1 gallon"), ("Red Pepper Aioli", "Garlic (minced)", 1, False, None),
    ("Basil Aioli", "Mayonnaise", 128, False, "1 gallon"), ("Basil Aioli", "Basil Pesto", 32, False, "1 quart"),
    ("Special Sauce", "Mayonnaise", 64, False, "half gallon"), ("Special Sauce", "Brown Mustard", 64, False, "half gallon"),
]

MENU = [
    ("The Big Fun", "Sandwiches"), ("French Onion Roast Beef", "Sandwiches"), ("Smoke Stack", "Sandwiches"),
    ("Fresh Mozz", "Sandwiches"), ("Velvet Italian", "Sandwiches"), ("Cuban", "Sandwiches"),
    ("Ham and Brie", "Sandwiches"), ("Children's Grilled Cheese", "Grilled Cheese"),
    ("French Onion Grilled Cheese", "Grilled Cheese"), ("Pesto Grilled Cheese", "Grilled Cheese"),
    ("Granny Smith Grilled Cheese", "Grilled Cheese"), ("Chimmi Grilled Cheese", "Grilled Cheese"),
    ("Mad Salad", "Salad"), ("Reuben", "Specials"), ("Grilled Pesto Tempeh", "Specials"),
    ("Chicken Salad Sandwich", "Specials"),
]
S = "Annie's Bakery Sourdough"
# (menu item, ingredient, qty, is_estimate, note)
RECIPES = [
    ("The Big Fun", "Ciabatta Roll", 1), ("The Big Fun", "Chipotle Aioli", 2), ("The Big Fun", "Spring Mix", 0.5),
    ("The Big Fun", "Roasted Red Peppers", 1), ("The Big Fun", "Pickled Onions", 1), ("The Big Fun", "Turkey", 3), ("The Big Fun", "Gouda", 2),
    ("French Onion Roast Beef", "Ciabatta Roll", 1), ("French Onion Roast Beef", "Chipotle Aioli", 2),
    ("French Onion Roast Beef", "Arugula", 0.5), ("French Onion Roast Beef", "Provolone", 2),
    ("French Onion Roast Beef", "Onion (fresh)", 2), ("French Onion Roast Beef", "Roast Beef", 3), ("French Onion Roast Beef", "Chimichurri", 1),
    ("Smoke Stack", "Ciabatta Roll", 1), ("Smoke Stack", "Chipotle Aioli", 2), ("Smoke Stack", "Spring Mix", 0.5),
    ("Smoke Stack", "Tomato", 1), ("Smoke Stack", "Turkey", 3), ("Smoke Stack", "Bacon", 2), ("Smoke Stack", "Gouda", 2), ("Smoke Stack", "Chimichurri", 1),
    ("Fresh Mozz", "Ciabatta Roll", 1), ("Fresh Mozz", "Basil Aioli", 2), ("Fresh Mozz", "Arugula", 0.5),
    ("Fresh Mozz", "Tomato", 1), ("Fresh Mozz", "Mozzarella", 1.4), ("Fresh Mozz", "Zucchini", 3),
    ("Velvet Italian", "Ciabatta Roll", 1), ("Velvet Italian", "Basil Aioli", 2), ("Velvet Italian", "Arugula", 0.5),
    ("Velvet Italian", "Roasted Red Peppers", 1), ("Velvet Italian", "Pickled Onions", 1), ("Velvet Italian", "Capicola", 2), ("Velvet Italian", "Burrata", 3),
    ("Cuban", "Ciabatta Roll", 1), ("Cuban", "Special Sauce", 2), ("Cuban", "Pickles", 0.5), ("Cuban", "Ham", 3),
    ("Cuban", "Pulled Pork", 2), ("Cuban", "Swiss", 2),
    ("Ham and Brie", "Ciabatta Roll", 1), ("Ham and Brie", "Red Pepper Aioli", 2), ("Ham and Brie", "Arugula", 0.5),
    ("Ham and Brie", "Tomato", 1, True, "Recipe card lists tomato with no quantity: 1 oz assumed"),
    ("Ham and Brie", "Ham", 3), ("Ham and Brie", "Brie", 1), ("Ham and Brie", "Pistachio Pesto", 1),
    ("Children's Grilled Cheese", S, 2), ("Children's Grilled Cheese", "White Cheddar", 2),
    ("French Onion Grilled Cheese", S, 2), ("French Onion Grilled Cheese", "White Cheddar", 3),
    ("French Onion Grilled Cheese", "Onion (fresh)", 4), ("French Onion Grilled Cheese", "Chipotle Aioli", 1),
    ("Pesto Grilled Cheese", S, 2), ("Pesto Grilled Cheese", "White Cheddar", 3), ("Pesto Grilled Cheese", "Tomato", 1.2), ("Pesto Grilled Cheese", "Basil Pesto", 1),
    ("Granny Smith Grilled Cheese", S, 2), ("Granny Smith Grilled Cheese", "White Cheddar", 3),
    ("Granny Smith Grilled Cheese", "Green Apple", 1), ("Granny Smith Grilled Cheese", "Basil Aioli", 1),
    ("Chimmi Grilled Cheese", S, 2), ("Chimmi Grilled Cheese", "White Cheddar", 3), ("Chimmi Grilled Cheese", "Bacon", 2), ("Chimmi Grilled Cheese", "Chimichurri", 1),
    ("Mad Salad", "Arugula", 1), ("Mad Salad", "Spring Mix", 1), ("Mad Salad", "Roasted Red Peppers", 1.5),
    ("Mad Salad", "Pickled Onions", 1.5), ("Mad Salad", "Tomato", 1),
    ("Reuben", "Annie's Bakery Jewish Rye", 2), ("Reuben", "Corned Beef", 4), ("Reuben", "Sauerkraut", 1.5),
    ("Reuben", "Swiss", 2), ("Reuben", "Thousand Island Dressing", 1.5),
    ("Grilled Pesto Tempeh", S, 2), ("Grilled Pesto Tempeh", "Tempeh", 5.3), ("Grilled Pesto Tempeh", "Onion (fresh)", 1),
    ("Grilled Pesto Tempeh", "Roasted Red Peppers", 1), ("Grilled Pesto Tempeh", "Red Pepper Aioli", 1.5),
    ("Chicken Salad Sandwich", S, 2), ("Chicken Salad Sandwich", "Red Pepper Aioli", 2), ("Chicken Salad Sandwich", "Spring Mix", 0.5),
    ("Chicken Salad Sandwich", "Chicken Salad", 2.5), ("Chicken Salad Sandwich", "Tomato", 1),
]

# ----------------------------------------------------------------------------
# Supplier items (the mapping). Every row below was read off a real invoice.
# (sku, description, pack, brand, sales_unit, pricing_unit, catch_weight,
#  ingredient, units_per_case, units_per_lb, status, confidence, note)
# ----------------------------------------------------------------------------
def fixed(sku, desc, pack, brand, ing, per_case, conf, note=None, su="CS", status="suggested"):
    return (sku, desc, pack, brand, su, su, False, ing, per_case, None, status, conf, note)

def cw(sku, desc, pack, brand, ing, conf, note=None):
    return (sku, desc, pack, brand, "CS", "LB", True, ing, None, 16, "suggested", conf, note)

def need(sku, desc, pack, brand, ing, note, su="CS", cwt=False):
    return (sku, desc, pack, brand, su, "LB" if cwt else su, cwt, ing, None, None, "needs_input", "low", note)

def none(sku, desc, pack, brand, note, su="CS", pu=None):
    return (sku, desc, pack, brand, su, pu or su, False, None, None, None, "unmapped", None, note)

NOT_RECIPE = "Not in any recipe. Decide: track as retail/supply, or ignore."
ITEMS = [
    # ---- Bread
    fixed("1000419", 'ROLL, CIBAT WHT 5 Z 3X6" SLCD', "35/5 OZ", "CHEFS LINE", "Ciabatta Roll", 35, "high", "Case = 35 rolls. Confirms the demo's 'box = 35'."),
    fixed("9633650", 'BREAD, SDOUG 8" 15 SLCD 1/2"', "10/27 OZ", "ANNIESBKRY", "Annie's Bakery Sourdough", 150, "high",
          "10 loaves x 15 slices. The demo assumed 12 slices per loaf: it is 15."),
    # ---- Protein
    cw("2565976", "TURKEY, BRST WHL NTRL SHAPE", "2/6-8 LBA", "METRODELI", "Turkey", "high", "Catch weight: invoice prints each case's real weight (13-16 lb)."),
    cw("1007005", "ROAST BEEF, TOP INS RND C/O DF", "2/5-9 LBA", "CTLMN SLCT", "Roast Beef", "high", "Catch weight."),
    cw("1006663", "ROAST BEEF, TOP INS RND CAP-ON", "8-13 LBA", "CTLMN SLCT", "Roast Beef", "medium",
       "Different cut/pack than 1007005, seen once (09/24, ordered 2, shipped 1). Confirm it is the same roast beef you slice."),
    fixed("5931209", "BACON, PORK BELLY 13-17 APLWD", "15 LB", "HORMEL", "Bacon", 225, "medium",
          "Invoice gives 13-17 slices per lb x 15 lb: ~225 strips is the midpoint. Count one real case to confirm."),
    need("2771301", "BACON, PORK 14-18 SLCD LAID", "4D2/7.5 LB (hard to read)", "PATUXENT", "Bacon",
         "Seen once (10/05). Pack text unclear in the photo and the brand differs from Hormel. Check the pack and strips per case."),
    cw("6328900", "HAM, CAPCO SMKD CKD REF PORK", "2/5.25 LBA", "ROSELI", "Capicola", "medium",
       "'CAPCO' read as capicola. Confirm that is what goes on the Velvet Italian."),
    cw("7664840", "HAM, BNLS NTRL SHAPE NJ HONY", "2/7 LBA", "METRODELI", "Ham", "high", "Catch weight."),
    fixed("9504952", "PORK, BBQ PLLD IN VNGR SCE CKD", "2/5 LB", "BRKWD FARM", "Pulled Pork", 160, "medium",
          "2 x 5 lb = 160 oz, but the sauce is included in that weight. Weigh the drained pork from one bag to set the real usable oz."),
    cw("6863981", "CORNED BEEF, BOTM RND FLAT DF", "2/5-7 LBA", "CTLMN SLCT", "Corned Beef", "high", "Catch weight. Seen once (09/30)."),
    need("1627934", "CHICKEN, DCD BRST MEAT FRYER", "10 LB", "SPRNGR MTN", None,
         "Likely the base for house chicken salad, but there is no chicken salad recipe yet. Needs a prep recipe, then map this to it."),
    (  "1069942", "CHICKEN, BRST 4 Z BNLS SKNLS", "9/4/4 OZA", "CHEFS LINE", "CS", "LB", True, None, None, None, "unmapped", None,
       "Catch-weight 4 oz breasts, seen once (08/03). Not in any recipe: a special?"),
    # ---- Cheese
    fixed("1027612", "CHEESE, GOUDA SMKD SLCD 32 CT", "6/24 OZ", "GRT LAKES", "Gouda", 192, "high", "6 packs x 32 slices (0.75 oz each)."),
    need("1016284", "CHEESE, GOUDA HCKRY SMKD SLCD", "4/1.5 LB", "METRODELI", "Gouda",
         "Slice weight not printed. 96 oz per case; if slices are 0.75 oz that is 128/case. Count a pack to confirm."),
    fixed("4996898", "CHEESE, PROV SLCD .5 Z TRAY", "4/2.5 LB", "ROSELI", "Provolone", 320, "medium", "160 oz / 0.5 oz per slice, from the description."),
    fixed("7141673", "CHEESE, MOZZ LOG SLCD WHL MILK", "6/1 LB", "ROSELI", "Mozzarella", 96, "high", "6 x 1 lb = 96 oz."),
    fixed("4996989", "CHEESE, SWIS SLCD .75 Z TRAY", "4/2.5 LB", "GLNVW FRMS", "Swiss", 213.3333, "medium", "160 oz / 0.75 oz per slice = 213.3. Round to what a real case holds."),
    fixed("1419514", 'CHEESE, SWIS SLCD .75 Z 3.5"', "6/1.5 LB", "METRODELI", "Swiss", 192, "medium", "144 oz / 0.75 oz per slice. Seen once (08/03)."),
    need("2432912", "CHEESE, CHEDR WHT MILD SLCD", "6/1.5 LB", "METRODELI", "White Cheddar",
         "Slice weight not printed. 144 oz per case; if 0.75 oz that is 192 slices. Count a pack to confirm."),
    fixed("1356625", "CHEESE, BRIE WHEEL PLST WRPD", "2/2.2 LB", "GLNVW FRMS", "Brie", 70.4, "high", "2 wheels x 2.2 lb = 70.4 oz."),
    fixed("2808194", "CHEESE, BRIE WHEEL IMP CANDA", "2.2 LB", "EIFFEL TWR", "Brie", 35.2, "high", "One 2.2 lb wheel per case. Seen once (08/13)."),
    fixed("7590417", "CHEESE, BURRATA BALL 2 Z CUP", "6/4/2 OZ", "BELGIOIOSO", "Burrata", 48, "medium", "Read as 6 trays x 4 cups x 2 oz = 48 oz. Confirm against a real case."),
    none("1195139", "CHEESE, GYRE SLCD .75 Z TWIN", "4/1.5 LB", "METRODELI", "Gruyere: not in any recipe. " + "Decide: track or ignore."),
    # ---- Produce
    fixed("3956539", "SALAD MIX, HRVST BLND MDLY CUT", "4/3 LB", "CROSS VALY", "Spring Mix", 192, "medium",
          "12 lb per case. Is 'harvest blend' what you call spring mix? Ordered most weeks."),
    fixed("5100394", "SALAD MIX, SPRG BAG", "3/1 LB", "CROSS VALY", "Spring Mix", 48, "medium", "3 x 1 lb. Seen once (09/24, qty 3). Same ingredient, different SKU."),
    fixed("9546982", "ARUGULA, BABY CLND LOOS LEAF", "2/2 LB", "CROSS VALY", "Arugula", 64, "high", "2 x 2 lb = 64 oz."),
    fixed("4326492", "PEPPER, BELL RED SWT PLD FIRE", "12/28 OZ", "ROSELI", "Roasted Red Peppers", 336, "high",
          "12 cans x 28 oz. The demo assumed a ~15 oz can. One product feeds both the topping and the aioli, so they should be one ingredient."),
    need("4332003", 'ONION, RED JMB 3" BOX FRESH', "25 LB", "CROSS VALY", None,
         "Probably the source for pickled onions. If you pickle them in-house, a Pickled Onions prep recipe is needed. Seen once (09/14)."),
    fixed("4732525", "TOMATO, PLUM MED #1 GRD FRESH", "25 LB", "CROSS VALY", "Tomato", 400, "high", "25 lb = 400 oz purchased weight. Slicing loses some: do a yield test."),
    need("3973683", "ZUCCHINI, GREEN #1 MEDIUM FRES", ".5 BU", "PACKER", "Zucchini", "Sold by the half-bushel; weight not printed. Weigh one case. Seen once (09/24)."),
    need("6199833", "PICKLE, DILL CC CHIP 2000-2500", "5 GA", "MONARCH", "Pickles", "Sold in a 5 gal pail; drained weight not printed. Weigh one pail's contents."),
    fixed("8326696", 'ONION, YLW JMB 3" FRESH REF', "50 LB", "CROSS VALY", "Onion (fresh)", 800, "high", "50 lb = 800 oz purchased weight. Peeling loses some: do a yield test."),
    need("1433721", "APPLE, GRANY SMITH XFCY WA.", "CT20-22 EA", "CROSS VALY", "Green Apple",
         "Pack text 'CT20-22 EA' is unclear: how many apples / lb per case? Seen once (10/05, ordered 1, shipped 0: out of stock)."),
    need("1155662", "SAUERKRAUT, REF", "5 GA", "SCHWARTZ", "Sauerkraut", "5 gal pail; weight not printed. Seen once (09/28)."),
    # ---- Herbs
    fixed("4326401", "BASIL, FRESH HERB", "1 LB", "CROSS VALY", "Basil (fresh)", 16, "high", "1 lb = 16 oz. Price swings a lot week to week ($15.65 to $29.31 per lb)."),
    fixed("4332862", "TARRAGON, FRESH HERB", "1 LB", "CROSS VALY", "Tarragon (fresh)", 16, "high", "1 lb = 16 oz. ~$23-24 per lb: the pistachio pesto is expensive."),
    fixed("7326432", "PARSLEY, WSHD & DSTEM FRESH", "1 LB", "CROSS VALY", "Parsley (fresh)", 16, "high", "Sold per EA bunch of 1 lb.", su="EA"),
    fixed("9326430", "CILANTRO, WSHD & TRIMD FRESH", "1 LB", "CROSS VALY", "Cilantro (fresh)", 16, "high", "Sold per EA bunch of 1 lb.", su="EA"),
    # ---- Pantry
    fixed("1333970", "OIL, CNOLA OLIV EX VRGN 90/10", "4/1 GA", "ROSELI", "Oil", 512, "high", "4 gal x 128 fl oz. Recipes use cups: 4 cups = 32 oz."),
    fixed("7329113", "MAYONNAISE, XHVY PLST JUG SHLF", "4/1 GA", "HARVEST VL", "Mayonnaise", 512, "high", "4 gal x 128 oz. Matches the recipes' 'gallon of mayonnaise'."),
    need("9330671", "GARLIC, CHPD IN WATER NTRL TUB", "6/32 OZ", "ROSELI", "Garlic (minced)",
         "Sold by weight (192 oz/case) but recipes use Tbs. ~0.5 oz per Tbs would be ~384 Tbs per case: measure one tub. Seen once (08/03)."),
    fixed("9328337", "VINEGAR, WINE RED 5% ACIDITY", "4/1 GA", "MONARCH", "Red Wine Vinegar", 1024, "high", "4 gal x 256 Tbs per gal."),
    none("0294827", "VINEGAR, BALSMC IMP ITALY", "2/5 LT", "HARVEST VL", NOT_RECIPE),
    none("7775421", "MARGARINE, SALTD SOLID IW REF", "30/1 LB", "GLNVW FRMS", NOT_RECIPE),
    none("3007564", "CRUMB, GHM CRKR PLN FINE BAG", "2/5 LB", "NABISCO", NOT_RECIPE),
    none("6922793", "MILK, CNDSD SWTND", "24/14 OZ", "GLNVW FRMS", NOT_RECIPE),
    # ---- Drinks, chips, supplies (all unmapped)
    none("1015148", "DRINK, SODA ROOT BEER", "24/12 OZ", "DR BROWN", NOT_RECIPE),
    none("1822823", "TEA, ICED SWTND CAN CFNTD SHLF", "24/22 OZ", "ARNOLD PLM", NOT_RECIPE),
    none("2996874", "DRINK, SODA COLA DIET COKE BTL", "24/20 OZ", "COKE", NOT_RECIPE),
    none("3555398", "TEA, ICED BLK SWTND PET PLST", "12/18.5 OZ", "GOLD PEAK", NOT_RECIPE),
    none("5560131", "DRINK, SODA COLA COKE MEX GLS", "24/12 OZ", "COKE", NOT_RECIPE),
    none("5592001", "WATER, ARTES NTRL PLST BTL", "24/500 ML", "FIJI", NOT_RECIPE),
    none("5732777", "DRINK, SODA CLUB", "6/4/6.8 OZ", "FEVER-TREE", NOT_RECIPE),
    none("6716247", "DRINK, SODA CHRY CHEERWINE GLS", "6/4/12 OZ", "CHEERWINE", NOT_RECIPE),
    none("8522219", "DRINK, SODA GNGR BEER GLS BTL", "6/4/6.8 OZ", "FEVER-TREE", NOT_RECIPE),
    none("8805055", "DRINK, SODA GINGER ALE", "6/4/6.8 OZ", "FEVER-TREE", NOT_RECIPE),
    none("9255563", "WATER, SPRG GLS BTL VARBL", "24/16.9 OZ", "ACQUA PANA", NOT_RECIPE),
    none("1162679", "JUICE, GUAVA LMNDE DRNK 10%", "6/12 OZ", "NATALIES", NOT_RECIPE),
    none("1163618", "JUICE, BLOOD ORNG 100% NFC SS", "6/12 OZ", "NATALIES", NOT_RECIPE),
    none("1163624", "JUICE, LMNDE DRNK 22% NTRL SS", "6/12 OZ", "NATALIES", NOT_RECIPE),
    none("1203122", "JUICE, ORNG 100% NFC PLST BTL", "6/46 OZ", "SMPLYBEVRG", NOT_RECIPE),
    none("2354815", "CHIP, BBQ MSQT SS BAG SHLF", "60/1.5 OZ", "ZAPP'S", NOT_RECIPE),
    none("5199936", "CHIP, PTATO KTL SS BAG SHLF", "60/1.5 OZ", "ZAPP'S", NOT_RECIPE),
    none("6388911", "CHIP, PTATO KTL SS BAG SHLF", "60/1.5 OZ", "ZAPP'S", NOT_RECIPE),
    none("7760567", "CHIP, SALT & VNGR SS BAG SHLF", "60/1.5 OZ", "ZAPP'S", NOT_RECIPE),
    none("1564145", "CONTAINER, PPRBD KRAFT BRWN #44", "40 EA", "MONOGRAM", "Supply. Decide: track or ignore."),
    none("4954269", "CUP, PLA PLST 16 Z CLD CLR", "20/50 EA", "MONOGRAM", "Supply. Decide: track or ignore."),
    none("5150650", "LINER, 44 GAL 37X50 BLK .9 MIL", "5/20 EA", "MONOGRAM", "Supply. Decide: track or ignore."),
    none("7634157", "NAPKIN, DNNR WHT 15X17 2 PLY", "20/150 EA", "VALU PLUS", "Supply. Decide: track or ignore."),
    none("8609174", "TOWEL, PAPR 9X11 PERF RL WHT", "230 RL", "MONOGRAM", "Supply. Decide: track or ignore."),
    none("9650802", "GLOVE, NTRLE LG PF BLK AMBDX", "4/250 EA", "MONOGRAM", "Supply. Decide: track or ignore."),
]

# Which SKUs appeared on which photographed invoice (ship date). Several photos cut off
# before the bottom of the page, so a SKU missing from a date does not prove it wasn't delivered.
INVOICES = {
    "2026-07-30": "1015148 1822823 2996874 5560131 5592001 6388911 7760567 1162679 1163624 1203122 1356625 2565976 4732525 7329113 7590417 9546982 1000419 9504952 9633650",
    "2026-08-03": "1333970 1564145 2996874 4326492 5560131 6388911 6922793 7760567 9255563 9650802 1016284 1069942 1195139 1419514 2432912 3956539 5931209 7326432 7590417 7664840 8326696 9330671 9546982 1000419 9633650",
    "2026-08-13": "0294827 1015148 2354815 2996874 5199936 5560131 6199833 6388911 7760567 8609174 9328337 1163624 2565976 2808194 4996898 7141673 7329113 7590417 7664840 9546982 1000419 1627934 9633650",
    "2026-09-03": "5199936 5560131 6388911 7760567 1027612 1163624 1356625 2565976 7590417 7664840 8326696 1000419 9504952 9633650",
    "2026-09-14": "1015148 1333970 1564145 2354815 2996874 3555398 4326492 5199936 5560131 5592001 5732777 6199833 6388911 7760567 8522219 8805055 1027612 2432912 2565976 3956539 4326401 4332003 4332862 4996989 5931209 6328900 7326432",
    "2026-09-24": "1015148 1822823 2354815 3555398 5199936 5592001 6388911 7760567 1006663 1016284 1027612 1163618 1163624 2565976 3973683 5100394 5931209 7326432 7590417 7664840 9326430 1000419 1627934 9633650",
    "2026-09-28": "1015148 1564145 2354815 2996874 4326492 4954269 5150650 5199936 5560131 6388911 6716247 7760567 9255563 9650802 1007005 1155662 1162679 1163624 2432912 2565976 4326401 4732525 4996989 5931209 6328900 7326432 7329113",
    "2026-09-30": "3007564 2565976 6863981 9326430",
    "2026-10-01": "1015148 1564145 1822823 2354815 2996874 5199936 5560131 5732777 6388911 7634157 7760567 1027612 1163618 1163624 1203122 1356625 2432912 2565976 4996989 7326432 7329113 7590417 7664840 8326696 9326430 9546982",
    "2026-10-05": "1333970 2996874 4326492 5199936 6716247 7760567 1007005 1027612 1163624 1433721 2565976 2771301 3956539 4326401 4332862 4996898 7141673 7326432 7329113 7664840 7775421 9326430 9546982",
}


def q(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"


def n(x):
    return "NULL" if x is None else repr(x)


def validate():
    names = {i[0] for i in ING} | {p[0] for p in PREPS}
    problems = []
    if len(names) != len(ING) + len(PREPS): problems.append("duplicate item name")
    menu = {m[0] for m in MENU}
    seen_pairs = set()
    for r in RECIPES:
        if r[1] not in names: problems.append(f"recipe ingredient missing: {r[1]}")
        if r[0] not in menu: problems.append(f"recipe menu item missing: {r[0]}")
        if (r[0], r[1]) in seen_pairs: problems.append(f"ingredient twice in one recipe: {r}")
        seen_pairs.add((r[0], r[1]))
    seen_pairs = set()
    for pl in PREP_LINES:
        if pl[0] not in {p[0] for p in PREPS}: problems.append(f"prep missing: {pl[0]}")
        if pl[1] not in names: problems.append(f"prep component missing: {pl[1]}")
        if pl[1] == pl[0]: problems.append(f"sauce uses itself: {pl}")
        if (pl[0], pl[1]) in seen_pairs: problems.append(f"component twice in one sauce: {pl}")
        seen_pairs.add((pl[0], pl[1]))
    skus = [it[0] for it in ITEMS]
    if len(skus) != len(set(skus)): problems.append("duplicate SKU in ITEMS")
    for it in ITEMS:
        if it[7] and it[7] not in names: problems.append(f"supplier item {it[0]} -> unknown ingredient {it[7]}")
        if len(pack_desc(it)) > 60: problems.append(f"pack_description too long ({len(pack_desc(it))}): {pack_desc(it)}")
    seen = {s for v in INVOICES.values() for s in v.split()}
    for s in seen - set(skus): problems.append(f"SKU on an invoice but not in ITEMS: {s}")
    for s in set(skus) - seen: problems.append(f"SKU in ITEMS never on an invoice: {s}")
    if problems:
        print("\n".join(problems)); sys.exit(1)


def pack_desc(it):
    """varchar(60): what the invoice printed, so a human can recognise the product."""
    sku, desc, pack, brand, su, pu, cwt, *_ = it
    d = f"{desc.title()} ({pack})" if len(desc) + len(pack) < 55 else f"{desc[:50].title()} ({pack})"
    return ("Per lb: " + d) if cwt and len("Per lb: " + d) <= 60 else d


def pack_cost(it):
    """Invoice price per pack (per lb for catch weight), or None. Only from invoice-verified ingredient costs."""
    ingn, upc, upl = it[7], it[8], it[9]
    for (name, kind, cat, unit, cost, src, cdate, note, _) in ING:
        if name == ingn and src == I and cost is not None:
            # give the price to the first suggested SKU of that ingredient only
            first = next(x for x in ITEMS if x[7] == ingn and x[10] == "suggested")
            if first[0] != it[0]:
                return None
            per = upl if it[6] else upc
            return round(cost * per, 2)
    return None


def main():
    validate()
    L = []
    w = L.append
    w("-- =============================================================================")
    w("-- seed.sql  -  The Office, for the 7-table Pantry schema. GENERATED by tools/build_seed.py:")
    w("-- edit the script, not this file. Run once on a fresh database after both migrations.")
    w("--")
    w("-- Starting stock is ZERO on purpose: the first real numbers should come from a count.")
    w("-- par_level / reorder_quantity are blank until you set them.")
    w("-- Every SKU is seeded UNMATCHED (item_id and units_per_pack NULL): no delivery moves stock")
    w("-- until a manager confirms the match (see apply_mapping_suggestions.sql, or confirm_sku()).")
    w("-- =============================================================================")
    w("begin;")
    w(f"insert into public.supplier (supplier_name, rep_name, phone, email) values ({q(SUPPLIER)}, NULL, NULL, NULL);")
    w("")
    w("-- D1 inventory_item: purchased ingredients, then house-made sauces")
    w("insert into public.inventory_item (item_name, category, unit_of_measure) values")
    rows = [f"  ({q(i[0])}, {q(i[2])}, {q(i[3])})" for i in ING]
    rows += [f"  ({q(p[0])}, 'Prepared Sauces', 'oz')" for p in PREPS]
    w(",\n".join(rows) + ";")
    w("")
    item = lambda nm: f"(select item_id from public.inventory_item where item_name = {q(nm)})"
    unit_of = {i[0]: i[3] for i in ING}
    unit_of.update({p[0]: "oz" for p in PREPS})
    w("-- D2 recipe: menu items (yield 1 = one item sold) and sauces (yield = ounces per batch)")
    w("insert into public.recipe (recipe_name, recipe_type, toast_menu_item, yield_quantity) values")
    rows = [f"  ({q(m[0])}, 'menu', {q(m[0])}, 1)" for m in MENU]
    rows += [f"  ({q(p[0])}, 'sauce', NULL, {p[1]})" for p in PREPS]
    w(",\n".join(rows) + ";")
    w("")
    rec = lambda nm: f"(select recipe_id from public.recipe where recipe_name = {q(nm)})"
    w("-- D2 recipe_ingredient")
    w("insert into public.recipe_ingredient (recipe_id, item_id, quantity_used, unit_of_measure) values")
    rows = [f"  ({rec(r[0])}, {item(r[1])}, {r[2]}, {q(unit_of[r[1]])})" for r in RECIPES]
    rows += [f"  ({rec(pl[0])}, {item(pl[1])}, {pl[2]}, {q(unit_of[pl[1]])})" for pl in PREP_LINES]
    w(",\n".join(rows) + ";")
    w("")
    w("-- D5 supplier_sku: read off 10 US Foods invoices. last_unit_cost = price per pack (per lb for catch weight),")
    w("-- filled only where weight x price matched the printed extended price.")
    w("insert into public.supplier_sku (supplier_id, supplier_sku_code, pack_description, last_unit_cost) values")
    sup = f"(select supplier_id from public.supplier where supplier_name = {q(SUPPLIER)})"
    w(",\n".join(f"  ({sup}, {q(it[0])}, {q(pack_desc(it))}, {n(pack_cost(it))})" for it in ITEMS) + ";")
    w("")
    w("commit;")
    with open(os.path.join(ROOT, "supabase", "seed.sql"), "w") as f:
        f.write("\n".join(L) + "\n")

    # ---- optional: confirm the matches I could convert
    M = []
    M.append("-- apply_mapping_suggestions.sql  -  GENERATED by tools/build_seed.py.")
    M.append("-- Run in the Supabase SQL editor AFTER you have reviewed data/us_foods_mapping_review.xlsx.")
    M.append("-- Delete the line for any SKU you disagreed with, or change its number. Only SKUs the invoices let me convert")
    M.append("-- are here. The 'needs input' SKUs (weights not printed) are NOT: confirm them with confirm_sku() once measured.")
    M.append("begin;")
    sug = [it for it in ITEMS if it[10] == "suggested"]
    for it in sorted(sug, key=lambda r: r[0]):
        per = it[9] if it[6] else it[8]
        M.append(f"update public.supplier_sku set item_id = {item(it[7])}, units_per_pack = {per:g} "
                 f"where supplier_sku_code = {q(it[0])};  -- {it[7]}{' (per lb)' if it[6] else ''}")
    M.append("commit;")
    with open(os.path.join(ROOT, "supabase", "apply_mapping_suggestions.sql"), "w") as f:
        f.write("\n".join(M) + "\n")

    # ---- things the ERD has no column for
    with open(os.path.join(ROOT, "data", "notes_not_in_database.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["kind", "name", "note"])
        for i in ING:
            if i[7]: wr.writerow(["item", i[0], i[7]])
        for (p, ingn, qty, est, note) in PREP_LINES:
            if est or note: wr.writerow(["sauce line" + (" (ESTIMATE)" if est else ""), f"{p} / {ingn} / {qty:g}", note or ""])
        for r in RECIPES:
            est = r[3] if len(r) > 3 else False
            note = r[4] if len(r) > 4 else None
            if est or note: wr.writerow(["menu line" + (" (ESTIMATE)" if est else ""), f"{r[0]} / {r[1]} / {r[2]:g}", note or ""])

    # ---- review sheet for the human
    seen = {}
    for d, skus in INVOICES.items():
        for s in skus.split():
            seen.setdefault(s, []).append(d)
    order = {"suggested": 0, "needs_input": 1, "unmapped": 2}
    with open(os.path.join(ROOT, "data", "us_foods_item_mapping.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["status", "confidence", "sku", "us_foods_description", "pack_as_printed", "brand",
                     "maps_to_ingredient", "ingredient_unit", "how_it_converts", "invoices_seen_on", "last_seen",
                     "what_i_need_from_you", "your_answer"])
        for (sku, desc, pack, brand, su, pu, cwt, ingn, upc, upl, status, conf, note) in sorted(ITEMS, key=lambda r: (order[r[10]], r[7] or "~", r[0])):
            u = unit_of.get(ingn, "")
            if status == "unmapped":
                conv = ""
            elif status == "needs_input":
                conv = "cannot convert from the invoice alone"
            elif cwt:
                conv = f"catch weight: enter shipped LB; units_per_pack = {upl:g} {u} per lb"
            else:
                conv = f"units_per_pack = {upc:g} {u} per {'each' if su=='EA' else 'case'}"
            wr.writerow([status, conf or "", sku, desc, pack, brand, ingn or "", u, conv,
                         len(seen[sku]), max(seen[sku]), note or "", ""])
    print(f"seed.sql: {len(ING)+len(PREPS)} items, {len(MENU)+len(PREPS)} recipes, {len(RECIPES)+len(PREP_LINES)} recipe lines, {len(ITEMS)} SKUs; "
          f"{len(sug)} suggested matches")


if __name__ == "__main__":
    main()
