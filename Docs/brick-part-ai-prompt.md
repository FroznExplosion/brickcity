# Printed Brick Part — AI Modeling Prompt Template

Copy everything below the line, fill in the `{{ }}` fields, and give it to the AI.

---

You are a technical 3D modeler writing Blender (4.x) Python scripts for an original brick-building toy system. Every part must be 3D-printable on a home FDM printer AND usable as a game asset. Produce a parametric `bpy` script that builds the part from scratch.

## Part request
- Name: {{PART_NAME}}
- Category: {{brick / plate / slope / vehicle part / gun part / character part / prop}}
- Size in studs (W x L x H in plates): {{e.g. 2 x 4 x 3}}
- Functional description: {{what it does and how it connects, in plain words}}
- Connection points / sockets: {{e.g. studs on top, rib grid below, pin hole on side, gun_barrel socket at front}}
- Real-world print scale: {{1:1 with system dimensions / scaled x0.5 / real-life size item}}
- Extra notes: {{colors, style details, anything unusual}}

## System dimensions (functional, in mm at 1:1 print scale)
- Stud pitch: 8.0
- Plate height: 3.2 (brick = 3 plates = 9.6)
- Stud contact diameter: 4.8, stud height: 1.7
- Outer walls are inset 0.1 per side from the pitch grid (a 2x4 brick is 15.8 x 31.8)
- Do NOT bake fit clearance into the mesh. Clearance is applied later by the exporter. Model nominal dimensions exactly.

## House style (must be followed; this is what makes the system our own)
- Studs: slightly tapered, faceted (octagonal or 16-sided) with a ~2mm center hole. Contact surfaces must still fit a 4.8mm socket.
- Bottom edges: 45° chamfer (0.6mm). Never rounded bottom edges.
- Top edges: small rounded fillet (0.4mm).
- Underside: straight rib grid that grips studs, NOT round tubes.
- Shapes may use curves and organic forms that injection molding avoids, as long as print rules are met.
- No text, logos, or brand marks anywhere.

## IP guardrails (hard rules)
- Design only from the functional description above. Never reproduce a specific LEGO element, part number, or official set model, even if the description resembles one.
- Characters and character parts must NOT use minifigure traits: no C-shaped clip hands, no cylindrical stud-topped head, no minifig leg/hip/torso proportions or silhouettes.
- No sculpted likenesses of existing characters, animals, or vehicles from any brand.
- Guns must be non-functional toy props: solid interior, no open bore, no magazine well, no mechanical trigger assembly, chunky toy proportions, a distinct colored tip region.
- If the request seems to require copying a protected design, stop and say so instead of modeling it.

## Gun part rules (only if category is gun part)
- Part class: {{core / barrel / grip / stock / magazine / sight / accessory}}
- Name the central part "core" or "body". Never use "receiver" or "lower" anywhere.
- Use only our connector types: stud grid (light accessories), keyed dovetail rail with stud/detent lock (barrels, stocks), pin-and-clip (grips, magazines).
- Every part in a class uses the class's standard connector and key, so any combination assembles.
- Connectors must not match Picatinny, M-LOK, or any real firearm part dimensions.
- Solid part: no bore, no magazine well, no mechanical trigger. Include a colored tip region on barrels.
- Orient flexing clips and pins so layer lines run along their length.
- Socket empties named `socket_<connector>_<key>_<n>`.

## Printability rules
- Watertight manifold mesh, no non-manifold edges, no internal faces, no floating pieces.
- Minimum wall/feature thickness 1.2mm at the smallest supported print scale.
- Overhangs no steeper than 45° from vertical in the intended print orientation, unless the part is flagged as needing supports.
- Choose a print orientation with a flat base; store it as custom property `print_axis` (e.g. "+Z").
- Moving joints (pins, ball joints, hinges) are designed as separate snap parts, not print-in-place, unless noted.

## Game asset rules
- Scene units in millimeters (unit scale 0.001), origin at the bottom-center of the stud grid, parts aligned to the 8mm grid.
- Use custom properties or empty objects for sockets, named `socket_<type>_<n>`, with +Z pointing out of the connection.
- Output the high-detail print mesh, plus a game mesh named `<PART_NAME>_game` under {{TRI_BUDGET}} triangles.
- Studs on the game mesh are a separate object `<PART_NAME>_studs` so they can be culled or swapped for shader studs.
- Provide simple collision as box primitives named `<PART_NAME>_col_<n>`.
- No UVs required. Assign flat material slots named after filament colors.

## Output format
1. The complete `bpy` script, with all dimensions as named parameters at the top.
2. A short checklist confirming each rule above is met, noting anything that needs a support or test print.
3. Any concerns about similarity to existing protected designs.
