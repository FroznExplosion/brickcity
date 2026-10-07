// Turns the Tactics Casebook (Docs/Tactics/tactics_casebook.html, the page the
// enemy's choices are authored on) plus the settings saved from it
// (Docs/Tactics/settings/<collection>/<id>.json) into the book the game reads:
// data/ai/tactics_book.json -- and the roster of types (the page's Roster tab,
// Docs/AIRoster.md) into data/ai/roster.json.
//
//     node tools/tactics_export.js
//
// The page's own model code is run here, so the book holds the EFFECTIVE values
// (your settings over the page's suggestions) and the game needs no defaults. It
// also writes `golden`: cases with the exact odds the page gives, which
// tools/tactics_book_probe.gd checks the game's TacticsBook against.

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const pagePath = path.join(root, "Docs", "Tactics", "tactics_casebook.html");
const settingsDir = path.join(root, "Docs", "Tactics", "settings");
const outPath = path.join(root, "data", "ai", "tactics_book.json");
const rosterPath = path.join(root, "data", "ai", "roster.json");

const html = fs.readFileSync(pagePath, "utf8");
const marker = "   STORAGE";
if (!html.includes(marker)) throw new Error("page layout changed: no STORAGE marker");
const modelSrc = html.split("<script>")[1].split(marker)[0].replace(/\/\* =+\s*$/, "");

// Settings saved from the page, by collection.
const settings = {};
for (const coll of ["sit", "factor", "action", "memory", "rules", "actx", "sitx", "combo", "scale", "recipe"]) {
  settings[coll] = {};
  const dir = path.join(settingsDir, coll);
  if (!fs.existsSync(dir)) continue;
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith(".json")))
    settings[coll][f.slice(0, -5)] = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
}

const M = new Function("SETTINGS", modelSrc + `
Object.assign(S, SETTINGS);
return {S, MULT, ALWAYS, ALWAYS_SHARE, SLOTS, SCALES, SITS, FACTORS, RULES, MEMDEF,
  allSits, allActs, sitActs, baseW, isNever, implied, sitScale, modStep, curves, teamMax, teamPairs, needs,
  memStep, comboOf, maxExtra, compute, extrasFor,
  allRecipes, rDerive, R_BODIES, R_SIZES, R_CLASSES, R_GRADES, R_LAYERS, R_MECH, R_MECH_GRADE, R_MECH_FIXED, R_ATTACKS, R_ROLES, R_MODS, R_TRIGGERS};`)(settings);

const book = {version: 1, source: "Docs/Tactics/tactics_casebook.html", mult: M.MULT, always: M.ALWAYS,
  always_share: M.ALWAYS_SHARE, max_extra: M.maxExtra(), slots: M.SLOTS.map(s => s[0]),
  moves: {}, facts: {}, amounts: {}, moments: {}, memory: {}, rules: {}, golden: []};

for (const a of M.allActs()) {
  const c = M.comboOf(a.id);
  book.moves[a.id] = {label: a.l, group: a.g, built: a.b, max: M.teamMax(a.id), pairs: M.teamPairs(a.id),
    needs: M.needs(a.id), combos: {first: c.first, with: c.with, then: c.then}};
}
for (const f of M.FACTORS) {
  const mods = {};
  for (const a of Object.keys(book.moves)) { const st = M.modStep(f.id, a); if (st !== 3) mods[a] = st; }
  book.facts[f.id] = {label: f.l, group: f.g, mods};
}
for (const x of M.SCALES)
  book.amounts[x.id] = {label: x.l, stops: x.stops, log: !!x.log, discrete: !!x.disc, default: x.def, curves: M.curves(x.id)};
for (const s of M.allSits()) {
  const weights = {};
  for (const a of M.sitActs(s.id)) weights[a] = M.baseW(s.id, a);
  book.moments[s.id] = {label: s.l, who: s.who || "", implied: M.implied(s.id), amounts: M.sitScale(s.id),
    weights, never: M.sitActs(s.id).filter(a => M.isNever(s.id, a))};
}
for (const [k] of M.MEMDEF) book.memory[k] = M.memStep(k);
for (const r of M.RULES) { const v = M.S.rules[r.id] || {}; book.rules[r.id] = {label: r.t, strength: v.strength ?? null, notes: v.notes || ""}; }

// Golden cases: a fixed pseudo-random spread over moments, facts, amounts, memory and squadmates.
let seed = 12345;
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
const choose = xs => xs[Math.floor(rnd() * xs.length)];
const momentIds = Object.keys(book.moments), factIds = Object.keys(book.facts), moveIds = Object.keys(book.moves);
const kinds = factIds.filter(f => book.facts[f].group === "kind");
for (let i = 0; i < 60; i++) {
  const moment = momentIds[i % momentIds.length];
  const facts = [];
  const nf = Math.floor(rnd() * 5);
  for (let k = 0; k < nf; k++) { const f = choose(factIds); if (!facts.includes(f) && !(kinds.includes(f) && facts.some(g => kinds.includes(g)))) facts.push(f); }
  if (i % 7 === 3) facts.push("p_reach");
  const amounts = {};
  for (const x of M.SCALES) if (rnd() < 0.5)
    amounts[x.id] = x.disc ? Math.floor(rnd() * x.stops.length) : Math.round((x.log ? Math.exp(Math.log(1) + rnd() * Math.log(200)) : rnd() * 100) * 10) / 10;
  const mem = rnd() < 0.3 ? {last: choose(moveIds), outcome: choose(["", "failed", "worked"])} : {};
  const mates = []; const nm = Math.floor(rnd() * 3); for (let k = 0; k < nm; k++) mates.push(choose(moveIds));
  const ticked = new Set(facts.concat(M.implied(moment)));
  ticked.sc = Object.assign(M.sitScale(moment), amounts);
  const rows = M.compute(moment, ticked, mem, mates);
  const expect = {}; for (const r of rows) expect[r.a] = r.p;
  const top = rows.slice().sort((a, b) => b.p - a.p)[0];
  const extras = {};
  if (top && top.p > 0) for (const x of M.extrasFor(moment, ticked, top.a, mates)) extras[x.slot + ":" + x.a] = x.p;
  book.golden.push({moment, facts, amounts, mem, mates, expect, main: top ? top.a : "", extras});
}

// The roster: each recipe with everything worked out from it, by the page's own code -- so
// the game derives nothing itself (Roster, scripts/ai/roster/roster.gd).
const roster = {version: 1, source: "Docs/Tactics/tactics_casebook.html",
  parts: {bodies: Object.keys(M.R_BODIES), sizes: M.R_SIZES, classes: M.R_CLASSES, grades: M.R_GRADES,
    attacks: Object.keys(M.R_ATTACKS), roles: Object.keys(M.R_ROLES), mods: Object.keys(M.R_MODS), triggers: Object.keys(M.R_TRIGGERS)},
  recipes: {}};
let unfit = 0;
for (const [id, r] of Object.entries(M.allRecipes())) {
  const d = M.rDerive(r);
  if (d.errors.length) unfit++;
  roster.recipes[id] = {body: r.body, size: r.size, class: r.cls, grade: r.grade, attack: r.attack, role: r.role,
    mods: r.mods || [], phases: r.phases || [], built: !!r.built, unit: r.unit || "", derived: d};
}

fs.mkdirSync(path.dirname(outPath), {recursive: true});
fs.writeFileSync(rosterPath, JSON.stringify(roster, null, 1) + "\n");
console.log(`wrote ${path.relative(root, rosterPath)}: ${Object.keys(roster.recipes).length} recipes` + (unfit ? `, ${unfit} that cannot be fielded` : ""));
fs.writeFileSync(outPath, JSON.stringify(book, null, 1) + "\n");
console.log(`wrote ${path.relative(root, outPath)}: ${Object.keys(book.moves).length} moves, ${Object.keys(book.facts).length} facts, ` +
  `${Object.keys(book.amounts).length} amounts, ${Object.keys(book.moments).length} moments, ${book.golden.length} golden cases`);
