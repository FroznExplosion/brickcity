# Inventory: two hotbars, off-hand, backpack, chests (mine world)

Ported from zylanntest's `game/inventory/` (its README is the design this
follows), shaped to brickcity: content packs, MenuScreen, no renderer
read-backs, and the arsenal left alone.

Status: stages 1-12 built (round three, 2026-11-24: guns as items, materials and shapes, Terraria crafting);
2026-11-25 Minecraft's menus and Bedrock's recipe book (section 14); round four (2026-11-25: off-hand
up/down, quick slot, two-handed guns, off-hand pistol) -- see its section in 4.

**Sections 1 and 2 below are the first round's.** There is no B mode switch any
more (stage 10): the selected slot is in the hands, a gun or anything else;
B is now the quick slot and C the off-hand (round four).

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
    **Built** (2026-11-24): `scripts/inventory/mine_hands.gd`, gun items a
    class from `WeaponClass.gun_ids()` (ItemCatalog), a gun icon model,
    PlayerKit `"arsenal": false` (the level still loads), PlayerHud
    `hint_lines` (the mine world shows its own keys). The builder acts when
    the hand is not a gun; the wheel always walks the hotbar (Shift + wheel:
    the flight's speed). `--gate=inventory`: the kit's guns, 7 draws one,
    LMB fires it (31 -> 26 rounds), 1 puts it away, its rounds in its stack
    and kept through a save. A gun held right in front of a wall is pulled
    back by the view (PlayerView), as everywhere.
11. **Materials, shapes, cost by size.** Building blocks become MATERIALS
    (stone, soil, sand, clay, snow, ice, ores ...; what breaking gives), each
    able to place a few terrain colours (stone: stone, dark stone, granite,
    diorite). The material in hand is laid with the chosen SHAPE: Z cycles
    plate 1x1, brick 1x1, 1x2, 2x2, 2x4, 4x4 (R turns it); V cycles the
    colour. Cost = the plate cells it fills (a 1x1 plate 1, a 2x4 brick 24);
    breaking gives them back. Wood and leaves need terrain materials of
    their own (the terrain's C++ table) and trees that break into them: a
    Terrain-area change, asked for separately.
    **Built** (2026-11-24): materials are block items with `colours` -- the
    pack's families soil (grass, dirt, podzol, the grasses), stone (stone,
    dark stone, granite, diorite, road), sand (sand, red sand), clay (clay,
    the terracottas) fold those colours' own items into them
    (ItemCatalog._fold_families, `folded_into`); the rest stay one colour.
    A block stack holds 999 plate cells. MineBuilder.SHAPES: 2x2, 1x1, 4x4,
    1x2, 2x4 bricks and 1x1, 2x2, 2x4 plates (Z), R turns, V the colour,
    MMB picks the material at the colour looked at. Survival: laying uses
    the cells filled, breaking (and the pickaxes) gives the cells broken.
    Saves: the inventory's format 2 and the world file's format 3 count
    plate cells; older ones are read with bricks x 3 and folded ids moved
    onto their family. Kit bar 1: soil, stone, gravel, snow, sand,
    sandstone, clay, ice, obsidian. `--gate=inventory` (58 checks): V, Z x4,
    R, a turned 2x4 dark stone brick for 24 cells.
12. **Terraria crafting.** Recipes are ingredient lists with a station:
    `{"inputs": {"stone": 12, "#ore": 2}, "station": "workbench",
    "output": ..., "count": ...}`. Stations (workbench, furnace) are placed
    like chests. The screen's Craft tab lists every recipe you can make with
    what you carry and the stations within 4 m (click: one, shift: as many
    as you can), then the ones you nearly can, greyed, with what is missing.
    It replaces the 2 x 2 grid and the Recipes tab.
    **Built** (2026-11-24): RecipeBook reads `inputs` / `station` (no
    shapes); 14 base recipes (workbench by hand from stone and clay, furnace
    at a workbench, gravel and the small backpack by hand, sandstone, ice,
    chest, pickaxe, the backpack upgrades at a workbench, bucket, source
    bucket, Mega Pickaxe at a furnace, obsidian). Inventory `count_of`,
    `can_craft`, `missing`, `craft` (from the hotbars, off-hand and storage;
    All: up to 64 times; a backpack keeps its contents); an old save's grid
    items go into storage. Workbench and furnace are `kind: station` items,
    placed, saved and broken through MineChests (each placed block now has
    an `item`; `stations_near`, 4 m); RMB on one opens the Craft tab. The
    kit has both at the end of the storage. `--gate=inventory` (63 checks):
    gravel by hand with a real click, sandstone greyed, a workbench placed,
    RMB opens the Craft tab, sandstone made; the Craft tab at 640x400.

### Grenades and backpacks put down (2026-11-25, asked by the user)

- **Grenades** are an item (stacks of 16; 16 in the kit's storage, a furnace
  recipe: 4 from 12 coal ore + 6 iron ore). G throws one from whatever is
  carried (LMB too with it in the hand), the arsenal's throw
  (`Grenade.throw`) without the arsenal (`mine_world.throw_grenade`). Its
  blast reaches the world through `AIServices.on_structure_hit`, which the
  mine world now sets (`_world_hit`: a blast -> `blast()`, a shot -> `_mine`):
  every whole brick in the box round it goes (BrickTerrain.find_bricks on a
  worker, as the Mega Pickaxe's face) and chests in reach break. The crash:
  `Grenade.blast` asked `services.ai_world.line_clear`, and the mine world
  has no AI world -- now `Grenade._clear` asks the physics instead there.
  Rockets and grenade launchers (the player's gun) blast the same way.
- **Backpacks put down** (zylanntest's): a backpack in the hand + RMB puts it
  down as a container (MineChests: `is_container`, `slot_count` -- its slots
  ARE its contents, 9/18/27); it leaves the hand even in creative. RMB opens
  it (the screen shows only its slots, titled with its name); Shift + RMB
  picks it up and wears it -- if one is worn they SWAP, yours standing where
  the other stood with its contents (`mine_world.take_backpack`). Broken
  (LMB, a shot, a blast, the ground going) it falls as itself with its
  contents, never scattered. Saved with the world like a chest.
- Probe: placed backpacks (122 checks). `--gate=inventory` (78): G throws,
  the blast breaks bricks; a backpack down, opened, picked up and swapped
  back, broken.

Later: multiplayer authority.

### Round four: both hands and the quick slot (2026-11-25, decided with the user)

The question was how guns, the off-hand and aiming fit together. Rejected
on the way: "a two-handed item hides the off-hand" alone (a pistol could
never aim with anything in the off-hand, since RMB would be the off-hand's);
everything two-handed (the off-hand would be pointless); a combat/building
mode switch (B, the old way: guns not in the inventory again). The two
hotbars stay the "modes" the player wants: bar 1 combat, bar 2 building is
a layout, not a rule.

**What was built:**

- **Off-hand up or down** (`Inventory.offhand_up`, saved). C toggles it
  (pad: hold LB). Down: RMB is the main hand's (aim a gun, place a block) --
  plain Minecraft minus its off-hand. Up, with something in the active
  off-hand slot: RMB uses the off-hand item instead -- places its block,
  device or chest, fires its pistol. Nothing is ever hidden by a rule the
  player did not choose. X held still picks which of the two off-hand
  slots (pad: hold Y).
- **Two-handed items lower the off-hand by themselves**: a gun of any class
  but pistol and revolver (`hand: "two"`) in the main hand. The flag is
  kept, so going back to a one-handed item brings the off-hand back up.
  `Inventory.offhand()` is the off-hand in use: null while down, empty or
  lowered.
- **What may go in the off-hand** (`hand`): `any` (the default for a pack
  item with none) = blocks, pistols, revolvers, every wiring device and
  cable, chests, buckets and fluids, pickaxes, seeds and crops; `off` =
  shields (none yet); `right` = the wrench, grenades, hoe, scythe, watering
  can, backpacks, stations; `two` = the other guns. RMB with a non-gun in
  the off-hand, up, is its place/pour (`place_target` on the off-hand).
- **The quick slot** (`Inventory.quick`, one slot, saved; area `quick`):
  B pulls it out (pad: hold RB) -- it is the main hand until put away:
  B again, a tap of X or a turn of the wheel (pad: an RB/LB tap, a Y tap)
  only put it away -- the toolbar slot it left comes back, the bar is not
  swapped, the slot not stepped; 1-9 put it away and take that slot. Empty:
  B does nothing. Meant for a grenade, a special gun or tool.
- **Pad** (no pad support exists elsewhere yet: moving, looking and the
  triggers are for later): LB/RB tap step the slot, hold (350 ms) = off-hand
  up/down / quick slot; Y tap = other bar (or put the quick slot away),
  hold = the other off-hand slot. A tap acts on release, so a hold never
  also steps.
- **The off-hand pistol**: its own GunController (`MineHands.off_gun`),
  RMB its trigger, its rounds kept in its stack like the main gun's; it
  reloads by itself when empty, and with R. Its trigger rules are the
  gun's own (GunFireMode): a pistol that charges fires on the release, so a
  long hold charges instead. It is drawn low on the left
  of the view (no left arm pose yet: later, with ViewArms). Dual pistols
  are a main pistol + an off-hand pistol, up: LMB right, RMB left, no
  sights.
- **HUD**: the off-hand slots left of the bars, dim while down (or lowered
  by a two-handed item); the quick slot right of the bars, outlined while
  out; the caption names both hands ("Pickaxe  |  off: Stone").
- **Filling them**: the screen has no off-hand or quick slots (section 14):
  C over a slot swaps it with the active off-hand slot, B with the quick
  slot; over an empty slot the hand's item lands there.
- **Never by themselves**: pickups, crafting, shift-click and the cursor
  going back never put an item into an empty off-hand slot (a stack of the
  same kind there is topped up by a pickup).
- Shields: an `off` item needs blocking, which does not exist yet -- later.
- Tests: inventory_probe (the off-hand rules, pickups never into it, the
  quick slot and up flag saved); `--gate=inventory` 4a (stone laid from the
  off-hand with C and RMB), 4b (the off-hand pistol fires on RMB taps, a
  rifle lowers it, it comes back), 4c (B, X, the wheel, 3; saved).
  2026-11-26: probe 141 ok, gate PASS (109 checks).

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

## 13. Wood and leaves (2026-11-24)

Asked by the user: build with every brick type by material -- stone, wood,
leaves -- and get wood from trees. Before this the terrain had one `wood` and
one `leaves` material (MineWater.md 14.8, floating debris), no item said what
they were for, and a tree could not be broken.

**Materials.** Appended to BrickTerrain's `Material` (append-only: a save
stores the byte), each a filament no other ground uses (floaters.gd tells a
piece's material by its colour). No dark wood: the one dark brown left, skin
dark, is dirt's brown to 0.01.

| Family | Colours (terrain materials, filament) |
|---|---|
| wood | wood (caramel, the old one), pale wood (skin medium), birch wood (sand) |
| leaves | leaves (forest, the old one), light leaves (lime), autumn leaves (orange), red leaves (red) |

`material_burns` (brick_terrain.h) is wood or leaves of any colour: lava
lights them (brick_fluid `ignite_round`, lava_fire.gd), and floaters.gd floats
them. The terrain draws them in their filament colours like all ground (the
PBR wood/leaf sets of Docs/PbrWood.md are brick-world materials, not terrain;
a PBR look for terrain wood is later work).

**Items.** `wood` and `leaves` in content/base/data/items/base.json with
`colours`: material families (section 11), so Z shapes, R turns, V picks the
colour and the cost is plate cells, as for stone. The starting kit has a
full stack of each at the end of the storage (before the stations); an older
character takes them from the Creative tab.

**Trees break whole.** A mine world tree stays a TerrainTrees row (a brick
recipe drawn by ImpostorLod), not terrain cells: stamping trees into the field
would mean the generator, the coarse tiers and the far cards all learning
trees. Instead:
- `TerrainTrees.ray` meets a tree's trunk box or canopy box (per variant,
  from its recipe's Wood and Leaf parts). The builder looks at it when it is
  nearer than the ground (like a chest), outlined.
- LMB (hand or pickaxe) fells it: `TerrainTrees.fell` takes it out of its
  ImpostorLod set and its trunk collider, and remembers its trunk cell in
  `felled`, which `_place` skips, so a cell streamed in again leaves it out.
- Survival: the tree's plate cells, Wood parts as `wood` and Leaf parts as
  `leaves` (`Trees.yield_cells`: a 7-brick trunk is 84 wood); what does not
  fit drops where it stood. Creative: nothing given.
- `felled` is saved in the world file (`.inv`, key `felled`: [[x, z], ...]),
  so a felled tree stays gone.

**Recipes.** Workbench 48 wood (it was stone and clay), chest 96 wood at a
workbench, pickaxe 12 wood (the handle) + 24 stone + 12 iron ore.

**Tests.** inventory_probe: the families and their fold, the materials burn,
`yield_cells`, the recipes, felled round trip. `--gate=inventory`: survival,
a tree looked at, LMB, wood and leaves in the inventory, the tree gone from
the set, a wood brick laid from the stack.

## 14. Minecraft's menus (2026-11-25)

The user: model the inventory, crafting, furnace and the other item menus on
Minecraft's, crafting on Bedrock's recipe book; hover an item and its name
pops up beside it; no armour, no off-hand, no player figure. Templates: the
Minecraft wiki's Bedrock screenshots (crafting table with the recipe book,
furnace recipe book, chest).

**The look** (`McStyle`, scripts/inventory/mc_style.gd), drawn from colours,
no textures, scaled by the slot size (one Minecraft pixel = slot / 18):
light grey panel #C6C6C6 with a black edge (corners cut), white top-left and
#555 bottom-right bevel; sunken #8B8B8B slots that touch (dark top-left,
white bottom-right); dark grey #3F3F3F titles; Bedrock's red cell (#C8605D)
for what cannot be made or is lacking; tabs over the panels; the tooltip
near-black with a purple edge, the name white and the lines after it grey
(red for what is missing). `InvSlot.mc` switches a slot to this look (the
HUD hotbar keeps its dark one); `bad` makes it red, `picked` frames it.

**The screen** (`InventoryScreen`, still a MenuScreen so it fits any window):

| Left panel (the recipe book) | Right panel |
|---|---|
| tabs: Construction, Equipment, Items, Nature, Creative (creative only), Farming, All (search) | tabs: recipe book on/off, this screen, X close |
| "Craftable recipes" / "All recipes", a search box, the craftable-only switch | "Crafting" (E), "Crafting Table", "Furnace", or the station's name: the backpack slot (where Minecraft has the armour), the picked recipe's ingredients in a grid (2x2; 3x3 at a crafting table; one column and a flame at a furnace), an arrow, the result |
| the recipes as cells: grey can be made now, red cannot, what can be made first | the note: what it still needs (red), or "Click the result to craft · Shift-click: as many as you can" |
| Creative: every item (search filters); Farming: the farming guide | "Inventory": the worn backpack's slots, then hotbar 2 and hotbar 1 |

At a chest (or a backpack put down) the book is hidden and "Chest" with its
slots stands where the crafting area is. Click a recipe cell to pick it;
click the result to make one, Shift-click to make as many as you can (up to
64 times; what does not fit is thrown in front of the player). The result
goes into the inventory, as Terraria's did (stage 12): the recipes are still
ingredient lists, not shapes, so the grid only shows them.

- **Which recipes a screen shows.** E (no station): every recipe, those
  needing a station not in reach red. A crafting table (RMB on a workbench):
  by hand and the workbench's. Any other station (furnace, compost bin, a
  mod's): only its own. `InventoryScreen.open_station(id)`; mine_world's
  `open_chest` calls it for a station.
- **Recipe tabs.** A recipe's `category` (in its table), else its output
  item's `category`, else by kind: blocks construction; tools, weapons,
  buckets, backpacks equipment; seeds, crops, fluids nature; the rest items
  (`RecipeBook.category_of_item`).
- **The tooltip.** Over any slot, recipe cell, ingredient, result, tab or
  the switch: `InventoryScreen.tip_lines(control)`, placed right of and above
  the mouse, kept on screen; hidden while a stack is held (Minecraft's).
  An item's `description` shows as grey lines under its name.
- **Kept between openings:** the book shown or hidden, the switch
  (`book_open`, `craftable_only`, static).
- The search box takes typing only after it is clicked; Escape or Enter
  leaves it, a click elsewhere too. Otherwise every key is the screen's (E,
  Tab, Escape, Q, 1-9 as before).

**No off-hand slots in the screen** (the user: no armour, off-hand or player
figure there). The off-hand itself came back the same day in play (round
four, section 4, decided with the user in another chat): it is filled
Minecraft's way -- C over a slot in the screen swaps it with the active
off-hand slot, B with the quick slot (`Inventory.swap_slots`) -- and the HUD
shows both. Crafting and pickups still never put anything there by themselves.

**Not done (Minecraft has it):** 3x3 shapes, the result onto the cursor.
Furnaces smelt over time since section 15.

**Tests.** inventory_probe: the off-hand checks pruned (no off-hand), an old
save's off-hand pickaxe moved into the inventory. `--gate=inventory`: the
farming top-ups cleared first (they filled the slots the checks use); the
recipe book's tabs; the name beside the mouse; Gravel picked in the book and
made by a click on the result; Sandstone red without a workbench; the
craftable-only switch; at the workbench Sandstone made the same way; the
furnace screen lists only furnace recipes. Pictures: user://dev/inv_tooltip,
inv_craft, inv_craftable_only, inv_workbench, inv_furnace, inv_chest.

## 15. Furnaces that smelt (2026-11-25)

The user: yes, furnaces smelt over time with fuel, like Minecraft.

**The rules** (`Smelting`, scripts/inventory/smelting.gd; tables in packs,
`content/<pack>/data/smelting/*.json`, so a mod adds what smelts and burns):

| Smelts | Takes | Gives | Time |
|---|---|---|---|
| iron ore | 12 cells (one 2x2 brick) | 1 iron ingot | 5 s |
| gold ore | 12 cells | 1 gold ingot | 5 s |
| sand | 12 cells | 12 cells of glass | 5 s |

| Fuel | Takes | Burns |
|---|---|---|
| coal ore | 12 cells | 40 s (8 smelts) |
| wood | 12 cells | 7.5 s |
| leaves | 12 cells | 2.5 s |

As in Minecraft: the fire takes its fuel at once when lit and only lights if
there is something it can smelt; it burns on when the input runs out; a smelt
left half done when the fire goes out starts again; a full output (or another
item there) stops it. Times are a little shorter than Minecraft's (10 s a
smelt) because the mine world's ore comes by the brick.

**A furnace is a placed block with slots.** An item with `"smelter": true`
(the furnace) is placed by MineChests like a station, with
`Smelting.SLOTS` slots (input, fuel, output) and a state {burn, burn_max,
cook, t} in the world time. `MineChests.settle_furnaces` brings every
furnace up to `world_time` every 0.25 s -- with the screen shut too -- and
`Smelting.settle` catches up any gap at once (a load, a long absence: like
MineFarming's settle). Saved with the world (`furnace` beside its slots).
Broken, its contents drop.

**The screen** (RMB on it): Minecraft's furnace -- the input over the flame
over the fuel, the arrow (white as the smelt goes), the output -- with
Bedrock's furnace book on the left: what smelts, grey if you carry enough,
red if not; a click puts all you carry of it on top (`Inventory.fill_slot`).
Slot rules (`Inventory.chest_rules = "furnace"`): the fuel slot takes only
fuels, the output takes nothing (a held stack of the same clicked on it
takes from it), shift-click sends what smelts on top and what only burns
below. The flame burns down as the fuel goes.

**Recipes moved onto ingots.** The furnace no longer crafts; what was made
"at a furnace" is made at a workbench from ingots: bucket 2 iron ingots,
source bucket a bucket + 1 gold ingot, grenades 12 coal + 1 iron ingot,
mega pickaxe (diamond ore, unchanged) at a workbench; and pickaxe 1 iron
ingot (was 12 ore), medium backpack 3 iron ingots (36 ore), large backpack
3 gold ingots (36 ore), scythe and watering can 2 iron ingots (18 ore;
recipes/farming.json). One ingot is one brick of ore, so the costs are
about the same as before.

**Tests.** inventory_probe `_smelting`: the tables, a fire lit and a smelt
part done, two out in 13 s, burnt out with nothing left, no fuel nothing,
a full output stopping an hour's catch-up, the slot rules, shift-click
routing, the book's fill, a placed furnace saved and back with its fire.
`--gate=inventory` `_gate_furnace`: a furnace put down, RMB opens it, the
book's Iron ingot fills the input, the coal clicked below, the world's time
moved on (half a smelt shown on the arrow, then 2 ingots), the ingots
clicked out, then shut: a minute on gives 3 gold ingots; saved with its
fire. Pictures: user://dev/inv_furnace, inv_furnace_done.
