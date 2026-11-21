# Inventory: two hotbars, off-hand, backpack, chests (mine world)

Ported from zylanntest's `game/inventory/` (its README is the design this
follows), shaped to brickcity: content packs, MenuScreen, no renderer
read-backs, and the arsenal left alone.

Status: all five stages built (branch `mine-inventory`). What is left is under "Later".

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

Later: backpacks (bigger storage), survival toggle in the world menu,
crafting (zylanntest's recipe tools), saving the inventory per character
instead of per world, a gun item in a hotbar slot, multiplayer authority.

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
