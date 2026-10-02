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

- **Soldiers using it:** run with `-- --tactics=book` (off by default; the scripted
  policy runs otherwise). `TacticsSense` reads the moment, facts and amounts from the
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

To update after changing the page: copy the page source here, save the settings
here, run the exporter, run the probe, commit all of it together.

Chance of a move = its weight in the moment × each true fact × each amount × memory
× teamwork, scaled so the moves add to 1. A fact set to "95%" gives its move 95% of
the pick.
