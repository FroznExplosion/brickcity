class_name MachineLoadout

## What the machines carry, in one place: a tank's main gun and machine gun and
## its two crew seats, a mech's arm gun and the launcher it takes to walls, an
## APC's gun. The city (CityVehicles, WaveDirector) and the planet
## (PlanetGarrison, the planet's gates) used to each write these out; now they
## call here, and only where a machine stands, what tracks it and what else a
## scene hangs on it stay theirs.
##
## Static and stateless. Seeds come from the caller, in the caller's order, so
## a scene's rolls are drawn from its dice exactly as before.

const TANK_MAIN := &"rocket_launcher"
const TANK_MG := &"lmg"
const MECH_ARM := &"lmg"
const MECH_LAUNCHER := &"rocket_launcher"
const APC_GUN := &"lmg"
const CREW_SEATS := [Tank.Seat.DRIVER, Tank.Seat.GUNNER]


## A tier-1 gun of class `cls` from `lib`, rolled from `seed`.
static func roll(lib: GunPartLibrary, seed: int, cls: StringName) -> GunInstance:
	return GunInstance.from_result(GunGenerator.generate(lib, seed, WeaponClass.builtin(cls), 1))


## A tank's guns, [main, machine gun]: the main from `main_seed`, the machine
## gun from `mg_seed`.
static func tank_guns(lib: GunPartLibrary, main_seed: int, mg_seed: int) -> Array[GunInstance]:
	return [roll(lib, main_seed, TANK_MAIN), roll(lib, mg_seed, TANK_MG)] as Array[GunInstance]


## Its crew into a tank's seats: `spawn` is called with each seat (driver, then
## gunner) and returns the pawn to put there. The pawns, in seat order.
static func crew_tank(t: Tank, spawn: Callable) -> Array[Pawn]:
	var out: Array[Pawn] = []
	for seat in CREW_SEATS:
		var p: Pawn = spawn.call(seat)
		t.board(p, seat, true)
		out.append(p)
	return out


## A mech's arm gun, in its hand and equipped: hidden, because the arm's own
## greybox is the gun the player sees until a dressed gun replaces it
## (MechAssembler.arm_gun). The caller sets the gun's dice and what its rounds
## do to structure.
static func arm_mech(m: Mech, lib: GunPartLibrary, seed: int) -> GunInstance:
	var gi := roll(lib, seed, MECH_ARM)
	gi.visible = false
	m.arm.add_child(gi)
	m.gun.equip(gi)
	return gi


## The launcher a mech takes to walls -- unless it fights with its fists
## (`no_gun`): one that punches its way carries none. `next_seed` is called only
## when there is a launcher to roll, so a fist mech draws nothing from the dice.
static func arm_launcher(br: MechBrain, m: Mech, lib: GunPartLibrary, next_seed: Callable,
		rng: RandomNumberGenerator, on_hit: Callable) -> void:
	if m.no_gun:
		return
	br.arm_launcher(roll(lib, int(next_seed.call()), MECH_LAUNCHER), rng, on_hit)
