# Notice: trademarks, licensing, and what is not licensed

*Plain-language summary of what this repository gives you and what it does not. It is a statement
of terms, not legal advice — see [Docs/printed-brick-city-legal-brief.md](Docs/printed-brick-city-legal-brief.md)
for the project's own research summary, which is also not legal advice.*

---

## 1. This is not LEGO

**LEGO® is a trademark of the LEGO Group, which does not sponsor, authorise, endorse or have any
connection with this project.** Neither do Mega Bloks, Brickadia, Brick Rigs or any other maker of
construction toys or games.

Nothing in this repository uses or reproduces:

- the LEGO name, logo, wordmark, or the mark moulded on studs;
- official part names, part numbers, set names, set designs, or colour names;
- the minifigure, or any of its distinctive elements — the C-shaped hands, the cylindrical
  stud-topped head, the torso and hip silhouette, the printed-face style;
- packaging, box art or trade dress resembling any commercial brick product.

**No compatibility with any commercial brick system is claimed, implied or intended.** The parts
here are described as "brick-built"; the dimensions in the code are the project's own and exist so
that its geometry is internally consistent.

What the project does rely on is that the *basic* brick is functional geometry whose patents expired
decades ago, which is why interlocking bricks are made by many companies (Kirkbi v. Ritvik, Supreme
Court of Canada, 2005; Lego Juris v. OHIM, CJEU, 2010). That reasoning covers plain bricks, plates
and tiles. It does not cover sculpted or distinctive newer elements, and this project does not copy
any.

If you represent a rights holder and believe something here crosses a line, open an issue or contact
the owner and it will be looked at promptly.

---

## 2. What is licensed

### The code — GPL-3.0

Everything that is source code is licensed under the **GNU General Public License, version 3**
([LICENSE](LICENSE)):

```
scripts/        shaders/        scenes/         tools/
gdextension/brick/src/          project.godot and project configuration
addons/brick/  (the extension descriptor and the built binary)
```

You may use it, study it, change it and redistribute it. If you distribute a changed version, GPL-3.0
requires you to make your changes available under the same licence. That is the point of the choice:
the code stays open, including in anybody else's hands.

GPL-3.0 includes an express patent licence from contributors for the code as distributed (§11). It
grants no trademark rights (§7(e)), and none are granted here — see §4 below.

### Third-party code

- **godot-cpp** — a submodule, not a copy; licensed by its own authors under the MIT licence, at the
  commit recorded in `.gitmodules`. Nothing in this repository relicenses it.
- **Godot Engine** — MIT, and not distributed here.
- `addons/copy-errors` — under its own licence as published by its author.
- **LimboAI** v1.7.0 (`addons/limboai`) — MIT, © Serhii Snitsaruk and the LimboAI contributors;
  its licence is `addons/limboai/LICENSE.md` and its logo's `LOGO_LICENSE.md`. The prebuilt
  Windows and Linux x86_64 libraries are included as published. Nothing here relicenses it.

---

## 3. What is NOT licensed

**The GPL applies to the code. It applies to nothing else in this repository, and to nothing that
may be added later.**

### Documentation — all rights reserved

Everything under `Docs/`, this file, and `README.md` is **© the owner, all rights reserved**. It is
published so that the code can be understood, reviewed and contributed to. It is not licensed for
copying, redistribution, adaptation, translation, or republication in whole or in part, and it is
not licensed as training data for machine-learning systems.

### Assets — all rights reserved, now and later

The repository currently contains no art, models, textures, audio, or printable part files. **When
it does, those are not covered by the GPL and are not open source.** Any asset added here is all
rights reserved unless a file beside it says otherwise in writing. Assume a file is proprietary
unless it is code.

This is the same separation id Software used and Godot itself encourages: an open engine, and
content the author still owns.

### The design

The reasoning in `Docs/` — the layer model, the failure model, the LOD ladder, the milestones and
the measurements behind them — is the part of this project that took the longest, and it is
published rather than given away.

It is worth being straight about what that can and cannot mean. **Copyright protects the way an idea
is expressed, not the idea itself.** The documents are protected as text and are not licensed for
reuse (above). Somebody who reads them and independently writes their own implementation of a
similar approach is generally free to do so, and no wording in a notice file changes that. What is
reserved is what can be: the text, the assets, the name, and — for the code — the obligations that
GPL-3.0 imposes on anyone who redistributes it.

If you want the code, the docs or the design under different terms than these, ask. Dual licensing
is possible because the owner holds the copyright.

---

## 4. Name and marks

**"Printed Brick City"**, **"Brickcity"**, and any logo or in-game brand belonging to this project
are reserved by the owner. The GPL grants no right to use them (GPL-3.0 §7(e)). A fork must not use
them in a way that suggests it is this project or is endorsed by it.

---

## 5. Printable files and safety

This project is about brick-built things and intends to produce printable models. Anything printed
from files this project generates is printed at the maker's own risk: **there is no warranty, express
or implied, of fitness, durability or safety**, and the GPL disclaims warranty for the code as well
(§15–16).

The project's rules about what it will and will not generate — solid props, non-standard connectors,
naming, and the firearm-law reasoning behind them — are in
[Docs/printed-brick-city-legal-brief.md](Docs/printed-brick-city-legal-brief.md). Those are design
constraints the generator enforces, not legal guarantees.

Laws on printable files, imitation firearms, toy safety and children's privacy differ by country and
change. Before any public release, this project intends to obtain review from a qualified lawyer,
and nothing here substitutes for that.

---

## 6. Contributing

Contributions of code are welcome under GPL-3.0; by opening a pull request you licence your
contribution under the same terms. Contributions of documentation or assets are not being accepted,
because of the split above.

---

*Copyright © 2026 the owner of this repository (GitHub: FroznExplosion). "LEGO" is a registered
trademark of the LEGO Group; other names may be trademarks of their respective owners, and are used
here only to say what this project is not.*
