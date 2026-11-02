#!/usr/bin/env python3
"""Builds data/us_foods_mapping_review.xlsx (the sheet a person fills in) from tools/build_seed.py."""
import csv
import os
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import build_seed as B  # noqa: E402

F = "Arial"
thin = Side(style="thin", color="D0D0D0")
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)
HEAD = PatternFill("solid", fgColor="2E3D34")
FILL = {"suggested": "E6EEE3", "needs_input": "FBEFDC", "unmapped": "EDEDED"}
INPUT = PatternFill("solid", fgColor="FFFF00")   # cells the person fills in


def style_header(ws, row, ncols):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.font = Font(name=F, bold=True, color="FFFFFF", size=10)
        cell.fill = HEAD
        cell.alignment = Alignment(wrap_text=True, vertical="center")
        cell.border = BORDER


wb = Workbook()

# ------------------------------------------------------------------ Read me
ws = wb.active
ws.title = "Read me"
ws.sheet_view.showGridLines = False
ws.column_dimensions["A"].width = 3
ws.column_dimensions["B"].width = 26
ws.column_dimensions["C"].width = 95
rows = [
    ("title", "US Foods item mapping: your review", None),
    ("text", "What this is", "Every product read off your 10 US Foods invoices (Jul 30 to Oct 5, 2026), matched to your ingredients, with how a case converts into the units your recipes use. In the database every one of these SKUs starts UNMATCHED (no ingredient, no conversion), and an unmatched SKU cannot change stock. Your answers decide which ones get matched."),
    ("text", "After you answer", "Rows you mark OK get confirmed by running supabase/apply_mapping_suggestions.sql (I delete or edit the lines you corrected). Amber rows are confirmed one at a time with confirm_sku() once you have the real number. The database stores one number per SKU (units_per_pack) and a price per pack (last_unit_cost); brand and these notes live only in this sheet."),
    ("text", "What to do", "Go down the 'Mapping review' tab. In the yellow 'Your answer' column, write OK if the match and conversion are right, or write what is wrong / what the real number is. Start with the amber rows: those are the ones I could not convert from the invoice alone."),
    ("head", "Colour key", None),
    ("key-suggested", "Green row", "I matched it and calculated the conversion from the invoice. Needs your OK."),
    ("key-needs_input", "Amber row", "I know which ingredient it is, but the invoice does not say how much usable product is in a case (weights not printed). Needs a real measurement from you."),
    ("key-unmapped", "Grey row", "Not in any recipe (drinks, chips, supplies, other). Decide whether to track it as retail/supply, or ignore it."),
    ("key-input", "Yellow cell", "The only cells meant for you to edit."),
    ("head", "Example answers", None),
    ("example", "Example (not a real row)", "OK   |   No, it's Hormel only, we stopped buying Patuxent   |   Weighed one pail: 31 lb drained = 496 oz   |   Ignore"),
    ("head", "Things to know", None),
    ("text", "Photos are partial", "Several photos cut off the bottom of the page, so the frozen section (rolls, bread) is missing from 10/01 and 10/05 and some lines may be missing from 09/14 and 09/28. A product missing from a date does not prove it was not delivered."),
    ("text", "Prices", "I only trusted a price when weight x price (or quantity x price) matched the printed extended price. Prices on the 'Corrections' tab are approximate. The importer will take exact prices from future invoices."),
    ("text", "Estimates", "Anything marked 'medium' or 'low' confidence is my arithmetic from the pack text (for example, slices per case from slice weight). Count one real case to settle it."),
]
r = 2
for kind, a, b in rows:
    if kind == "title":
        ws.cell(row=r, column=2, value=a).font = Font(name=F, bold=True, size=14)
        r += 2
        continue
    if kind == "head":
        ws.cell(row=r, column=2, value=a).font = Font(name=F, bold=True, size=11, color="2E3D34")
        r += 1
        continue
    ca = ws.cell(row=r, column=2, value=a)
    cb = ws.cell(row=r, column=3, value=b)
    for c in (ca, cb):
        c.font = Font(name=F, size=10)
        c.alignment = Alignment(wrap_text=True, vertical="top")
    ca.font = Font(name=F, size=10, bold=True)
    if kind.startswith("key-"):
        k = kind[4:]
        if k == "input":
            ca.fill = INPUT
        else:
            ca.fill = PatternFill("solid", fgColor=FILL[k])
    if kind == "example":
        cb.fill = INPUT
    ws.row_dimensions[r].height = 15 * max(1, (len(b) // 95) + 1)
    r += 1

# ------------------------------------------------------------------ Mapping review
ws = wb.create_sheet("Mapping review")
headers = ["Status", "Confidence", "SKU", "US Foods description", "Pack as printed", "Brand",
           "Maps to ingredient", "Ingredient unit", "How it converts", "On how many of 10 invoices", "Last seen",
           "What I need from you", "Your answer"]
ws.append(headers)
style_header(ws, 1, len(headers))
ws.row_dimensions[1].height = 32
with open(os.path.join(ROOT, "data", "us_foods_item_mapping.csv"), newline="") as f:
    rd = csv.DictReader(f)
    for rec in rd:
        ws.append([rec["status"], rec["confidence"], rec["sku"], rec["us_foods_description"], rec["pack_as_printed"],
                   rec["brand"], rec["maps_to_ingredient"], rec["ingredient_unit"], rec["how_it_converts"],
                   int(rec["invoices_seen_on"]), rec["last_seen"], rec["what_i_need_from_you"], None])
widths = [12, 11, 10, 36, 16, 14, 24, 10, 38, 12, 11, 60, 34]
for i, w in enumerate(widths, 1):
    ws.column_dimensions[get_column_letter(i)].width = w
for row in ws.iter_rows(min_row=2, max_row=ws.max_row):
    status = row[0].value
    for c in row:
        c.font = Font(name=F, size=10)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        c.border = BORDER
        if c.column < 13:
            c.fill = PatternFill("solid", fgColor=FILL[status])
    row[12].fill = INPUT
    row[2].number_format = "@"          # keep SKU as text (leading zeros, e.g. 0294827)
    row[9].alignment = Alignment(horizontal="center", vertical="top")
ws.freeze_panes = "E2"
ws.auto_filter.ref = f"A1:{get_column_letter(len(headers))}{ws.max_row}"
dv = DataValidation(type="list", formula1='"OK,Ignore,Needs discussion"', allow_blank=True, showErrorMessage=False)
dv.promptTitle = "Your answer"
dv.prompt = "Pick OK / Ignore, or type what is wrong or the real number."
dv.showInputMessage = True
ws.add_data_validation(dv)
dv.add(f"M2:M{ws.max_row}")

# ------------------------------------------------------------------ Corrections
ws = wb.create_sheet("Corrections")
h = ["Item", "Earlier demo assumed", "Invoices show", "Why it matters"]
ws.append(h)
style_header(ws, 1, 4)
corr = [
    ("Ciabatta roll cost", "$0.55 per roll", "~$1.53 per roll ($52.50-53.39 per case of 35)", "Every sandwich is costed ~$1 too low."),
    ("Sourdough slices", "12 slices per loaf; $0.30 per slice", "15 slices per loaf, 10 loaves = 150 per case; ~$0.37 per slice", "Stock per case was understated by 20%."),
    ("Roasted red pepper can", "~15 oz can", "12 x 28 oz per case", "Red pepper aioli would deduct the wrong amount."),
    ("Roasted red peppers: 2 ingredients", "'sliced topping' (oz) and 'canned' (can)", "One product (SKU 4326492) feeds both", "Two stock levels for one shelf would drift apart. Merged into one."),
    ("Turkey cost", "$0.42 per oz", "~$0.49 per oz ($7.85-7.88 per lb)", "Most-used protein."),
    ("Herb costs", "Basil $0.55, tarragon $0.70, parsley $0.35, cilantro $0.35 per oz", "Basil ~$0.98, tarragon ~$1.45, parsley ~$0.57, cilantro ~$0.62 per oz (basil swung $15.65-$29.31 per lb)", "Pesto and chimichurri cost more than assumed, and herb prices move week to week."),
    ("Oil and mayo cost", "Oil $0.06, mayo $0.05 per oz", "Oil ~$0.15, mayo ~$0.09 per oz", "Every sauce is costed low."),
    ("Suppliers", "Baker's Row, Coastal Foods, Greenline, Restaurant Depot", "US Foods for nearly everything seen", "Replaced with a single US Foods supplier plus 'other / not on invoices'."),
    ("Delivery days", "Thursday and Monday", "Confirmed: 9 of 10 invoices ship Mon or Thu (plus one Wednesday, 09/30, a separate route)", "Count and ordering schedule can key off these."),
    ("Catch-weight meats", "Counted as a fixed case", "Turkey, roast beef, ham, capicola, corned beef are priced per lb and each case has its own printed weight", "Must convert from the printed weight, not a fixed case size."),
    ("Ordered vs shipped", "Assumed equal", "Roast beef 2 ordered / 1 shipped (09/24); Granny Smith apples 1 ordered / 0 shipped (10/05)", "Stock must follow what shipped, not what was ordered."),
]
for rec in corr:
    ws.append(list(rec))
for i, w in enumerate([30, 40, 62, 52], 1):
    ws.column_dimensions[get_column_letter(i)].width = w
for row in ws.iter_rows(min_row=2, max_row=ws.max_row):
    for c in row:
        c.font = Font(name=F, size=10)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        c.border = BORDER
ws.freeze_panes = "B2"

# ------------------------------------------------------------------ Not on invoices
ws = wb.create_sheet("Recipe items with no SKU")
ws.append(["Ingredient used in a recipe", "Unit", "Used in", "Question for you"])
style_header(ws, 1, 4)
mapped = {it[7] for it in B.ITEMS if it[7]}
uses = {}
for (menu, ing, *_rest) in B.RECIPES:
    uses.setdefault(ing, []).append(menu)
for (p, ing, *_rest) in B.PREP_LINES:
    uses.setdefault(ing, []).append(p + " (sauce)")
q = {
    "Annie's Bakery Jewish Rye": "Where do you buy it? Not on any US Foods invoice.",
    "Tempeh": "Where do you buy it?",
    "Chicken Salad": "What is the recipe? (Diced chicken, SKU 1627934, is probably the base.)",
    "Pickled Onions": "Do you pickle red onions in-house (SKU 4332003)? If so, what is the recipe?",
    "Salt": "Bought elsewhere? How is it tracked: by container or by Tbs?",
    "Black Pepper": "Bought elsewhere?",
    "Cumin": "Bought elsewhere?",
    "Crushed Red Pepper": "Bought elsewhere?",
    "Pistachios": "Bought elsewhere?",
    "Brown Mustard": "Bought elsewhere?",
    "Canned Chipotle Peppers (Adobo)": "Bought elsewhere? What size can?",
    "Thousand Island Dressing": "Bought or made? If made, what is the recipe?",
}
unit_of = {i[0]: i[3] for i in B.ING}
for name in sorted(unit_of):
    kind = [i for i in B.ING if i[0] == name][0][1]
    if name in mapped or name not in uses:
        continue
    ws.append([name, unit_of[name], ", ".join(sorted(set(uses[name]))[:4]) + ("..." if len(set(uses[name])) > 4 else ""), q.get(name, "")])
for i, w in enumerate([34, 8, 60, 70], 1):
    ws.column_dimensions[get_column_letter(i)].width = w
for row in ws.iter_rows(min_row=2, max_row=ws.max_row):
    for c in row:
        c.font = Font(name=F, size=10)
        c.alignment = Alignment(wrap_text=True, vertical="top")
        c.border = BORDER
    row[3].fill = INPUT
ws.freeze_panes = "B2"

out = os.path.join(ROOT, "data", "us_foods_mapping_review.xlsx")
wb.save(out)
print("wrote", out)
