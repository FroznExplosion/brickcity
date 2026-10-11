# Tactics Casebook

How the enemy chooses what to do, authored as odds rather than code.

- **The page:** `tactics_casebook.html` is the source of the hosted Tactics Casebook
  (claude.ai artifact, private to the owner). Fifteen broad *moments* (contact, lost the
  player, close quarters...), 38 *moves*, *facts* that are true or not (inside a
  building, player above us, within melee reach, we're a melee fighter), *amounts* with
  curves (distance, cover, health, magazine, squad, player health), *combos* (grenade
  first, mark while firing, breach then flash), teamwork limits and memory. Your first
  casebook's 30 specific cases are kept as checks on the page.
- **Your settings:** `settings/<collection>/<id>.json`, saved from the page's storage.
  Only what you changed is stored; everything else is the page's suggestion.
- **The book:** `node tools/tactics_export.js` runs the page's own model code over
  the settings and writes `data/ai/tactics_book.json`: effective values plus
  `golden` cases with the page's exact odds.
- **In the game:** `TacticsBook` (`scripts/ai/tactics/tactics_book.gd`) reads the book
  and gives the same odds, picks, extras and squad plans.
  `tools/tactics_book_probe.gd` checks it against the golden cases and checks the
  behaviour asked for (melee in reach ~95%, shoot then grenade face to face, grenade
  first at a player behind cover, no melee from far unless a melee fighter).

- **Soldiers using it:** the casebook is the default policy; `-- --tactics=scripted`
  runs the old scripted one. `TacticsSense` reads the moment, facts and amounts from the
  world at each engage decision -- distance, both sides' cover (bricks across the
  lines to head and chest), above/below, within reach, inside (a roof overhead), the
  player unaware or reloading or in a mech, alone, other squads near, health,
  magazine, squad strength, the player's health. `BookCombatPolicy` draws the book's
  plan and maps its move to one of the eight tactics the soldier tree can carry out
  (rush and melee added, CombatPolicy spec 2); grenades are thrown (`Grenade`: lobbed,
  a danger zone for 1.2 s, then up to 120 damage within 4 m, none behind bricks, and a
  small blast in the bricks; two per soldier, never onto a friend); call for help and
  mark are said aloud. `tools/ai_moves_probe.gd` checks grenade, melee and rush. A move the game can't do yet (grenade,
  smoke, breach...) is counted as *wanted* and the draw is made again among the
  doable moves. Every logged decision carries the plan (`--log-decisions=PATH`).
  `tools/tactics_sense_probe.gd` checks the readings and a fight.

- **The player in a building** (2026-10-11): the moment "Player is in a building" is read
  when the player is under a roof and the soldier is not (before everything but close
  quarters and losing). `TacticsSense.ways_in` looks at the ways in by their route costs --
  the soldier's walking map and a breaching one (`AIServices.foot_breach_nav`, a wall a
  way through at 4 m a column), both through the hierarchy, kept 4 s for soldiers about as
  far off -- and sets one of the facts *A way in close by* (the walk not much more than
  straight there), *The way in is a long way round* (twice and more), *No way in on foot*,
  and *Breaching in is much the shorter*. Health, ammo and explosives come in through the
  amounts and facts the book already has. The moves are carried out: *Sweep* and *Flash,
  then go in* push in by the door; *Make their own way in* pushes in on the breaching map,
  and where its path goes into bricks the soldier plants a charge (2 s) and blows it
  (`Soldier.breach_way`, through `on_breach`); *Guard the ways out* and *Wait them out* are
  now built -- cover facing the door the player would come out of (where the walk goes under
  the roof, `Soldier.watch_point`). `tools/inside_probe.gd` (8) checks the readings, the
  odds and a soldier blowing its way in.

- **What happened, counted:** while the city runs (not in a gate), `TacticsTally`
  counts every book decision by moment -- moves taken, moves asked for that could
  not be done, extras, the facts that held, the player's cover and distance band,
  and each move's judged outcome -- into `user://tactics_tally.json`
  (`%APPDATA%\Godot\app_userdata\Brickcity\`), added to across runs. Delete the
  file to start again. The page's "In the game" tab draws it: paste the file there,
  or have Claude upload it (the page's storage, `tally/latest`).

- **The roster of types:** the page's Roster tab builds each enemy or ally type as a
  recipe (body, size, class and grade, attack, role, mods, phases; `Docs/AIRoster.md`).
  The exporter writes `data/ai/roster.json` with everything worked out from each
  recipe; `Roster` (`scripts/ai/roster/roster.gd`) reads it, and `UnitCatalog` takes
  each unit's name, weapon, points and health from its recipe -- so a recipe changed
  on the page changes the unit in the game after an export. A recipe's attack, role,
  size and phases are the soldier's too (`Soldier.set_type`): a melee type or a bomber
  holds no gun, fodder stays on the cheap brain, a large body walks the large map, and a
  phase changes it mid-fight. A flyer is a type too (`Flyer.set_type`): the casebook's
  move becomes its flight mode, and a bomber on a flyer dives and goes off.
  `tools/roster_probe.gd`, `tools/roster_field_probe.gd`, `tools/roster_types_probe.gd`
  and `tools/roster_air_probe.gd` check it.

- **Mechs:** a mech recipe carries its class's shield, armour, health and doors
  (`derived.mech`); `Mech.set_type` applies them through `MechLayers`, which is how a
  mech is killed (`Docs/AIRoster.md` 4.2; `tools/mech_layers_probe.gd`).

- **A mech's moves:** the moment `mech_fight` and the facts "Mech against mech" are a
  mech's own page of the casebook. `TacticsSense.read_mech` reads them,
  `BookCombatPolicy.decide_mech` rolls, and `MechBrain` does it (stand off, close in,
  punch, back off, turn the open side away, bail out) whenever its pilot has given it
  no order. `tools/mech_fight_probe.gd` checks it; `tools/mech_mount_probe.gd` checks
  bailing out. With somebody riding it the moment is "A rider on us" (`mech_ridden`:
  electric smoke, scrape it off, crush it, or fight on for the escort), with the facts of
  its own group (smoke ready, somewhere low near, a wall behind, our soldiers near);
  `TacticsSense.read_ridden`, `BookCombatPolicy.decide_ridden`, `tools/mech_rodeo_probe.gd`.
  The Roster tab's **Boarder** has the rodeo mod: it climbs a player's mech
  (`Soldier.rodeo`).

To update after changing the page: copy the page source here, save the settings
here, run the exporter, run the probe, commit all of it together.

Chance of a move = its weight in the moment × each true fact × each amount × memory
× teamwork, scaled so the moves add to 1. A fact set to "95%" gives its move 95% of
the pick.
