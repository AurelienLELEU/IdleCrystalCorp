extends Node

## Cœur de simulation du jeu.
##
## Responsabilités : état de la partie, économie, sauvegarde, gains hors-ligne,
## ascension, succès. Il ne connaît ni l'interface, ni les pubs, ni l purchases.
## L'UI s'abonne aux signaux ci-dessous ; tout ce qui doit être lu par l'UI
## passe par une méthode publique.
##
## Règle d'or : aucune recherche linéaire dans une boucle de rendu. Les listes
## de game_config.json sont indexées une fois par GameConfig, et la production
## comme la puissance de clic sont mises en cache et invalidées à la demande.

signal resources_changed(total: BigNum, per_sec: BigNum)
signal production_changed(per_sec: BigNum)
signal click_power_changed(power: BigNum)
signal building_purchased(id: String, count: int, cost: BigNum)
signal upgrade_purchased(id: String, level: int, cost: BigNum)
signal research_purchased(id: String, level: int, cost: BigNum)
signal achievement_unlocked(id: String, reward_text: String)
signal game_reset()
signal prestige_performed(points_gained: int, total_points: int)
signal offline_gains_pending(elapsed: float, amount: BigNum)
signal offline_gains_claimed(amount: BigNum, doubled: bool)
signal save_written()
signal combo_changed(stacks: int, multiplier: float)
signal message(text: String, kind: String)
signal daily_bonus_changed(available: bool)

## Message destiné à l'interface (toast). `kind` : "info", "success", "warn", "error".
func notify(text: String, kind: String = "info") -> void:
	message.emit(text, kind)

const SAVE_PATH := "user://idle_save.dat"
const LEGACY_SAVE_PATH := "user://savegame.json"
const SAVE_VERSION := 2
const DAILY_BONUS_SECONDS := 86400.0
const UI_TICK_HZ := 10.0

const STAT_DEFAULTS := {
	"clicks": 0,
	"best_combo": 0,
	"sessions": 0,
	"play_time": 0.0,
	"ads_watched": 0,
	"notifications_scheduled": 0,
	"first_launch": 0.0,
	"last_daily_claim": 0.0,
}

# --- Contenu
var config: GameConfig

# --- État de la run courante
var current_resources: BigNum = BigNum.zero()
var click_bonus: BigNum = BigNum.zero()
var buildings_owned: Dictionary = {}
var click_upgrades_owned: Dictionary = {}
var research_levels: Dictionary = {}
var run_earnings: BigNum = BigNum.zero()

# --- État permanent
var achievements_unlocked: Dictionary = {}
var prestige_points: int = 0
var prestige_count: int = 0
var lifetime_earnings: BigNum = BigNum.zero()
var research_levels_total: int = 0
var buildings_total_owned: int = 0
var flags: Dictionary = {"no_ads": false}
var stats: Dictionary = {}

# --- Boost consommable (achat)
var boost_multiplier: float = 1.0
var boost_ends_at: float = 0.0
var boost_started_at: float = 0.0

## Production au moment du dernier point de contrôle : c'est elle qui sert au
## calcul des gains hors-ligne, sinon acheter juste avant de quitter ne rapporterait
## rien une fois l'application tuée en arrière-plan.
var production_at_save: BigNum = BigNum.zero()

# --- Gains hors-ligne : crédités une seule fois, à la réclamation
var pending_offline: Dictionary = {}
var last_save_timestamp: float = 0.0

# --- Combo de clics rapides
var combo_stacks: int = 0
var combo_timer: float = 0.0

# --- Interne
var save_path_override: String = ""
var is_loaded: bool = false
var _production_cache: BigNum = BigNum.zero()
var _click_cache: BigNum = BigNum.zero()
var _production_dirty: bool = true
var _click_dirty: bool = true
var _autosave_timer: Timer
var _ui_tick_timer: Timer
var _boost_active: bool = false
var _last_write_time: float = 0.0


# =============================================================== initialisation

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_stats_init()
	config = GameConfig.new()
	if not config.load_from_file():
		notify("Configuration de jeu introuvable : l'équilibrage par défaut est utilisé.", "error")
	_apply_boost_state()
	_load_game()
	_ensure_minimum_state()
	_recalculate()

	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = config.autosave_interval
	_autosave_timer.one_shot = false
	_autosave_timer.timeout.connect(save_game)
	_autosave_timer.autostart = true
	add_child(_autosave_timer)

	# Rythme d rafraîchissement de l'interface : 10 Hz suffit largement et évite
	# de reconstruire des dizaines de libellés à 60 Hz sur mobile.
	_ui_tick_timer = Timer.new()
	_ui_tick_timer.wait_time = 1.0 / UI_TICK_HZ
	_ui_tick_timer.timeout.connect(_emit_tick)
	_ui_tick_timer.autostart = true
	add_child(_ui_tick_timer)

	_on_session_started()


func _stats_init() -> void:
	stats = STAT_DEFAULTS.duplicate(true)
	stats["first_launch"] = Time.get_unix_time_from_system()


# ==================================================================== production

func _process(delta: float) -> void:
	stats["play_time"] = float(stats.get("play_time", 0.0)) + delta

	if _boost_active and Time.get_unix_time_from_system() >= boost_ends_at:
		_boost_active = false
		boost_multiplier = 1.0
		boost_ends_at = 0.0
		_production_dirty = true
		notify("Votre surcharge est terminée.", "info")

	var prod := get_production_per_sec()
	if not prod.is_zero():
		_grant(prod.mul_float(delta), true)

	if combo_stacks > 0:
		combo_timer -= delta
		if combo_timer <= 0.0:
			combo_stacks = 0
			combo_timer = 0.0
			_click_dirty = true
			combo_changed.emit(0, 1.0)


func _emit_tick() -> void:
	resources_changed.emit(current_resources, get_production_per_sec())


func get_production_per_sec() -> BigNum:
	if _production_dirty:
		_recalculate()
	return _production_cache


func get_click_power() -> BigNum:
	if _click_dirty:
		_recalculate()
	return _click_cache


func _recalculate() -> void:
	_production_dirty = false
	_click_dirty = false

	# -- Production
	var base := config.base_production_per_sec
	for b in config.buildings:
		var count := get_building_count(str(b.get("id", "")))
		if count <= 0:
			continue
		var per := BigNum.from_float(float(b.get("production_per_sec", 0.0)))
		var every := int(b.get("milestone_every", 0))
		if every > 0:
			var milestones := count / every
			if milestones > 0:
				per = per.mul(BigNum.from_float(float(b.get("milestone_mult", 2.0))).powf_num(float(milestones)))
		base = base.add(per.mul_float(float(count)))

	var total := base.mul(_research_mult("production_mult"))
	total = total.mul(_achievement_production_mult())
	total = total.mul(_prestige_multiplier())
	if _boost_active and boost_multiplier != 1.0:
		total = total.mul(BigNum.from_float(boost_multiplier))

	_production_cache = total
	production_changed.emit(total)

	# -- Puissance de clic
	var click := config.start_click_power.add(click_bonus)
	for u in config.click_upgrades:
		click = click.add(BigNum.from_float(float(u.get("power_bonus", 0.0))).mul_float(float(get_upgrade_level(str(u.get("id", ""))))))
	click = click.mul(_research_mult("click_mult"))
	click = click.mul(_combo_multiplier())
	_click_cache = click
	click_power_changed.emit(click)


func _research_mult(effect_type: String) -> BigNum:
	var result := BigNum.from_float(1.0)
	for t in config.research:
		if str(t.get("effect_type", "")) != effect_type:
			continue
		var level := get_research_level(str(t.get("id", "")))
		if level <= 0:
			continue
		result = result.mul(BigNum.from_float(float(t.get("effect_value", 1.0))).powf_num(float(level)))
	return result


func _achievement_production_mult() -> BigNum:
	var bonus := 0.0
	for a in config.achievements:
		if str(a.get("reward_type", "")) != "production_mult":
			continue
		if not is_achievement_unlocked(str(a.get("id", ""))):
			continue
		bonus += float(a.get("reward_value", 0.0)) - 1.0
	return BigNum.from_float(1.0 + bonus)


func _combo_multiplier() -> BigNum:
	var per_stack := float(config.combo.get("power_per_stack", 0.04))
	return BigNum.from_float(1.0 + float(combo_stacks) * per_stack)


func _prestige_multiplier() -> BigNum:
	var per_point := float(config.prestige.get("mult_per_point", 0.01))
	return BigNum.from_float(1.0 + float(prestige_points) * per_point)


func get_combo_multiplier() -> float:
	return 1.0 + float(combo_stacks) * float(config.combo.get("power_per_stack", 0.04))


func get_combo_window() -> float:
	var base := float(config.combo.get("base_window", 1.2))
	return base + _sum_research_effect("combo_window")


# ======================================================================== gains

func _grant(amount: BigNum, counted: bool) -> void:
	if amount == null or amount.is_zero():
		return
	if amount.is_negative():
		amount = BigNum.zero()
	current_resources = current_resources.add(amount)
	if counted:
		run_earnings = run_earnings.add(amount)
		lifetime_earnings = lifetime_earnings.add(amount)
		_check_achievements()


## Attribution externe de ressources (récompense de pub, etc.).
## `counted` décide si le gain entre dans le cumul « gagné au total », qui pilote
## les succès et le calcul d'ascension.
func grant_resources(amount: BigNum, counted: bool = true) -> void:
	_grant(amount, counted)
	resources_changed.emit(current_resources, get_production_per_sec())


## Temps de surcharge restant, en secondes (0 si aucune surcharge).
func get_boost_remaining() -> float:
	return maxf(0.0, boost_ends_at - Time.get_unix_time_from_system())


## Durée totale de la surcharge courante, pour afficher une barre de progression.
func get_boost_total() -> float:
	if not is_boost_active():
		return 0.0
	return maxf(1.0, boost_ends_at - boost_started_at)


## true si une surcharge d'achat ou de pub est en cours.
func is_boost_active() -> bool:
	return _boost_active and get_boost_remaining() > 0.0


## Récolte manuelle. Retourne le montant réellement obtenu (pour l'animation).
func harvest() -> BigNum:
	var power := get_click_power()
	stats["clicks"] = int(stats.get("clicks", 0)) + 1
	_register_combo()
	_grant(power, true)
	return power


func _register_combo() -> void:
	var max_stacks := int(config.combo.get("max_stacks", 25))
	var window := get_combo_window()
	if combo_timer <= 0.0:
		combo_stacks = 0
	combo_stacks = mini(combo_stacks + 1, max_stacks)
	combo_timer = window
	stats["best_combo"] = maxi(int(stats.get("best_combo", 0)), combo_stacks)
	_click_dirty = true
	combo_changed.emit(combo_stacks, get_combo_multiplier())
	_check_achievements()


# ====================================================================== bâtiments

func get_building_count(id: String) -> int:
	return int(buildings_owned.get(id, 0))


func is_building_unlocked(id: String) -> bool:
	var b := config.building(id)
	if b.is_empty():
		return false
	return prestige_count >= int(b.get("unlock_prestige", 0))


func _building_cost_reduction() -> float:
	var level := _sum_research_levels("cost_reduction")
	var per_level := 1.0
	for t in config.research:
		if str(t.get("effect_type", "")) == "cost_reduction":
			per_level = float(t.get("effect_value", 0.92))
			break
	return pow(per_level, float(level))


## Coût de la prochaine unité, réduction de recherche comprise.
func get_building_cost(id: String) -> BigNum:
	var b := config.building(id)
	if b.is_empty():
		return BigNum.zero()
	var count := get_building_count(id)
	var cost := BigNum.from_float(float(b.get("base_cost", 0.0))).mul(
		BigNum.from_float(float(b.get("cost_multiplier", 1.15))).powf_num(float(count))
	)
	return cost.mul_float(_building_cost_reduction())


## Coût total pour `n` unités consécutives (boucle : n est borné par l'UI).
func get_building_cost_batch(id: String, n: int) -> BigNum:
	var total := BigNum.zero()
	var owned := get_building_count(id)
	for i in maxi(1, n):
		total = total.add(_building_cost_at(id, owned + i))
	return total


func _building_cost_at(id: String, count: int) -> BigNum:
	var b := config.building(id)
	if b.is_empty():
		return BigNum.zero()
	return BigNum.from_float(float(b.get("base_cost", 0.0))).mul(
		BigNum.from_float(float(b.get("cost_multiplier", 1.15))).powf_num(float(count))
	).mul_float(_building_cost_reduction())


## Nombre d'unités achetables d'affilée, borné pour ne jamais bloquer une frame.
func get_building_max_affordable(id: String, cap: int = 1000) -> int:
	var bought := 0
	var spent := BigNum.zero()
	while bought < cap:
		var step := _building_cost_at(id, get_building_count(id) + bought)
		if spent.add(step).gt(current_resources):
			break
		spent = spent.add(step)
		bought += 1
	return bought


## Achète jusqu'à `count` unités. Retourne le nombre réellement acheté.
func buy_building(id: String, count: int = 1) -> int:
	if not is_building_unlocked(id):
		return 0
	var bought := 0
	for i in maxi(1, count):
		var cost := get_building_cost(id)
		if current_resources.lt(cost):
			break
		current_resources = current_resources.sub(cost)
		buildings_owned[id] = get_building_count(id) + 1
		buildings_total_owned += 1
		bought += 1
	if bought > 0:
		_production_dirty = true
		_recalculate()
		building_purchased.emit(id, get_building_count(id), get_building_cost(id))
		_check_achievements()
		_save_soon()
	return bought


# ============================================================ améliorations de clic

func get_upgrade_level(id: String) -> int:
	return int(click_upgrades_owned.get(id, 0))


func get_upgrade_cost(id: String) -> BigNum:
	var u := config.click_upgrade(id)
	if u.is_empty():
		return BigNum.zero()
	var level := get_upgrade_level(id)
	return BigNum.from_float(float(u.get("base_cost", 0.0))).mul(
		BigNum.from_float(float(u.get("cost_multiplier", 1.3))).powf_num(float(level))
	)


func buy_upgrade(id: String) -> bool:
	var u := config.click_upgrade(id)
	if u.is_empty():
		return false
	var level := get_upgrade_level(id)
	if level >= int(u.get("max_level", 999)):
		return false
	var cost := get_upgrade_cost(id)
	if current_resources.lt(cost):
		return false
	current_resources = current_resources.sub(cost)
	click_upgrades_owned[id] = level + 1
	_click_dirty = true
	upgrade_purchased.emit(id, level + 1, cost)
	_save_soon()
	return true


# ===================================================================== recherche

func get_research_level(id: String) -> int:
	return int(research_levels.get(id, 0))


func get_research_max_level(id: String) -> int:
	var t := config.research_tech(id)
	return int(t.get("max_level", 1))


func get_research_cost(id: String) -> BigNum:
	var t := config.research_tech(id)
	if t.is_empty():
		return BigNum.zero()
	var level := get_research_level(id)
	return BigNum.from_float(float(t.get("base_cost", 0.0))).mul(
		BigNum.from_float(float(t.get("cost_multiplier", 1.0))).powf_num(float(level))
	)


func is_research_unlocked(id: String) -> bool:
	var t := config.research_tech(id)
	if t.is_empty():
		return false
	if prestige_count < int(t.get("unlock_prestige", 0)):
		return false
	for req in t.get("requires", []):
		if get_research_level(str(req)) <= 0:
			return false
	return true


func buy_research(id: String) -> bool:
	if not is_research_unlocked(id):
		return false
	if get_research_level(id) >= get_research_max_level(id):
		return false
	var cost := get_research_cost(id)
	if current_resources.lt(cost):
		return false
	current_resources = current_resources.sub(cost)
	research_levels[id] = get_research_level(id) + 1
	research_levels_total += 1
	_production_dirty = true
	_click_dirty = true
	_recalculate()
	research_purchased.emit(id, get_research_level(id), cost)
	_check_achievements()
	_save_soon()
	return true


func _sum_research_levels(effect_type: String) -> int:
	var total := 0
	for t in config.research:
		if str(t.get("effect_type", "")) == effect_type:
			total += get_research_level(str(t.get("id", "")))
	return total


func _sum_research_effect(effect_type: String) -> float:
	var total := 0.0
	for t in config.research:
		if str(t.get("effect_type", "")) != effect_type:
			continue
		total += float(t.get("effect_value", 0.0)) * float(get_research_level(str(t.get("id", ""))))
	return total


# ===================================================================== ascension

func get_prestige_requirement() -> BigNum:
	return BigNum.from_float(float(config.prestige.get("min_run_earnings", 1e9)))


## Éclats d'Éternité gagnés si le joueur ascendait maintenant.
func get_prestige_preview() -> Dictionary:
	var requirement := get_prestige_requirement()
	var can := run_earnings.gte(requirement)
	var points := _prestige_points_for(run_earnings)
	var current := _prestige_multiplier().to_float()
	var projected := 1.0 + float(prestige_points + points) * float(config.prestige.get("mult_per_point", 0.01))
	return {
		"can_prestige": can,
		"points_gained": points,
		"total_points": prestige_points + points,
		"current_multiplier": current,
		"next_multiplier": projected,
		"requirement": requirement,
		"progress": clampf(run_earnings.log10v() - requirement.log10v(), 0.0, 1.0) if requirement.log10v() > 0.0 else 0.0,
		"resets_research": bool(config.prestige.get("reset_research", true)),
	}


func _prestige_points_for(earnings: BigNum) -> int:
	if earnings.is_zero() or earnings.is_negative():
		return 0
	var divisor := float(config.prestige.get("divisor", 1e6))
	var exponent := float(config.prestige.get("exponent", 0.5))
	var bonus := 1.0 + _sum_research_effect("prestige_bonus")
	var scaled := earnings.div_float(maxf(1.0, divisor)).powf_num(exponent)
	return int(floor(scaled.to_float() * bonus))


func can_perform_prestige() -> bool:
	return run_earnings.gte(get_prestige_requirement()) and _prestige_points_for(run_earnings) > 0


func perform_prestige() -> int:
	if not can_perform_prestige():
		return 0
	var points := _prestige_points_for(run_earnings)
	if points <= 0:
		return 0
	prestige_points += points
	prestige_count += 1

	# Remise à zéro de la run. Ce qui est conservé est dicté par la config.
	current_resources = BigNum.zero()
	run_earnings = BigNum.zero()
	buildings_owned.clear()
	buildings_total_owned = 0
	if bool(config.prestige.get("reset_research", true)):
		research_levels.clear()
		research_levels_total = 0
	if not bool(config.prestige.get("keep_click_upgrades", false)):
		click_upgrades_owned.clear()
	combo_stacks = 0

	_production_dirty = true
	_click_dirty = true
	_recalculate()
	prestige_performed.emit(points, prestige_points)
	notify("Ascension réussie : %s %s" % [Fmt.number_bn(BigNum.from_float(float(points))), config.prestige_name], "success")
	_check_achievements()
	save_game()
	return points


# ======================================================================= succès

func is_achievement_unlocked(id: String) -> bool:
	return bool(achievements_unlocked.get(id, false))


func get_achievements_unlocked_count() -> int:
	return achievements_unlocked.size()


func _check_achievements() -> void:
	# Boucle plutôt que récursion : une récompense peut débloquer un autre succès,
	# et la profondeur est bornée pour qu'un cycle improbable ne boucle pas.
	for _pass in 8:
		var unlocked_any := false
		for a in config.achievements:
			var id := str(a.get("id", ""))
			if id.is_empty() or is_achievement_unlocked(id):
				continue
			if not _achievement_progress_reached(a):
				continue
			achievements_unlocked[id] = true
			var reward_text := _grant_achievement_reward(a)
			_production_dirty = true
			_click_dirty = true
			achievement_unlocked.emit(id, reward_text)
			unlocked_any = true
		if not unlocked_any:
			return


func _achievement_progress_reached(a: Dictionary) -> bool:
	var threshold := float(a.get("threshold", 0.0))
	match str(a.get("type", "")):
		"lifetime":
			return lifetime_earnings.cmp(BigNum.from_float(threshold)) >= 0
		"buildings_total":
			return buildings_total_owned >= int(threshold)
		"clicks":
			return int(stats.get("clicks", 0)) >= int(threshold)
		"prestige":
			return prestige_count >= int(threshold)
		"research_levels":
			return research_levels_total >= int(threshold)
		"combo":
			return combo_stacks >= int(threshold)
		"building":
			return get_building_count(str(a.get("target", ""))) >= int(threshold)
	return false


func _grant_achievement_reward(a: Dictionary) -> String:
	var value := float(a.get("reward_value", 0.0))
	match str(a.get("reward_type", "")):
		"resources":
			var amount := BigNum.from_float(value)
			current_resources = current_resources.add(amount)
			# Volontairement hors "gagné total" : une récompense ne doit pas
			# déclencher une cascade de succès.
			return "+%s %s" % [amount.format_short(), config.resource_name]
		"production_mult":
			return "Production %s" % Fmt.multiplier(value)
		"click_power":
			click_bonus = click_bonus.add(BigNum.from_float(value))
			return "+%s par clic" % BigNum.from_float(value).format_short()
		"prestige_points":
			prestige_points += int(value)
			return "+%d %s" % [int(value), config.prestige_name]
	return ""


# ============================================================== bonus quotidien

func is_daily_bonus_available() -> bool:
	var last := float(stats.get("last_daily_claim", 0.0))
	return Time.get_unix_time_from_system() - last >= DAILY_BONUS_SECONDS


func get_daily_bonus_time_left() -> float:
	var last := float(stats.get("last_daily_claim", 0.0))
	if last <= 0.0:
		return 0.0
	return maxf(0.0, DAILY_BONUS_SECONDS - (Time.get_unix_time_from_system() - last))


func get_daily_bonus_amount() -> BigNum:
	# Une heure de production, avec un plancher pour les tout débuts.
	var amount := get_production_per_sec().mul_float(3600.0)
	var floor_amount := config.start_resources
	if amount.lt(floor_amount):
		amount = floor_amount
	return amount


func claim_daily_bonus(doubled: bool = false) -> BigNum:
	if not is_daily_bonus_available():
		return BigNum.zero()
	var amount := get_daily_bonus_amount()
	if doubled:
		amount = amount.mul_float(2.0)
	stats["last_daily_claim"] = Time.get_unix_time_from_system()
	_grant(amount, true)
	daily_bonus_changed.emit(false)
	save_game()
	return amount


# ================================================================ gains hors-ligne

func get_offline_cap_hours() -> float:
	var base := float(config.offline.get("base_hours", 2.0))
	var per_level := float(config.offline.get("hours_per_research_level", 2.0))
	return base + per_level * float(_sum_research_levels("offline_hours"))


func has_pending_offline() -> bool:
	return not pending_offline.is_empty()


func get_pending_offline() -> Dictionary:
	return pending_offline.duplicate()


## Calcule les gains hors-ligne sans les créditer. Appelé au retour au premier
## plan et au démarrage. Le crédit se fait uniquement dans claim_offline_gains(),
## ce qui garantit qu'une même période ne peut jamais être comptée deux fois.
func _compute_offline_gains() -> void:
	if last_save_timestamp <= 0.0:
		return
	var now := Time.get_unix_time_from_system()
	var elapsed := now - last_save_timestamp
	if elapsed <= 0.0:
		return
	var min_popup := float(config.offline.get("min_popup_seconds", 60.0))
	var cap_seconds := get_offline_cap_hours() * 3600.0
	var effective := minf(elapsed, cap_seconds)
	var amount := _production_at_last_save().mul_float(effective)

	# L'horodatage est avancé AVANT toute sortie. C'est ce qui rend ce calcul
	# idempotent : sans cela, un second appel (revenir en avant-plan sans
	# qu'aucune sauvegarde n'ait eu lieu) recalculerait la même période et la
	# compterait une seconde fois. Conséquence : chaque portion de temps est
	# consommée exactement une fois par _compute_offline_gains().
	last_save_timestamp = now

	if amount.is_zero() or amount.is_negative():
		return

	if elapsed < min_popup:
		# Absence courte : on crédite sans popup et on reprogramme le point de départ.
		current_resources = current_resources.add(amount)
		return

	# Si une période précédente est encore en attente — le joueur a mis
	# l'application en arrière-plan puis est revenu sans collecter — on cumule au
	# lieu d'écraser, sinon ces gains seraient perdus. Comme chaque portion est
	# calculée à partir d'un last_save_timestamp distinct, le cumul ne peut pas
	# compter deux fois la même seconde.
	if pending_offline.is_empty():
		pending_offline = {
			"elapsed": elapsed,
			"effective": effective,
			"amount": amount,
			"capped": elapsed > cap_seconds,
		}
	else:
		pending_offline["elapsed"] = float(pending_offline.get("elapsed", 0.0)) + elapsed
		pending_offline["effective"] = float(pending_offline.get("effective", 0.0)) + effective
		pending_offline["amount"] = pending_offline.get("amount", BigNum.zero()).add(amount)
		pending_offline["capped"] = bool(pending_offline.get("capped", false)) or elapsed > cap_seconds
	offline_gains_pending.emit(elapsed, amount)


func _production_at_last_save() -> BigNum:
	return production_at_save if not production_at_save.is_zero() else get_production_per_sec()


## Réclame les gains hors-ligne. `doubled` correspond au récompense pub.
func claim_offline_gains(doubled: bool = false) -> BigNum:
	if pending_offline.is_empty():
		return BigNum.zero()
	var amount: BigNum = pending_offline.get("amount", BigNum.zero())
	if doubled:
		amount = amount.mul_float(2.0)
	pending_offline = {}
	current_resources = current_resources.add(amount)
	run_earnings = run_earnings.add(amount)
	lifetime_earnings = lifetime_earnings.add(amount)
	# Horodatage remis à zéro : sans cela la période serait rejouée au prochain
	# lancement, puisque rien n'aurait été écrit entre-temps.
	last_save_timestamp = Time.get_unix_time_from_system()
	_check_achievements()
	offline_gains_claimed.emit(amount, doubled)
	save_game()
	return amount


# ==================================================================== sauvegarde

func get_save_path() -> String:
	return save_path_override if not save_path_override.is_empty() else SAVE_PATH


func _save_soon() -> void:
	# Limiteur de débit : une rafale de 50 achats en une seconde n'écrit pas 50
	# fois sur le stockage, et la sauvegarde périodique rattrape le reste. Le délai
	# est volontairement-borné (et non un timer remis à zéro) pour que des
	# achats répétés ne puissent jamais affamer l'autosave.
	var now := Time.get_unix_time_from_system()
	if now - _last_write_time < 3.0:
		return
	save_game()


func save_game() -> void:
	if not is_loaded:
		return
	var data := _serialize()
	var path := get_save_path()
	# Écriture atomique : fichier temporaire puis remplacement, pour qu'une
	# coupure au milieu de l'écriture ne corrupte pas la sauvegarde.
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("Échec d'écriture de la sauvegarde : %s" % tmp_path)
		return
	file.store_buffer(SaveCodec.encode(data))
	file.close()
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		push_error("Dossier de sauvegarde inaccessible : %s" % path.get_base_dir())
		return
	if dir.file_exists(path.get_file()):
		dir.remove(path.get_file())
	var err := dir.rename(tmp_path.get_file(), path.get_file())
	if err != OK:
		# Sur certains systèmes user:// est en lecture seule une fois l'app
		# sandstoneée : on retombe sur une écriture directe.
		var fallback := FileAccess.open(path, FileAccess.WRITE)
		if fallback != null:
			fallback.store_buffer(SaveCodec.encode(data))
			fallback.close()
		else:
			push_error("Renommage de sauvegarde impossible (erreur %d)" % err)
			return
	last_save_timestamp = Time.get_unix_time_from_system()
	_last_write_time = last_save_timestamp
	save_written.emit()


func _serialize() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"resources": current_resources.serialize(),
		"click_bonus": click_bonus.serialize(),
		"buildings": _stringify_keys(buildings_owned),
		"click_upgrades": _stringify_keys(click_upgrades_owned),
		"research": _stringify_keys(research_levels),
		"achievements": achievements_unlocked.duplicate(),
		"prestige_points": prestige_points,
		"prestige_count": prestige_count,
		"run_earnings": run_earnings.serialize(),
		"lifetime_earnings": lifetime_earnings.serialize(),
		"research_levels_total": research_levels_total,
		"buildings_total_owned": buildings_total_owned,
		"boost_multiplier": boost_multiplier,
		"boost_ends_at": boost_ends_at,
		"boost_started_at": boost_started_at,
		"flags": _stringify_keys(flags),
		"stats": _stringify_keys(stats),
		"last_save": Time.get_unix_time_from_system(),
		"production_at_save": production_at_save.serialize(),
	}

func _load_game() -> void:
	var path := get_save_path()
	var data: Dictionary = {}
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var decoded: Variant = SaveCodec.decode(file.get_buffer(file.get_length()))
			file.close()
			if decoded != null:
				data = decoded
			else:
				push_warning("Sauvegarde illisible, elle sera ignorée : %s" % path)
	elif FileAccess.file_exists(LEGACY_SAVE_PATH):
		data = _load_legacy_json(LEGACY_SAVE_PATH)

	is_loaded = true
	if data.is_empty():
		_apply_fresh_state()
	else:
		_apply_save_data(data)
		if not FileAccess.file_exists(path):
			# Migration réussie depuis l'ancien format : on écrit au format courant.
			save_game()


func _load_legacy_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	push_warning("Ancienne sauvegarde JSON détectée, migration vers le format binaire.")
	return {
		"version": 1,
		"resources": float(d.get("current_resources", 0.0)),
		"buildings": d.get("buildings_owned", {}),
		"click_upgrades": d.get("click_upgrades_owned", {}),
		"research": d.get("research_unlocked", {}),
		"last_save": float(d.get("last_save_timestamp", 0.0)),
		"production_at_save": null,
	}


func _apply_fresh_state() -> void:
	current_resources = config.start_resources.copy()
	click_bonus = BigNum.zero()
	buildings_owned = {}
	click_upgrades_owned = {}
	research_levels = {}
	run_earnings = BigNum.zero()
	lifetime_earnings = BigNum.zero()
	prestige_points = 0
	prestige_count = 0
	achievements_unlocked = {}
	flags = {"no_ads": false}
	last_save_timestamp = Time.get_unix_time_from_system()


func _apply_save_data(d: Dictionary) -> void:
	current_resources = BigNum.deserialize(d.get("resources", 0.0))
	click_bonus = BigNum.deserialize(d.get("click_bonus", 0.0))
	buildings_owned = _int_map(d.get("buildings", {}))
	click_upgrades_owned = _int_map(d.get("click_upgrades", {}))
	research_levels = _int_map(d.get("research", {}))
	achievements_unlocked = _bool_map(d.get("achievements", {}))
	prestige_points = int(d.get("prestige_points", 0))
	prestige_count = int(d.get("prestige_count", 0))
	run_earnings = BigNum.deserialize(d.get("run_earnings", 0.0))
	lifetime_earnings = BigNum.deserialize(d.get("lifetime_earnings", 0.0))
	research_levels_total = int(d.get("research_levels_total", 0))
	buildings_total_owned = int(d.get("buildings_total_owned", 0))
	boost_multiplier = float(d.get("boost_multiplier", 1.0))
	boost_ends_at = float(d.get("boost_ends_at", 0.0))
	boost_started_at = float(d.get("boost_started_at", 0.0))
	stats = _merge_stats(d.get("stats", {}))
	flags = _merge_flags(d.get("flags", {}))
	last_save_timestamp = float(d.get("last_save", 0.0))
	if last_save_timestamp <= 0.0:
		last_save_timestamp = Time.get_unix_time_from_system()

	# Cohérence : les compteurs dérivés sont reconstruits depuis l'état brut,
	# sinon un save modifié à la main ou une version ancienne fausse l'UI.
	buildings_total_owned = 0
	for k in buildings_owned:
		buildings_total_owned += int(buildings_owned[k])
	research_levels_total = 0
	for k in research_levels:
		research_levels_total += int(research_levels[k])

	# La production au moment de la sauvegarde sert au calcul hors-ligne. Si elle
	# est absente (save v1 sans ce champ), on la reconstruit depuis l'état courant.
	production_at_save = BigNum.deserialize(d.get("production_at_save", null))
	if production_at_save.is_zero():
		_production_dirty = true
		_recalculate()
		production_at_save = get_production_per_sec()

	_compute_offline_gains()
	_check_achievements()


## Repartir de zéro en conservant l'identité de la sauvegarde.
func hard_reset() -> void:
	_apply_fresh_state()
	stats = STAT_DEFAULTS.duplicate(true)
	_stats_init()
	boost_multiplier = 1.0
	boost_ends_at = 0.0
	boost_started_at = 0.0
	_boost_active = false
	pending_offline = {}
	combo_stacks = 0
	combo_timer = 0.0
	_production_dirty = true
	_click_dirty = true
	_recalculate()
	game_reset.emit()
	save_game()


# ============================================================ cycle de vie / OS

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			_on_backgrounded()
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			_on_foregrounded()
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_WM_GO_BACK_REQUEST:
			save_game()


func _on_session_started() -> void:
	stats["sessions"] = int(stats.get("sessions", 0)) + 1
	_apply_boost_state()
	_configure_services()
	# La production au moment du lancement sert de référence hors-ligne.
	_recalculate()
	production_at_save = get_production_per_sec()
	daily_bonus_changed.emit(is_daily_bonus_available())


## Passe la configuration aux services de synthèse.
##
## Appelé au démarrage et après tout changement depuis l'interface. Le mode
## test AdMob est transmis ici : c'est le seul endroit où il est décidé, et il
## est aussi écrit dans la sauvegarde, pour qu'une session de développement
## reste en mode test même après un redémarrage.
func _configure_services() -> void:
	var ads_settings: Dictionary = config.ads
	Ads.configure(ads_settings)
	Store.configure(config.store)

	# Le mode test vient de ProjectSettings, non du JSON de jeu : un « true »
	# oublié dans la configuration livrerait de vraies annonces en production,
	# ce que Google sanctionne. Un binaire exporté en release force donc le mode
	# test à faux, quoi que dise le fichier.
	var debug_ads := bool(ProjectSettings.get_setting("application/ads_use_test_ads", true))
	if not OS.is_debug_build():
		debug_ads = false
	Ads.configure_plugin(
		str(ProjectSettings.get_setting("application/admob_app_id", "")),
		str(ProjectSettings.get_setting("application/admob_rewarded_unit_id", "")),
		debug_ads)


func _on_backgrounded() -> void:
	# Les gains hors-ligne sont calculés à partir de la production *actuelle*,
	# pas de celle du dernier point de contrôle, sinon acheter juste avant de
	# quitter ne rapporterait rien.
	_recalculate()
	production_at_save = get_production_per_sec()
	save_game()
	_schedule_idle_notification()


func _on_foregrounded() -> void:
	if not is_loaded:
		return
	_compute_offline_gains()
	_recalculate()
	daily_bonus_changed.emit(is_daily_bonus_available())


func _schedule_idle_notification() -> void:
	var notifications: Variant = _service("Notifications")
	if notifications == null:
		return
	var hours := float(config.offline.get("notify_after_hours", 2.0))
	if hours <= 0.0:
		return
	stats["notifications_scheduled"] = int(stats.get("notifications_scheduled", 0)) + 1
	notifications.schedule_idle_reminder(hours * 3600.0, {
		"title": "%s vous attend" % config.title,
		"body": "Vos %s continuaient de produire. Revenez les récupérer." % config.resource_name.to_lower(),
	})


func _service(node_name: String) -> Variant:
	return get_node_or_null("/root/%s" % node_name)


# ======================================================================= achats

func has_no_ads() -> bool:
	return bool(flags.get("no_ads", false))


func grant_store_product(product_id: String) -> void:
	var p := config.store_product(product_id)
	if p.is_empty():
		push_warning("Produit d'achat inconnu : %s" % product_id)
		return
	var grant: Dictionary = p.get("grant", {})
	if grant.has("no_ads"):
		flags["no_ads"] = true
		notify("Pubs supprimées, merci !", "success")
	if grant.has("resources"):
		_grant(BigNum.from_float(float(grant["resources"])), true)
	if grant.has("prestige_points"):
		prestige_points += int(float(grant["prestige_points"]))
		_production_dirty = true
	if grant.has("instant_hours"):
		_grant(get_production_per_sec().mul_float(float(grant["instant_hours"]) * float(grant.get("instant_multiplier", 1.0))), true)
	if grant.has("boost_hours"):
		_apply_boost(float(grant.get("boost_multiplier", 10.0)), float(grant["boost_hours"]))
	_recalculate()
	save_game()


func _apply_boost(multiplier: float, hours: float) -> void:
	var now := Time.get_unix_time_from_system()
	var active := now < boost_ends_at
	boost_multiplier = multiplier if not active else maxf(multiplier, boost_multiplier)
	# Une prolongation repart d'une nouvelle fenêtre : on remet le début à now
	# pour que la barre de progression reste lisible.
	boost_started_at = now if not active else boost_started_at
	boost_ends_at = now + hours * 3600.0
	_boost_active = true
	_production_dirty = true
	_recalculate()
	notify("Surcharge active : production %s pendant %s" % [Fmt.multiplier(boost_multiplier), Fmt.duration(hours * 3600.0)], "success")


## Surcharge temporaire, y compris obtenue via une pub récompensée.
func grant_temporary_boost(multiplier: float, hours: float) -> void:
	_apply_boost(multiplier, hours)


func _apply_boost_state() -> void:
	_boost_active = boost_ends_at > Time.get_unix_time_from_system() and boost_multiplier > 1.0
	if not _boost_active and boost_ends_at > 0.0:
		boost_multiplier = 1.0
		boost_ends_at = 0.0


# ======================================================================== divers

func _ensure_minimum_state() -> void:
	if buildings_owned == null:
		buildings_owned = {}
	if click_upgrades_owned == null:
		click_upgrades_owned = {}
	if research_levels == null:
		research_levels = {}
	if achievements_unlocked == null:
		achievements_unlocked = {}
	stats = _merge_stats(stats)
	flags = _merge_flags(flags)


func _merge_stats(raw: Variant) -> Dictionary:
	var out := STAT_DEFAULTS.duplicate(true)
	if typeof(raw) == TYPE_DICTIONARY:
		for k in (raw as Dictionary):
			out[str(k)] = (raw as Dictionary)[k]
	return out


func _merge_flags(raw: Variant) -> Dictionary:
	var out := {"no_ads": false}
	if typeof(raw) == TYPE_DICTIONARY:
		for k in (raw as Dictionary):
			out[str(k)] = (raw as Dictionary)[k]
	return out


## Les dictionnaires venus du JSON ont des clés String, mais rien ne garantit
## que ce soit le cas partout (un éditeur de save, un script tiers...). On
## normalise une fois pour ne pas découvrir une clé int au milieu d'une boucle.
func _stringify_keys(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src:
		out[str(k)] = src[k]
	return out


func _int_map(src: Variant) -> Dictionary:
	var out := {}
	if typeof(src) != TYPE_DICTIONARY:
		return out
	for k in (src as Dictionary):
		out[str(k)] = int((src as Dictionary)[k])
	return out


func _bool_map(src: Variant) -> Dictionary:
	var out := {}
	if typeof(src) == TYPE_DICTIONARY:
		for k in (src as Dictionary):
			out[str(k)] = bool((src as Dictionary)[k])
	return out
