# Tactics Casebook

How the enemy chooses what to do, authored as odds rather than code.

- **The page:** `tactics_casebook.html` is the source of the hosted Tactics Casebook
  (claude.ai artifact, private to the owner). Twelve broad *moments* (contact, lost the
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
  punch, back off, turn the open side away) whenever its pilot has given it no order.
  `tools/mech_fight_probe.gd` checks it.

To update after changing the page: copy the page source here, save the settings
here, run the exporter, run the probe, commit all of it together.

Chance of a move = its weight in the moment × each true fact × each amount × memory
× teamwork, scaled so the moves add to 1. A fact set to "95%" gives its move 95% of
the pick.
