# Inventory: two hotbars, off-hand, backpack, chests (mine world)

Ported from zylanntest's `game/inventory/` (its README is the design this
follows), shaped to brickcity: content packs, MenuScreen, no renderer
read-backs, and the arsenal left alone.

Status: stages 1-9 built; round three (10-12: guns as items, materials and shapes, Terraria crafting) in progress.

## 1. Two systems, one pair of hands

The game already has a full gun system: `PlayerArsenal` + `Loadout` (two
groups of two guns, ordnance on 5, C/Tab swap, R pickups, the gun backpack on
I, `CharacterSave`). It is the Weapons area's and it runs in the city, the
planets and the mine world. The mine world also had a builder hotbar
(`mine_builder.gd`: blocks and fluids on 1-9 0 - =).

**Decision (2026-11-19, with the user): keep them separate.** Guns stay in
the arsenal; blocks, tools, fluids, chests and other items live in the new
`Inventory`. What is in your hands is one of the two at a time:

| Hands | Shown | Keys go to |
|---|---|---|
| **Guns** (default) | the gun rig, arsenal HUD | the arsenal: 1-4, 5, C/Tab, wheel, R, I, E melee |
| **Items** (B) | the held item, the two hotbars + off-hand | the inventory: 1-9, wheel, X, Z, E/Tab |

**B** switches, exactly as it turned build mode on and off before; build mode
IS the Items hands now. Why not merge: the arsenal's rules (groups, third
hand, infusion, the floor-gun pickup on R, saves) would all have to move into
slots, every scene that has guns would change, and the keys clash everywhere
(1-4 vs 1-9, wheel, Tab). Separate, the inventory touches only the mine world
and the arsenal touches nothing. A later step can put a "gun" item in a
hotbar slot that, selected, switches the hands to Guns on that arsenal slot,
if that is wanted; nothing here stops it.

## 2. What the player sees and does (Items hands)

| Input | Does |
|---|---|
| B | Guns <-> Items |
| 1-9, wheel | slot in the active hotbar |
| X tap | the other hotbar (1 <-> 2) |
| X held (350 ms) | the other off-hand slot |
| Z | block size: 2x2, 1x1, 4x4 studs (was X) |
| left mouse | break (blocks, tools, empty hand); scoop (buckets); take (test fluids) |
| right mouse | use the item in hand: place a block or chest, pour; on a chest, open it |
| middle mouse | pick the block looked at into the hand (a slot that has it, else the hand slot) |
| E or Tab | the inventory screen |

Two hotbars of 9 at the bottom middle, the active one bright and on top; the
two off-hand slots to their left. The item's name over the bar.

**Creative by default.** The mine world is a creative sandbox: placing does
not use the stack up and breaking drops nothing. `Inventory.creative = false`
(survival, a menu option later) uses up what is placed and puts what is
broken into the inventory (`add_item`, leftovers dropped). Both paths are in
the code and the probe from stage 1.

## 3. Data

### 3.1 The catalog: `ItemCatalog` (scripts/inventory/item_catalog.gd)

Items are tables in packs: `content/<pack>/data/items/*.json`, read through
`ContentPacks.files("data/items")`, so a mod adds items by shipping a file
(not `items/`: that folder is furniture builds, Docs/Content.md 2). Later
packs override earlier ids.

```json
{ "items": {
	"bucket": { "name": "Bucket", "kind": "bucket", "max_stack": 1, "colour": "#8c8c99" },
	"chest":  { "name": "Chest", "kind": "chest", "max_stack": 64, "colour": "#8a5a2b" }
} }
```

Fields: `name`, `kind` (`block`, `fluid`, `bucket`, `source_bucket`, `chest`,
`tool`, `misc`), `max_stack` (default 64), `hand` (`any`, `right`, `off`,
`two`; zylanntest's HandUse), `colour`, `glyph`, `tags`, `description`;
`block`: `material` (a BrickTerrain material name); `fluid`: `fluid` (1
water, 2 lava) and `fluid_kind` (`source`, `still`).

**Blocks come from the terrain itself.** Every `BrickTerrain.material_names()`
entry but air and bedrock becomes a block item, id = the name with `_` for
spaces (`dark_stone`), colour from its filament. A file entry with the same id
only changes what it names (a description, a max stack).

### 3.2 Stacks and slots: `ItemStack`, `Inventory`

`ItemStack` (RefCounted): `id`, `count`, `data` (a Dictionary for per-stack
state: a bucket's tiles, a source bucket's fluid, later a backpack's
contents). `to_dict` / `from_dict` for saves.

`Inventory` (scripts/inventory/inventory.gd, a plain object the mine world
owns -- not an autoload: the city and planets have no use for it yet) keeps
zylanntest's model whole: slot addresses `{area, index}` with areas
`hotbar_0`, `hotbar_1`, `offhand`, `main`, `chest`; `get_slot` / `set_slot` /
`slot_accepts`; `left_click`, `right_click`, `shift_click`, `double_click`,
drag (`begin_drag`, `drag_touch`, `finish_drag`, the live preview amounts),
`add_item`, `drop`, `swap_hand_offhand`, active hotbar / slot / off-hand,
`consume_active`. The main storage is 27 slots for now (no backpack item
yet; zylanntest's backpack-owns-the-storage rule is kept for a later stage
and is why `data` exists). `changed` fires on every change; the HUD and the
screen redraw from it.

The inventory is saved in the mine world's save folder beside the edits
(`<seed>_<hash>.inv`, JSON), with the world, at the same moments.

## 4. Stages

1. **Data.** ItemCatalog (packs + terrain blocks), ItemStack, Inventory with
   all the click/drag/split rules, `content/base/data/items/base.json`
   (fluids, buckets, chest, pickaxe). `tools/probes/inventory_probe.gd`:
   stacks, merge, split, shift-click, double-click, drag distribute, add_item
   order, hand rules, hotbar swap, save round trip.
2. **The hotbars drive the builder.** `mine_builder.gd` reads the hand from
   `Inventory` instead of its own `hotbar`: block item -> place that
   material, fluid/bucket items -> pour/scoop with the bucket state in the
   stack's `data`; MMB pick finds or sets the block item. New HUD
   (`scripts/inventory/hotbar_hud.gd`): two bars + off-hand, swatch icons.
   X = hotbar / off-hand, Z = size. The inventory saved with the world.
3. **The inventory screen.** A `MenuScreen` (fits any window; `MenuFit.audit`
   clean at 640x400) on E/Tab in Items hands: off-hand, both hotbars, main
   storage, cursor item, item info on hover, creative tab (every catalog item,
   click = take a stack, click with a stack = delete). The world keeps
   running (Minecraft's), the player's movement and the camera are held, the
   mouse freed. Escape: cursor stack back, else close.
   **Built** (`scripts/inventory/inventory_screen.gd`, `inv_slot.gd`;
   opened by `mine_world.toggle_inventory`): tabs Storage / Creative in the
   header; chest grid (when one is open), storage 9x3 or the catalog, then
   off-hand beside hotbar 2 over hotbar 1; a line saying what the mouse is
   over. Clicks as section 2's table plus 1-9 over a slot (swap with that
   hotbar slot), middle click (creative: a full stack of it). The slots size
   to the window (26-52 px). Every key is the screen's while it is open (no
   walking, flying, F or M); the flight is frozen, the mouse freed the
   camera's way so the pawn's controller and the arsenal go quiet; on foot
   the pawn still falls and swims. A stack still held on close goes back to
   storage; no room = lost until dropped items (stage 5).
4. **Icons that spin.** **Built** (`scripts/inventory/item_icons.gd`). At
   load the mine world renders every catalog item ONCE: each item a small
   model (a 2x2 brick of the block's colour, a translucent block for a fluid,
   a bucket, a pickaxe, a chest, a box for anything else), laid out 32 times
   in a row, each copy turned a further 1/32 of a circle, one row an item, in
   one SubViewport with an orthographic 3/4 camera -- one render draws every
   icon and every spin frame (56 px a frame; about 40 items is 1792 x 2240).
   The viewport keeps what it drew (UPDATE_ONCE) and slots draw their frame
   straight from its texture: no `get_image()`, no read-back, no viewport a
   slot (CLAUDE.md, Docs/WhereWorkRuns.md). InvSlot spins only while the mouse
   is on it, grows 1.18x and eases home after (zylanntest's SlotHoverFx;
   no cap on how many, since a frame is only a texture region). The HUD
   uses InvSlot too and spins the hand's slot. Headless: no icons, swatches.
   Cost, once at load: ~120 ms to build the 1280 copies (~5600 mesh
   instances, 2026-11-20) and ~20 ms to free them after the render.
   A pack item with its own model (a brick build) is for later: `_model`.
5. **Chests and dropped items.** **Built** (`scripts/inventory/mine_chests.gd`,
   `dropped_items.gd`, owned by the mine world).
   - A chest is not a terrain material (the field's C++ is untouched): a node
     2 x 2 studs on the stud lattice and one brick (3 plates) tall, standing
     at any plate height (ground tops are at any plate). The chest item's
     model fitted to it, and a box collider on `Layers.WORLD`: the pawn
     stands on it, bullets hit it.
   - Chest item + RMB: a chest on the face looked at, if it is air and held
     from under. RMB on a chest (any hand) opens it: the screen borrows its
     27 slots (Inventory.open_chest), shift-click moves between it and you.
     The builder aims at a chest nearer than the ground and outlines it; no
     block can be placed into one; MMB on it picks a chest.
   - Broken by LMB, a shot (`mine_world._mine` asks the chests first), or
     what holds it going (`MineChests.check` on every `terrain_edited`: the
     ground under it all air, or ground put into it -- a block broken, a
     shot, the ground coming down, Docs/TerrainCollapse.md). What it held
     falls out; in survival the chest too, in creative not (Minecraft's).
   - Dropped items: a stack and a small turning, bobbing model of it, falling
     onto BrickTerrain's cells (`solid_at`, no physics bodies), woken again
     when the ground changes. Walk within 1.3 m of one (after a second) and
     it goes into the inventory; what does not fit stays. Gone after 5
     minutes, at most 200. Also from Q over a slot in the screen (Shift: the
     stack) and from a held stack with no room when the screen closes.
   - Saved with the world: `chests` (key = block, the slots) and `drops`
     (stack, position, age) in the same `.inv` file as the inventory.
   - Terrain frame: both are children of the mine world with no transform
     of their own, so the origin shift moves them with the ground
     (Docs/MineWorld.md 15).
   - The kit has 64 chests (hotbar 2 slot 8); a creative save from before
     gets them on load (`ensure_item`), a survival one does not.

### Round two (2026-11-20, asked by the user): stages 6-9

6. **The inventory is the character's.** **Built** (2026-11-20). Your hotbars, off-hand, backpack
   and storage go with you from world to world: saved in the character file
   (`CharacterSave.items`, `user://profile/character.json` -- the same file
   PlayerKit keeps the guns and level in; both read, change their own field
   and write, so neither loses the other's). The world file (`.inv` beside
   the edits) keeps only what is the world's: its chests, its dropped items
   and its game mode. An old world file that still holds an inventory gives
   it to a character that has none yet, once. Written on the main thread
   when the inventory changed, at the autosave and on leaving (a small file,
   as PlayerKit's). A scripted pass uses `user://dev/character_gate.json`.
7. **Survival switch** **(built, 2026-11-20)** in the world menu (World tab): a check box that
   changes the game mode of THIS world at once (no Generate): saved in its
   world file. Survival: placing uses the stack up, breaking (the builder's
   block break, the pickaxes) gives the broken bricks, the Creative tab is
   hidden, creative blocks show their counts. Creative (default): as before.
   One inventory for both modes (the user's choice: it is the character's),
   so what was taken in creative comes into survival with you.
8. **Backpacks** (zylanntest's): Small 9, Medium 18, Large 27 slots. The
   equipped backpack's own contents ARE your storage: a backpack slot beside
   the off-hand; take it off and the storage is gone with it (into the
   cursor, into a chest, onto the ground -- its contents go along, the stack
   carries them, `ItemStack.contents`). Shift-click a backpack: into the
   empty backpack slot. A backpack never goes into the storage it is. The
   kit wears a Large one (the 27 slots the storage always had); an old save
   gets one holding its old storage.
   **Built** (2026-11-20): `ItemStack.contents`, `Inventory.backpack` with
   `main` its contents, area `backpack`; the slot sits with the hands (so
   the Creative tab can put one on); the storage grid is rebuilt to the
   backpack's size and says which it is; a backpack icon model. Probe and
   `--gate=inventory` (off, parked, a Small one on, the Large one back).
9. **Crafting** (zylanntest's 2 x 2 grid and recipe book): a 2 x 2 craft
   grid and its output in the screen; a recipe is matched wherever it sits
   in the grid, a cell may hold more than it needs; taking the output uses
   the ingredients up (shift: as many as there are). Recipes are tables in
   packs, `content/<pack>/data/recipes/*.json` (Docs/Content.md):
   `{"recipes": [{"name", "pattern": ["ab", "ba"], "key": {"a": "sand",
   "b": "#stone"}, "output": "sandstone", "count": 1}]}` -- `#tag` is any
   item with that tag. A backpack made from a backpack keeps its contents
   (`keep_contents`). A Recipes tab lists them all. 3 x 3 (a crafting table)
   is for later.
   **Built** (2026-11-20): `scripts/inventory/recipe_book.gd` (RecipeBook:
   load, parse, trim, match with mirror, `uses`, `describe`);
   `content/base/data/recipes/base.json` -- 13 recipes: sandstone (4 sand),
   terracotta (4 clay), ice (4 snow), gravel x2 (2 #stone, stacked), chest
   (4 #stone), bucket (2 iron ore, diagonal), source bucket (bucket + gold
   ore), pickaxe (2 #stone over iron ore), Mega Pickaxe (pickaxe + 3 diamond
   ore), Small Backpack (4 #grass), Medium (Small + 3 iron ore) and Large
   (Medium + 3 gold ore), both keeping the contents, obsidian (lava source +
   water source). Tags in `data/items/base.json`: stone, dark stone, granite,
   diorite = `stone`; the five grasses = `grass`. Inventory: area `craft`
   (2 x 2) and `craft_out` (computed when read, never stored; take_craft,
   clear_craft; Q, double click and 1-9 on it do nothing, or it would be
   free). The screen: the grid under the storage on the Storage tab, and a
   Recipes tab (each recipe's shape as icons, what it makes, what it takes).
   Closing the screen puts the grid's items back (what does not fit drops).

### Round three (2026-11-24, decided with the user): stages 10-12

Why: bricks are small, so a crafting GRID is trivial to fill; and two hand
systems (guns / items, switched with B) are more to learn than one. The
model is Rust's and Terraria's: one hotbar, everything an item; Terraria's
crafting list; Fortnite / Valheim building (material x shape, cost by size).

**Separate from the other scenes.** All of this is the mine world's. The
city and the planets keep the arsenal (PlayerArsenal, Loadout) exactly as
it is; the mine world asks PlayerKit for no arsenal (`"arsenal": false`)
and runs its own hands. Nothing here changes how a gun fires
(GunController) or is drawn (PlayerView).

10. **Guns are items.** A gun is a stack of one (`kind: gun`, one catalog
    item a weapon class, `gun_rifle`, `gun_pistol` ...) whose `data` is the
    gun entry CharacterSave already keeps (class, seed, tier, rarity, parts)
    plus its name and the rounds in it. `MineHands` (scripts/inventory/
    mine_hands.gd): the selected hotbar slot is what is in your hands -- a
    gun goes into the GunController and the view (made once from its entry,
    kept while you carry it; its ammo written back to the stack when put
    away and before a save); anything else puts the gun away and the builder
    acts. No B, no modes: 1-9 and the wheel choose, always. Starting kit: the
    character's kit guns if it has some (CharacterSave.loadout), else a
    rolled rifle and pistol. Not in the mine world (yet): grenades, the
    skill tree's shield, picking up floor guns with R, the workbench's
    infusion -- the arsenal's, still in the city and on planets.
11. **Materials, shapes, cost by size.** Building blocks become MATERIALS
    (stone, soil, sand, clay, snow, ice, ores ...; what breaking gives), each
    able to place a few terrain colours (stone: stone, dark stone, granite,
    diorite). The material in hand is laid with the chosen SHAPE: Z cycles
    plate 1x1, brick 1x1, 1x2, 2x2, 2x4, 4x4 (R turns it); V cycles the
    colour. Cost = the plate cells it fills (a 1x1 plate 1, a 2x4 brick 24);
    breaking gives them back. Wood and leaves need terrain materials of
    their own (the terrain's C++ table) and trees that break into them: a
    Terrain-area change, asked for separately.
12. **Terraria crafting.** Recipes are ingredient lists with a station:
    `{"inputs": {"stone": 12, "#ore": 2}, "station": "workbench",
    "output": ..., "count": ...}`. Stations (workbench, furnace) are placed
    like chests. The screen's Craft tab lists every recipe you can make with
    what you carry and the stations within 4 m (click: one, shift: as many
    as you can), then the ones you nearly can, greyed, with what is missing.
    It replaces the 2 x 2 grid and the Recipes tab.

Later: placing a backpack as a container (zylanntest), multiplayer authority.

## 5. Tests

- `tools/probes/inventory_probe.gd` (headless): stage 1 rules, the builder's
  hand mapping, chest save/load and break drops (stage 5).
- `scenes/terrain_test.tscn -- --gate=inventory` (windowed): real key and
  mouse events -- B, E, the Creative tab, a catalog item into hotbar 2, a
  left drag spreading a stack, Escape putting the held stack back, 9 over a
  storage slot, `MenuFit.audit` at 800x450 and 640x400, E closes, X and 3,
  RMB places the item, the inventory back after save + generate. Prints
  `INV-GATE PASS`. Screenshots `user://dev/inv_*.png`. Stage 4: icons
  rendered, the hovered slot turns. Stage 5: a chest from the kit put down,
  opened with RMB, grass clicked into it, the chest screen at 640x400; after
  save + generate it is back with the grass; a shot breaks it, the grass
  drops and rests on the ground, flying over it picks it up; a second chest
  breaks when the ground under it is removed.
- Also: `mine_world_probe`, `content_packs_probe`, `--gate=menu`, `--gate=build`
  (if the build gate exists: it uses the old hotbar's slot keys).

## Mega Pickaxe (2026-11-19)

`mega_pickaxe` in content/base/data/items/base.json: a tool with
`break_area` 5 and `break_repeat` 0.05 (the catalog keeps these two fields).
One break clears a 5 x 5 face of blocks -- the face looked at, one block deep,
centred on the block looked at (`MineBuilder._break_cells`) -- and held it
repeats every 0.05 s against the pickaxe's 0.22 (`_break_repeat`). In the kit
right after the pickaxe on bar 2; a save made before it existed gets it once
(`Inventory.ensure_item`, called by MineWorld._load_inventory). In survival
the broken bricks are all counted as the material looked at. `-- --gate=mega`
compares it with the pickaxe (270 plate cells against 12 on uneven ground; a
full face is 300); inventory_probe checks the kit and the save top-up.
