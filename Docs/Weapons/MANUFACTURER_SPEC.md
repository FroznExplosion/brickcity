# Manufacturer, Parts & Merge Spec

**Engine:** Godot 4.6 · **Genre:** FPS rogue-lite. **Scope:** on-foot handheld guns,
ordnance and shields (space cut).
**Pairs with:** [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) (rarity ladder,
score, effect stacking), [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md),
[WEAPONS_SPEC.md](WEAPONS_SPEC.md), [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md),
[PROGRESSION_SPEC.md](PROGRESSION_SPEC.md), [META_SPEC.md](META_SPEC.md).

BL4-style model: a gun has a **base brand** (chassis/feel) and rolls **licensed parts**
from any brand on rarer versions. Parts each grant an **effect**. Two sources of the same
effect **upgrade** it; two *different* synergy effects **merge** into an extra bonus.

> **Rewritten.** This spec previously described a separate "gun mod / power-up" system in
> §8 that granted nothing and only amplified. That turned out to be the same object as a
> weapon ability seen from the other side, and keeping both produced two half-rules. §8 is
> now a pointer to the single stacking rule in QUALITY_NAMING §11. Sections that stated
> rarity is "behaviour, not raw power" have also been corrected — the shipping rarity
> ladder makes rarity worth up to 5× within a tier.

---

## 0. Design pillars

1. **Effects are the atoms; brands are their home and native feel.** Everything mechanical
   is an *effect* delivered by a *part*. A brand is a family of effects plus a chassis
   feel.
2. **Parts roll freely on guns (BL4).** Rarer guns roll more part slots and better parts.
   Parts function independently.
3. **One currency for effects.** A gun part, an equipped ability and a legendary's signature
   part all produce the same thing: an entry in the gun's effect list. Nothing downstream
   can tell them apart, and that is what makes stacking (§8) a single rule.
4. **Rarity is BOTH power and behaviour.** Higher rarity means more effects *and* more raw
   damage — Mythic is 5× a Common within a tier (QUALITY_NAMING §1). The old claim that
   rarity was "mostly behaviour, ~40% spread" is superseded.
5. **Percentages, never flat.** All effect magnitudes scale off the receiver's baseline.
6. **Fire-rate-scaled procs and mass-scaled stagger** — the melt guard and stunlock guard
   (§7). Any "chance on shot" or knockback obeys these.
7. **Compatibility is data.** Parts declare slots and compat tags; the generator only
   assembles valid combos (§4).

---

## 1. Brands

`Manufacturer` (`Resource`):
- `id`, `display_name`, `color`
- `chassis_capable: bool` — true = can be a gun's base brand; false = **part-only**.
- `stat_modifiers`, `recoil_pattern`, `element_bias`
- `native_effect: StringName` — the signature effect its *chassis* guns get for free.
- `min_tier: int`, `drop_weight: float` — availability gating. High `min_tier` + low weight
  = an exotic late brand. One brand can be common-early, another Tier-IV-only.

### Chassis brands (6)
| id | name | pillar | native effect (free on its guns) |
|---|---|---|---|
| `cowboy`    | Cowboy    | crit / precision kinetic | crit → ricochet |
| `elemental` | Elemental | status / tech | high `element_chance` |
| `rapid`     | Rapid     | fire rate / volume | trigger-hold fire-rate ramp |
| `boomer`    | Boomer    | explosive / splash | shots deal minor splash |
| `leech`     | Leech     | health↔ammo↔dmg economy | overdraw (fire past empty mag → health cost) |
| `charge`    | Charge    | small-mag power-shots | every Nth shot is a power shot |

### Part-only brands
| id | name | effects | availability |
|---|---|---|---|
| `defensive` | Defensive | shield module, overshield-on-kill, brace | normal |
| `seeker`    | Seeker    | homing rounds | **rare, purpose-built strong** (low weight, or Tier III+) |

---

## 2. Parts & effects

**Implemented as `GunPartDef`** (`scripts/guns/gun_part_def.gd`). The shipping fields:

| field | purpose |
|---|---|
| `id`, `display_name`, `slot`, `scene` | identity + the GLB this part instantiates |
| `manufacturer`, `weight` | brand, and relative pick weight inside its slot pool |
| `min_rarity` / `max_rarity` | **hard legality gate** — the part may never appear outside this band |
| `native_rarity` | the tier the part is *authored for*; what the generator aims at (QUALITY_NAMING §2.1) |
| `exclusive_to` | non-empty = belongs to one legendary's recipe and is excluded from every world pool |
| `stat_add` / `stat_mult` | stat payloads, applied additive-then-multiplicative |
| `effect_id`, `effect_params` | the mechanical effect this part carries |
| `effect_tags` / `effect_incompatible_tags` | compat gating (§4) |
| `effect_min_rarity` | effect-only gate, separate from the part's own band |
| `tags`, `name_fragment` | flavour tags; the word this part contributes to the gun's name |

> **`native_rarity` vs `min_rarity` is the distinction that matters.** The band says where
> a part is *legal*; `native_rarity` says where it *belongs*. The generator aims at a
> rolled offset from the gun's own rarity and the band overrules it — that gap is what
> produces the grade word (QUALITY_NAMING §2).

> **Authoring contract:** BODY `name_fragment`s are **nouns**, BARREL `name_fragment`s are
> **adjectives** (QUALITY_NAMING §3). Swapping them produces "AK47 Silenced".

### Effect catalog (by brand)
| brand | effect_id | what it does |
|---|---|---|
| cowboy | `ricochet` | crit fires a bouncing round to nearest enemy |
| elemental | `element` | applies the gun's element (base) |
| elemental | `double_element` | gun carries 2 elements; **manual button-press** switch (needs a secondary-fire slot) |
| rapid | `fire_ramp` | trigger-hold ramps fire rate |
| rapid | `extra_round` | **chance to fire >1 bullet; the extra is FREE.** Higher rarity → more. On shotguns → adds projectiles (§5) |
| rapid | `hyper_burst` | an extreme-fast burst every few shots or at random. Higher rarity → more shots per burst |
| boomer | `explosive` | rounds deal splash on impact |
| boomer | `cluster` | killing blow → delayed secondary blast |
| leech | `overdraw` | fire past empty mag → keep firing, drains health |
| leech | `lifesteal` | hits/kills heal |
| leech | `bayonet` | **universal part (any gun): enables melee + melee dmg.** Leech-matched: melee also **heals** |
| charge | `burst` | fires in bursts |
| charge | `power_shot` | every Nth shot is a charged power shot |
| defensive | `shield_module` | adds a regenerating shield layer to the wielder |
| defensive | `brace` | ADS / stand-still → damage reduction |
| seeker | `homing` | rounds curve toward enemies (rare, strong) |

> The classic Charge feel (small mag → harder shots) is the **chassis native**; `burst` and
> `power_shot` are separable licensed parts so they can appear on any gun.

### 2.1 Effects are currently LABELS

`GunEffects.collect()` gathers `effect_id`s and the UI prints them. **No dispatcher
exists.** Nothing in the list above changes behaviour at runtime yet, and neither does any
upgraded (`_up`) variant. This is the single largest gap between the loot *reading* well
and *playing* well — see §10.

---

## 3. Part slots on a gun

**Implemented as `GunPartDef.Slot`.** Assembly is recursive over `socket_*` node names, so
a part can both attach and receive (a barrel takes a muzzle).

| slot | holds | count |
|---|---|---|
| `BODY` | the receiver / base chassis. Owns reload animation | always exactly 1 |
| `BARREL` | fire behaviour + shot presentation + `element_ratio` | 1 |
| `GRIP` | handling | 1 |
| `MAGAZINE` | capacity / reload economy | 1 |
| `STOCK` | recoil / stability | 0–1 |
| `SIGHT` | optics | 0–1 |
| `MUZZLE` | attaches to a socket **on the barrel** | 0–1 |
| `UNDERBARREL` | attached device (shield module, launcher, deployable) | 0–1 |

Optional-slot fill chance rises with rarity, so Commons are sparse and Legendaries are
dense. Slot *weight* for quality purposes is separate and lives in QUALITY_NAMING §2.3
(BODY/BARREL count double; SIGHT/MUZZLE/UNDERBARREL count half).

> **Slots the old spec listed that do not exist:** `core` (now `BODY`), `secondary_fire`
> and `melee`. Alt-fire and bayonet are still wanted; they need either new enum entries or
> to ride on `UNDERBARREL`. **Open** — see §10.

---

## 3.5 Effect economy

### Free native effect
A gun's base brand grants **one** of its signature effects for free, at any rarity. A
Cowboy gun always ricochets; an Elemental gun always applies its element.

### How many effects a gun carries
**Emergent, not budgeted.** A gun's effects are simply whatever its parts carry, gated by
each part's `effect_min_rarity`. Because higher rarity fills more slots *and* draws
higher-tier parts, effect count rises with rarity without a separate cap:

| rarity | typical effect count |
|---|---|
| common | 0–1 (its parts are below the effect gate) |
| uncommon | 1 |
| rare | 1–2 |
| unique | 2–3 |
| legendary | 3–4 (one is its authored signature) |
| mythic | 3–5 |

> **This replaces the old fixed "bonus slot" table** driven by `Rarity.part_count_bonus`.
> That field still exists on `Rarity` and is **unused** — the slot-fill chance in
> `GunGenerator.OPTIONAL_SLOTS` does the same job with fewer moving parts. Delete the
> field or wire it; do not leave two systems claiming the same job.

### Brand-match magnitude
An effect's rolled magnitude scales by whether it matches the gun's **base brand**:

- **Own brand** (including the free native): `×1.15`
- **Cross brand** (licensed onto another manufacturer): `×0.85`

Brand-pure builds hit the sweet spot; mixed builds trade a little magnitude for
flexibility. This is **separate from stacking** (§8), which changes the effect's tier
rather than its magnitude.

---

## 4. Compatibility gating

The generator assembles only valid combos:

- **One part per slot.**
- `effect_incompatible_tags` — a part refuses to co-roll with a tagged conflict. The check
  is **symmetric**: neither side may declare a tag the other carries. Parts with no effect
  are always compatible.
- `min_rarity` / `max_rarity` — the hard band, which always beats the offset roll (§2).
- `effect_min_rarity` — gates the *effect* independently of the part.
- `exclusive_to` — legendary parts never enter a world pool.

Generator order: pick BODY (which sets the brand) → required slots → optional slots by
chance → for each, roll a rarity offset, filter by effect compatibility, weighted-pick.
If a target tier has no legal part, the target walks one step toward the gun's own rarity
and retries.

> ⚠ **`effect_min_rarity` is checked against the GUN's rarity, not the part's.** A
> higher-tier part carrying a gated effect on a lower-tier gun is placed, contributes to
> the grade word, and its effect is silently dropped. Gate on `part.native_rarity` instead.
> Known bug, logged in `iteration_summary.md`.

---

## 5. Weapon-type-specific part behavior

One `effect_id`, per-class magnitudes. Examples:

- `extra_round` on **rifle/pistol** → chance of +1 free bullet (rarity → +2, +3…).
- `extra_round` on **shotgun** → adds free projectiles to the spread, not a second pull.
- `power_shot` on **sniper** → huge single-shot amp; on **SMG** → smaller, more frequent.

Effects that make no sense on a class are excluded via compat tags.

### Ordnance
Ordnance (`WeaponClass.is_ordnance`: grenade, rocket launcher, grenade launcher, mine
layer, drone) runs the **identical** part, effect, merge and score pipeline. It is
cooldown-gated rather than magazine-gated, so `base_fire_rate = 1/cooldown` and DPS parity
holds — see QUALITY_NAMING §10.

Effects whose text says "per shot" need a per-class reading on ordnance, where one "shot"
is one 4-metre blast. `extra_round` on a rocket launcher is a second rocket, not a second
pellet. **Open** — the params exist, the values do not.

---

## 6. Merges (synergy bonuses)

`MergeRule` (`Resource`): `effect_a` + `effect_b` → **bonus effect** + `params` + trigger
(`always` | `conditional` | `chance`). **Merges are additive** — both base effects keep
working; the merge is extra. Auto-detected against the rule table.

**A merge needs two DIFFERENT effects. Two of the SAME effect is a stack (§8), not a
merge.** They are separate systems with separate rewards, and the distinction is what
stops "I rolled ricochet twice" from silently doing nothing.

### 2-part merges
| parts | merge bonus | trigger |
|---|---|---|
| ricochet + explosive | explosion on **both** the direct hit AND the ricochet target | always |
| ricochet + element | **higher DoT chance** on the ricochet shot | always |
| ricochet + power_shot | power shot **guarantees a ricochet even without a crit** | always |
| burst + power_shot | **last round of the burst = guaranteed power shot** | conditional |
| power_shot + explosive | power shots get **bigger splash + bonus dmg** | conditional |
| extra_round + double_element | the free extra bullet fires the **other element** | always |
| hyper_burst + double_element | burst **alternates elements per shot** (rarity → more shots) | conditional |
| double_element + explosive | explosion procs **both elements** | always |
| bayonet + power_shot | **charged melee lunge** | conditional |
| bayonet + explosive | **explosive melee** (stab detonates) | always |
| bayonet + lifesteal/overdraw | **blood blade** — melee kills refund health + ammo | always |
| overdraw + power_shot | firing on health → **every shot auto-charges** (desperation mode) | conditional |
| overdraw + lifesteal | blood spent overdrawing is **recovered by lifesteal** | always |
| shield_module + overdraw | overdraw drains **shield first, then health** | always |
| fire_ramp + extra_round | at max ramp, extra-round chance/count increases | conditional |
| cluster + element | every **bomblet applies the element** | always |
| homing + extra_round | extra bullets **home to separate targets** | always |

### Legendary-only special part
`grenade_drop` — Legendary guns only, very rare: killing with a **crit or a ricochet shot**
drops a live grenade at the victim's feet.

### 3-part merges (authored, not rollable)
A few exist **only** on specific named legendaries, layered on that legendary's own effect.
Example ceiling: `burst + power_shot + explosive` → an explosive guaranteed power finisher
with wide splash. Supported in data; hand-authored.

> **Merge detection runs on the STACKED effect list** (§8) and normalises ids to their
> base form first, so `ricochet_up` still satisfies a rule asking for `ricochet`. Without
> that, upgrading an effect would silently break every merge it takes part in — turning
> the stacking reward into a penalty. Asserted by probe.

---

## 7. Balance guards

### 7.1 Fire-rate-scaled proc (melt guard)
```
effective_chance = base_proc_per_second / gun.fire_rate    # clamp [floor, 1.0]
```
A 6/s and a 20/s gun proc at the same rate *per second*, not per bullet.

This is the same class of problem the **DPS spread budget** solves for raw stats
(QUALITY_NAMING §4.3): anything that multiplies into damage-per-second has to be budgeted
against fire rate, or fast guns win twice. A proc that ignored this would reintroduce the
bug that budget exists to prevent.

**Ordnance note:** a 0.25/s rocket launcher would get a proc chance of `base × 4` under
this formula. Clamp at 1.0 and consider a separate per-use rate for `is_ordnance`.

### 7.2 Mass-scaled stagger (stunlock guard)
```
applied_stagger = base_stagger * (reference_mass / enemy_mass)   # clamp
```
Light mobs fly and interrupt; heavies barely flinch.

---

## 8. Effect stacking — supersedes the old "gun mods / power-ups"

**There is no separate power-up system.** This section previously described a `PowerUp`
resource that amplified effects a gun already carried but "did not grant new effects,"
while a weapon ability granted effects it lacked. Those are one object seen from two
sides, and keeping them apart produced two half-rules that disagreed at the overlap.

The single rule, specified in full at
[QUALITY_NAMING §11](GUN_QUALITY_NAMING_SPEC.md):

> **Two sources of the same effect upgrade it. The sources are interchangeable.**

| source A | source B | result |
|---|---|---|
| gun part | gun part (the gun rolled it twice) | upgraded |
| gun part | equipped ability | upgraded |
| equipped ability | equipped ability | upgraded |
| — | one source only | base strength |

A third source adds nothing — the cap is deliberate.

Implementation is `GunEffects.stack()`, which counts sources. Upgrades are an id suffix
(`ricochet` → `ricochet_up`) so effect lists stay flat arrays that serialise unchanged, and
`WeaponAbility.base_id()` recovers the original so a handler dispatches once and reads the
upgrade as a magnitude.

**Equipped abilities are a PLAYER property** — never written onto a gun's recipe. Swapping
guns re-applies instantly; swapping abilities never edits a stored weapon.

Shipping abilities: `ricochet` · `explosive` · `lifesteal` · `fire_ramp` · `homing` ·
`power_shot` · `element` · `extra_round`. **3 slots.**

---

## 9. Equipped slots & swapping

### Weapon slots
- The player earns more equipped **gun** slots through the run/meta, **max 4**.
- **1 ordnance slot** (§5) — cooldown-gated, its own input.
- **1 shield slot** (QUALITY_NAMING §12) — passive; contributes a `shield` `DefenseLayer`
  above `health` in the wielder's `HealthPool`.
- **3 ability slots** (§8).

### Grouping (player choice in inventory)
One group or two:

- **One group:** the swap button cycles all equipped guns.
- **Two groups (2 + 2):** *press* swap toggles within the current group; *hold* swap
  switches groups. **Group memory:** switching back returns to the last-held gun of that
  group.

`Loadout` tracks `groups`, `active_group`, `last_active[group]`. Swap distinguishes press
from hold.

---

## 10. Build order & current status

| # | step | status |
|---|---|---|
| 1 | `Manufacturer` resource + 6 chassis + 2 part-only brands | **not built** — brands exist only as `StringName`s on parts |
| 2 | `GunPartDef` + slot model + compat gating (§2–§4) | ✅ built |
| 3 | Rarity offset roll, grade word, score (QUALITY_NAMING §2–§4) | ✅ built |
| 4 | Authored legendaries + `exclusive_to` parts (§6) | ✅ built — 5 shipping |
| 5 | Effect **stacking** (§8) | ✅ built |
| 6 | Ordnance classes (§5) | ✅ built — 5 shipping |
| 7 | Shields (QUALITY_NAMING §12) | ⚠ **partial** — generator + layer only; no card, equip, pickup or recharge |
| 8 | **Effect dispatch bus** (`on_hit`, `on_crit`, `on_kill`, `on_reload_empty`, `on_ads`, `on_layer_stripped`, `on_status_proc`, `on_alt_fire`, `on_melee`) | ❌ **not built — the biggest gap** |
| 9 | One effect end to end (ricochet) → prove part → effect → signal | ❌ blocked on 8 |
| 10 | Upgraded (`_up`) magnitudes | ❌ blocked on 8 |
| 11 | Fire-rate proc + mass-stagger helpers (§7) | ❌ not built |
| 12 | `MergeRule` table + detection | ✅ built — **23 shipping rules**, detection normalises upgraded ids |
| 13 | Brand-match magnitude (§3.5) | ❌ not built |
| 14 | `Loadout` slots + grouping + press/hold swap (§9) | ❌ not built |

### Open questions

1. **`secondary_fire` and `melee` slots do not exist** in `GunPartDef.Slot`. `double_element`
   and `bayonet` both need them. Add enum entries, or route them through `UNDERBARREL`.
3. **`effect_min_rarity` gates on the gun's rarity, not the part's** (§4), so a good part's
   effect can vanish on a lesser gun while still counting toward its grade word.
4. **`Rarity.part_count_bonus` is unused** and duplicates what optional-slot fill chance
   already does (§3.5). Delete it or wire it.
5. **Ordnance proc rates** need their own per-use scale; the §7.1 formula rewards a 0.25/s
   launcher four-fold.
