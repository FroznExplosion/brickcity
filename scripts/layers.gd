class_name Layers

## Single source of truth for collision layers.
##
## Both reference projects recorded the same lesson: layer numbers scattered as
## magic literals are the main thing that makes a system non-portable, and the
## fix is value-identical and free if you do it before the literals spread
## (Reference/reddawn.md section 13). So it is done before there are any.

const WORLD := 1 << 0      ## ground, terrain, anything permanent
const STRUCTURE := 1 << 1  ## standing brick, the chunk's static compound body
const DEBRIS := 1 << 2     ## detached clusters at rest
const PAWN := 1 << 3       ## characters. Nothing uses it yet.
const FALLING := 1 << 4    ## a large detached section still in motion
const RUBBLE := 1 << 5     ## a piece too small to matter to a collapse
## Interior fittings that are NOT made of brick, when there are any. Nothing
## uses it today.
##
## It was written for staircases, which had a body of their own and had to be
## kept off everything structural: a section coming down landed on the
## staircase and stopped, so the building stood on its own bannister. The fix
## turned out to be upstream of collision layers -- a staircase is bricks in
## the building's own chunk (Fixture), so it is the building's own body, and
## what lands on it breaks it. The layer stays for a fixture that is genuinely
## not brick.
const FIXTURE := 1 << 6

## What a projectile or an aim ray should be allowed to hit. Everything made of
## bricks, however small and whatever it is doing.
const HITSCAN_MASK := WORLD | STRUCTURE | DEBRIS | FALLING | RUBBLE | FIXTURE

## What a character stands on and walks into: the ground, standing buildings,
## and every piece of wreckage whatever state it is in. The same set as a
## hitscan, which is the point -- you can stand on anything you can shoot.
const PAWN_MASK := WORLD | STRUCTURE | DEBRIS | FALLING | RUBBLE | FIXTURE

## What a static building collides with. Rubble bounces off it; a falling
## section lands on it.
const STRUCTURE_MASK := DEBRIS | FALLING | RUBBLE | PAWN

## What such a fixture would want to know about: the ground it stands on and the
## people walking on it, and nothing that falls.
const FIXTURE_MASK := WORLD | PAWN

## A large section on its way down. It collides with the ground, with standing
## buildings, with settled wreckage and with other falling sections -- but NOT
## with rubble, which is the whole point: a few loose bricks have no business
## deflecting a falling building, and the pairs they generate are the bulk of
## the collision cost during a collapse.
const FALLING_MASK := WORLD | STRUCTURE | DEBRIS | FALLING

## Settled wreckage. Same as falling, plus rubble can land on it.
const SETTLED_MASK := WORLD | STRUCTURE | DEBRIS | FALLING | RUBBLE

## A small piece. It lands on the ground, on buildings and on settled wreckage,
## and passes through anything still collapsing -- and through other rubble,
## which is where the quadratic pair count came from.
const RUBBLE_MASK := WORLD | STRUCTURE | DEBRIS
