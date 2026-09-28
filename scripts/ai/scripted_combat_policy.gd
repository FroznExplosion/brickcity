class_name ScriptedCombatPolicy
extends CombatPolicy
## The engage decision by hand, until a model replaces it (CombatPolicy).
##
## Each tactic gets a score from the observation -- a few readable rules, each
## one a nudge -- and the tactic is DRAWN, weighted by those scores (a softmax at
## TEMPERATURE), not taken as the best. Two soldiers in the same spot do not do
## the same thing, and one soldier in the same spot twice need not either: the
## player cannot learn the one move every soldier makes. Low temperature is a
## sharper, more predictable soldier; high is a more random one.
##
## The rules, roughly:
##   * an empty or nearly empty magazine wants cover to reload in, badly --
##     unless there is no cover, when it reloads where it stands (fight open);
##   * being hurt, or low on health, wants cover, or further back;
##   * friends already shooting make a push or a flank worth it -- somebody is
##     keeping the enemy's head down -- and being alone makes both worse;
##   * cover that is close and lasts pulls towards taking it;
##   * standing in cover already makes staying (take cover) cheap;
##   * a threat far off is closed on; one close up is backed off from.

const TEMPERATURE := 0.55


func policy_name() -> String:
	return "scripted"


func decide(o: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	var score := scores(o)
	# Softmax, drawn.
	var top := -INF
	for v in score:
		top = maxf(top, v)
	var w := PackedFloat32Array()
	w.resize(score.size())
	var total := 0.0
	for i in score.size():
		w[i] = exp((score[i] - top) / TEMPERATURE)
		total += w[i]
	var pick := rng.randf() * total
	for i in w.size():
		pick -= w[i]
		if pick <= 0.0:
			return i
	return Tactic.TAKE_COVER


## Every tactic's score, for the draw and for overlays.
func scores(o: PackedFloat32Array) -> PackedFloat32Array:
	var cover := o[Obs.HAS_COVER] > 0.5
	var cover_near := cover and o[Obs.COVER_DIST] < 0.6
	var ammo := o[Obs.AMMO]
	var low_ammo := ammo < 0.3 or o[Obs.RELOADING] > 0.5
	var hurt := o[Obs.UNDER_FIRE] > 0.5
	var health := o[Obs.HEALTH]
	var friends := o[Obs.FRIENDS_SHOOTING] * 4.0
	var seeing := o[Obs.FRIENDS_SEEING] * 4.0
	var alone := o[Obs.ALONE] > 0.5
	var far := o[Obs.THREAT_DIST] * 40.0
	var visible := o[Obs.THREAT_VISIBLE] > 0.5

	var s := PackedFloat32Array()
	s.resize(Tactic.COUNT)
	# Stand and shoot: good with a full magazine and the enemy in sight, worse
	# the more it hurts and the better the cover on offer.
	s[Tactic.FIGHT_OPEN] = 0.3 + (0.6 if visible else -0.8) + ammo * 0.5 \
			- (1.0 if hurt else 0.0) - (0.6 if cover_near else 0.0) \
			+ (0.8 if low_ammo and not cover else 0.0)
	s[Tactic.TAKE_COVER] = (1.2 if cover else -3.0) + (0.4 if cover_near else 0.0) \
			+ o[Obs.COVER_LIFE] * 0.6 + (0.8 if hurt else 0.0) + (0.4 if o[Obs.IN_COVER] > 0.5 else 0.0) \
			- (0.3 * friends) - (1.0 if low_ammo else 0.0)
	s[Tactic.COVER_RELOAD] = (-3.0 if not cover else 0.0) + (2.4 if low_ammo else -1.5) \
			+ (0.5 if hurt else 0.0)
	# A push wants friends firing, ammo, health, and the enemy not on top of it.
	s[Tactic.PUSH] = -0.9 + friends * 0.55 + ammo * 0.6 + (health - 0.5) \
			+ (0.5 if far > 22.0 else 0.0) - (0.9 if far < 8.0 else 0.0) \
			- (1.0 if hurt else 0.0) - (0.8 if alone else 0.0) - (1.2 if low_ammo else 0.0)
	# A flank: the same, and it wants somebody else to be looking at the enemy.
	s[Tactic.FLANK] = -0.8 + friends * 0.45 + seeing * 0.35 + ammo * 0.4 \
			+ (0.3 if far > 10.0 and far < 30.0 else -0.4) \
			- (0.8 if hurt else 0.0) - (1.0 if alone else 0.0) - (1.0 if low_ammo else 0.0)
	# Falling back: hurt, low, and close.
	s[Tactic.FALL_BACK] = -1.4 + (1.0 if hurt else 0.0) + (1.0 - health) * 1.6 \
			+ (0.7 if far < 9.0 else 0.0) + (0.4 if alone else 0.0)
	return s
