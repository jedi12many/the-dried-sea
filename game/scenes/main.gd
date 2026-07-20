class_name GameHost
extends Node2D
## The host: owns Registry + all sim systems, builds the placeholder world,
## routes intents. Presentation stays thin — every rule lives in sim/.
## M1 slice: walk, harvest, hand-craft, build, day/night. Placeholder art only.

const TILE := 32
const WORLD := Vector2i(96, 128)
## REEF-FOREST-SPEC §1: WORLD grew 96x64 -> 96x128 by APPENDING south rows.
## NORTH_H is the frozen footprint of the old world — every B1 seeded
## generator (rng seeds 7/11/23) that used to size itself off WORLD.y must
## use NORTH_H instead, or every existing seeded position (nodes, shrines,
## fauna, the stranded pool) silently shifts when the map grows. NEVER change
## this number; it is the byte-identical north half's whole contract.
const NORTH_H := 64
const SCARP_Y := NORTH_H * TILE   # the border scarp's y-line: the old south rim
const SCREEN := Vector2(1280, 720)   # design resolution; modals center on it
const HARVEST_RANGE := 56.0
const ATTACK_RANGE := 44.0
const ATTACK_DAMAGE := 12.0     # bare hands + salvage; tool scaling at M1-end
const ATTACK_STAMINA := 15.0
const LOCAL_PLAYER := 1
const GAME_VERSION := "0.13.1"
const NET_PORT := 7777
# NET: whose deed is this (server sets per intent), and whose screen is this
var acting_pid := 1
var my_pid := 1
var net_mode := "offline"            # offline | server | client
var peers: Dictionary = {}           # peer_id -> pid
var net_players: Dictionary = {}     # username -> pid (persisted)
var next_pid := 1
var avatars: Dictionary = {}         # pid -> Vector2 (server truth of player positions)
var remote_nodes: Dictionary = {}    # pid -> Node2D (client visuals for OTHER players)
var enemy_net_ids: Dictionary = {}   # DSEnemy -> int (server)
var _next_enemy_net_id := 1
var _pos_timer := 0.0
var work_visuals: Dictionary = {}    # works.placed id -> visual Node2D
var _rest_glow: Node2D               # a warm halo on your bound rest point
var _hut_markers: Dictionary = {}    # hut inst_id -> {glow, label} occupancy marker
var _glow_t := 0.0                   # real-time accumulator for the gentle pulse
var _marker_accum := 0.0             # throttle for the (heavier) marker refresh
var sound: SoundKit
var drag_work_id := -1               # click-and-drag: which work is in hand

var registry := Registry.new()
var clock := SimClock.new()
var devotion: DevotionSystem
var village: VillageSystem
var works: WorksSystem
var verdict: VerdictSystem
var sanctum: SanctumSystem
var godhead: GodheadSystem
var beast: BeastSystem
var respawn_bind: Dictionary = {}   # pid -> work inst_id you chose as your rest point (tent/hearth)
var offertory_open := false
var offertory_inst := -1        # which altar the open Offertory is looking at
var offertory_label: Label
var offertory_title: Label
var offertory_items: Array = []  # number key -> item_id map, rebuilt each render
var inventory: InventorySystem
var stats: StatsSystem
var abilities: AbilitiesSystem

# the Six Virtues (character sheet)
var sheet_label: Label
var sheet_open := false
var consumed_hp: Dictionary = {}   # pid -> permanent strength eaten from gods
var cheat_death_used: Dictionary = {}  # pid -> bool (resets at dawn)
var equipped: Dictionary = {}      # pid -> {weapon: item_id, armor: item_id}
var doll_label: Label
var doll_sprite: Node2D
var doll_open := false

var player: DSPlayer
var hud: Label
var hp_bar: ColorRect
var stamina_bar: ColorRect
var vigor_bar: ColorRect
var maren_bar: ColorRect
var halor_godhead_label: Label
var maren_godhead_label: Label
var boss_bar: ColorRect
var boss_name: Label
var daynight: CanvasModulate
var resource_nodes: Array[Area2D] = []
var enemies: Array[DSEnemy] = []
var _minutes_since_hour := 0

# the soul, playable
const INTERACT_RANGE := 56.0
var shrines: Array[Node2D] = []
var survivor: DSVillager               # Anna, the first (kept for compat + tutorial)
var villagers: Array[DSVillager] = []  # additional rescued/stranded survivors
var beasts: Array[DSBeast] = []        # the tamed roster's bodies (VILLAGER-AND-GODHEAD-SPEC Part III)
# THE SHEPHERD'S WAY, offered (Part III §2): ground bait drops. A plain Node2D
# per drop (not a resource_nodes Area2D — bait isn't hit-harvestable by the
# player, and keeping it out of resource_nodes keeps a porter crab's own
# hoovering loop from vacuuming a hound's dinner). meta carries item_id,
# dropper_pid (feed_wild's owner), day_dropped (dawn spoilage), bait_id (its
# own stable id, mirrored to clients the same way beast_system's own ids are).
var baits: Array[Node2D] = []
var _next_bait_id := 1
var village_stock: Dictionary = {}     # the shared storehouse: item_id -> qty
var village_panel: Label
var village_panel_open := false
var village_tab := "roster"   # "roster" | "stores" | "sheet" — [TAB] cycles, [1-9] opens a sheet
var village_sheet_tid := -1   # whose character sheet the "sheet" tab shows
var village_store_page := 0   # stores tab paging ([0] flips), 9 takeable entries per page
var _villager_nid := 100

# THE DRILL-YARD (VILLAGER-AND-GODHEAD-SPEC Part I §1): train a villager's Arms class
var drill_open := false
var drill_inst := -1
var drill_step := "villager"    # "villager" | "class"
var drill_villager_id := -1
var drill_items: Array = []     # numbered choices for the current step

# M3.b: the rename modal (kennel), house-modal style (_make_modal)
var rename_open := false
var rename_beast_id := -1
var rename_items: Array = []   # numbered choices: current name, then the species' namePool

# M3.c: the keystone modal (REEF-FOREST-SPEC §6), house-modal style (_make_modal)
var keystone_open := false
var keystone_boss_id := ""     # which dead boss's ring this kneel-prompt is for
var keystone_items: Array = [] # numbered choices: attuned, living (not guttered/consumed) gods

# CALLINGS — the per-player quest journal
var callings: Dictionary = {}        # pid -> Array of {id, step}
var callings_done: Dictionary = {}   # pid -> Array of calling ids
var journal: Label
var journal_open := false
var _calling_drawn_today := false

# what each class does at work: [station ("" = forager), product, qty, to_village_stock?]
const JOBS := {
	"class-brinewife": ["work-smokehouse", "item-smoked-crab", 2, true],
	"class-salvager": ["work-workbench", "item-salt", 3, false],
	"class-smith": ["work-workbench", "item-bronze-salvage", 2, false],
	"class-reef-runner": ["", "item-driftwood", 2, false],
	"class-warden": ["work-yoke-post", "", 0, false],
}
# the self-managing labor pool: needs, what each task yields, and who's suited
# M3.b (REEF-FOREST-SPEC §3, CRAFT-AND-BUILD-SPEC Part 5): coralwood + reef-iron
# join as villager tasks — modest targets (6 each, below B1's 10-14) since
# they're a B2 want, not survival. "haul" is Vessa's Porter's Post (T2): a
# station-gated task with no forage node at all (same shape as "food", which
# also has no TASK_FORAGE_ITEM entry) — the post itself produces the bonus.
const NEED_TARGETS := {"food": 12, "wood": 14, "salt": 14, "bronze": 10, "coralwood": 6, "reef-iron": 6, "haul": 10}
const TASK_ITEM := {"food": "item-smoked-crab", "wood": "item-driftwood", "salt": "item-salt", "bronze": "item-bronze-salvage",
	"coralwood": "item-coralwood", "reef-iron": "item-reef-iron", "haul": "item-rope"}
const TASK_STATION := {"food": "work-smokehouse", "wood": "", "salt": "work-workbench", "bronze": "work-workbench",
	"coralwood": "", "reef-iron": "", "haul": "work-porters-post"}
const TASK_FORAGE_ITEM := {"wood": "item-driftwood", "salt": "item-salt", "bronze": "item-bronze-salvage",
	"coralwood": "item-coralwood", "reef-iron": "item-reef-iron"}   # tasks that gather from world nodes
# RISK: how far a villager ventures scales with how badly the village needs it.
# Full stores — work only what's near home (surplus, safe, feeds the gods).
# Empty stores — range far out into the flats, past warden cover, and chance it.
const FORAGE_LEASH_NEAR := 360.0
const FORAGE_LEASH_FAR := 1100.0
# M3.b: the reef band sits south of the scarp, ~1150-3000px from a north-built
# hearth — well past B1's 1100 max leash. A separate, much longer ceiling for
# reef tasks ONLY (see _task_leash) means the risk-leash still starts at the
# SAME near-360 comfort floor (a well-stocked village never sends anyone near
# the Stair), and only true desperation stretches it far enough to cross —
# "the leash was always the reef's tutorial" (REEF-FOREST-SPEC §3, verbatim).
const REEF_LEASH_FAR := 5200.0   # generous — exceeds the world's own diagonal (~5120px), so desperation always finds SOME reef node from anywhere in the village
const REEF_TASKS := ["coralwood", "reef-iron"]
const SURPLUS_PRIORITY := 0.12   # idle hands feed no gods: near nodes get worked even when full
const TASK_BASE := 2.0
const CLASS_SUIT := {
	"class-reef-runner": {"food": 0.9, "wood": 1.6, "salt": 0.7, "bronze": 0.4, "coralwood": 1.2, "reef-iron": 0.9, "haul": 1.3},
	"class-salvager": {"food": 0.5, "wood": 0.9, "salt": 1.6, "bronze": 1.1, "coralwood": 0.6, "reef-iron": 0.9, "haul": 0.6},
	"class-smith": {"food": 0.4, "wood": 0.5, "salt": 1.0, "bronze": 1.6, "coralwood": 0.5, "reef-iron": 1.3, "haul": 0.4},
	"class-brinewife": {"food": 1.6, "wood": 0.5, "salt": 0.7, "bronze": 0.3, "coralwood": 0.4, "reef-iron": 0.3, "haul": 0.5},
	"class-warden": {"food": 0.6, "wood": 0.6, "salt": 0.6, "bronze": 0.5, "coralwood": 0.5, "reef-iron": 0.5, "haul": 0.5},
}
const NAME_POOL := ["Bex", "Corin", "Del", "Enna", "Fisk", "Goro", "Hale", "Isa",
	"Joss", "Kael", "Lorn", "Mira", "Nils", "Orla", "Perr", "Renn", "Sable", "Tovin"]
const CLASS_POOL := ["class-brinewife", "class-salvager", "class-smith", "class-reef-runner", "class-warden"]
const TRAIT_POOL := ["trait-devout", "trait-agnostic", "trait-industrious", "trait-idle",
	"trait-storyteller", "trait-surly", "trait-night-owl", "trait-bitter", "trait-keen-eyes", "trait-forge-sense"]
var chapels: Dictionary = {}          # god_id -> position
var attuned: Dictionary = {}          # pid -> Array[String]
var rites_done_today: Dictionary = {} # god_id -> bool
var petrify: Dictionary = {}           # pid -> frames; petrify_frames mirrors MY pid for display
var petrify_frames := 0
var message := "Something pale stands in the north flats. It looks like it is waiting."
var menu_label: Label
var menu_title: Label       # the framed header of the craft/build modal
var menu_open := false
var modals: Dictionary = {}   # name -> {root, panel, title, body, footer}
var menu_mode := "build"   # "build" | "craft"
var menu_page := 0          # pages of 9; [0] key advances (recipes can exceed 9)
const MENU_PER_PAGE := 6   # build rows are 3 lines each; 6 fit the modal, longer lists page with [0]

# the camp: the first structure plants it; everything after builds within the ring
const CAMP_RADIUS := 320.0
var camp_center := Vector2.INF
var camp_ring: Line2D

# persistence
var save_path := "user://dried-sea-save.json"
var skip_autoload := false        # tests and --fresh runs start clean
var harvested_indices: Array = [] # which resource nodes are gone
# M3.c (REEF-FOREST-SPEC §9/§6, data bug 2): was a single global `boss_dead`
# bool — fine with one boss, wrong with two. Now per-boss, keyed by creature
# id. Save migration (load_game): an old save's `boss_dead: true` (the only
# boss that ever existed then) migrates to {"creature-old-shellback": true}.
var bosses_dead: Dictionary = {}   # creature_id -> bool
var keystones_claimed: Dictionary = {}   # creature_id -> bool (REEF-FOREST-SPEC §6)
var node_defs: Array = []         # deterministic layout: storms respawn from this
var _static_node_def_count := 0   # M3.a: set once boot-time world-gen (both bands) finishes; _world_sync's extra_defs only needs to ride indices minted AFTER this (boss hoard, corpse drops) — the deterministic base regenerates identically client-side for free

# the great storm (every 4th day; Maren's country)
const STORM_GLASS_IDX_BASE := 1000  # ephemeral nodes: never persisted
var storm_flash := 0.0

# THE LIGHTHOUSE-KEEPER'S LANTERN (B1 legend #2, the Harpoon's template):
# verse 1 rides intent_kneel (Halor's shrine); verse 2 is the marked wreck below;
# verse 3 rides _storm_dawn (surviving a great-storm day). Per-player, like the
# harpoon-verses — the world piece (the wreck) never depletes, so the grant is
# tracked per pid instead of by the item leaving the world.
const LANTERN_WRECK_POS := Vector2(TILE * 10, TILE * 26)  # the westernmost of the three beached wrecks in _build_ground()
var lantern_wreck_inspected: Dictionary = {}   # pid -> bool
var lantern_verse3_taken: Dictionary = {}      # pid -> bool
var tide_bell_rang_today := false              # Neris's Tide-Bell: rang at 06:00 or 18:00 today

# M3.b: Ghal's Blood-Scent — same server-truth/client-display-mirror shape as
# `petrify`/`petrify_frames` above (frame-counted, ticked in _physics_process,
# mirrored per-player via _player_state/cl_player_state).
var blood_scent: Dictionary = {}   # pid -> frames remaining
var blood_scent_frames := 0        # mirrors MY pid for display (HUD bearing line)
# a caster's facing direction, for a remote (server-side) acting_pid that has
# no local `player` Node to read .facing off — tracked from the position
# stream's own deltas (srv_pos). The LOCAL player's own facing is read straight
# off player.facing instead (see _acting_facing()); this dict only matters in
# co-op, for a client OTHER than the one this instance renders.
var _pid_facing: Dictionary = {}   # pid -> Vector2 (last-seen movement direction)
var _effect_note := ""             # _apply_effect's out-of-band extra line (intent_cast's
                                    # own message overwrite happens after every effect
                                    # runs — this survives it; see intent_cast)

# CALLINGS — the anchor registry (WORLD-SPEC "Callings", step params vocabulary):
# stable names a goto/escort/talk step's params can name, resolved to a world
# position at query time (some are fixed, some track dynamic state). The three
# beached wrecks mirror _build_ground()'s layout (LANTERN_WRECK_POS is the west
# one already); boss-ring is Old Shellback's ground from _spawn_enemies().
const WRECK_MID_POS := Vector2(TILE * 30, TILE * 27)
const WRECK_EAST_POS := Vector2(TILE * 38, TILE * 8)
const BOSS_RING_POS := Vector2(TILE * 5, TILE * 5)
# the fixed south-deep point — pinned to the OLD world's south rim (NORTH_H,
# never WORLD.y): REEF-FOREST-SPEC §1, "now ON the scarp — poetic, correct,
# zero content breakage."
const TRENCH_EDGE_POS := Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE - TILE * 1.5)
# the Stair of Hulls: the ~6-tile gap in the scarp, dead center — the ONLY
# crossing (REEF-FOREST-SPEC §1). "stair-of-hulls" calling anchor + HUD bearing.
const STAIR_GAP_HALF := TILE * 3.0
const STAIR_OF_HULLS_POS := Vector2(WORLD.x * TILE / 2.0, SCARP_Y)
var brine_pools: Array[Vector2] = []   # tracked in _build_ground() so "brine-pool" can resolve to the nearest one
var scarp_crossed := false   # world-level, one-shot (REEF-FOREST-SPEC §1 the crossing); persists in the save

# --- the Reef Forest band (REEF-FOREST-SPEC §1/§4/M3.a): its own seeded pass,
# appended after every north generator, touching NONE of their rng state or
# positions. Node/deco counts are tuning, not law — the seed is what's law.
const SOUTH_BAND_SEED := 2200
const SOUTH_ENEMY_SEED := 2300
const SOUTH_NODE_COUNTS := {
	"item-coralwood": 10, "item-reef-iron": 8, "item-pearl": 5, "item-anemone-silk": 6,
}

# M3.c (REEF-FOREST-SPEC §2/§4): the dark. NIGHT-ONLY, non-boss reef creatures
# don't exist by day at all — spawned wholesale at dusk, despawned wholesale
# at dawn (_sync_night_creatures), a SEPARATE seeded pass from every other
# spawn above (SOUTH_ENEMY_SEED's eel-wolves/urchin-backs are unaffected —
# "night spawns are their own pass"). Counts are data-driven off any
# creature.nightOnly flag (_night_creature_spawn_list) so a future B3 nightOnly
# creature gets the same on/off behavior for free; the counts themselves are
# first-guess code consts here, same convention as SOUTH_EEL_WOLF_COUNT etc.
# above — "many" (Drowned) vs "fewer, ambush" (angler-stalkers), per WORLD-SPEC.
const NIGHT_CREATURE_SEED := 2500
const NIGHT_CREATURE_COUNTS := {"creature-the-drowned": 6, "creature-angler-stalker": 4}
const NIGHT_CREATURE_DEFAULT_COUNT := 4   # any future nightOnly creature not yet tuned by name
var night_creatures: Array[DSEnemy] = []
var _night_creatures_active := false
# the stalker's false-glow decoy (REEF-FOREST-SPEC §4/B): client visual + a HUD
# tell (_direction_hints), "pathing bait rather than a creature" — a bare
# Node2D near the stalker, not a DSEnemy (it has no AI, no collision, no HP).
# The Lantern's glow reveals it within its radius (_lure_is_revealed) — the
# trinket's promised payoff, "the dark biomes respect it."
var angler_lures: Array[Node2D] = []
const LURE_OFFSET := Vector2(36.0, -22.0)   # "placed near the stalker" — not on top of it
const SOUTH_CANOPY_PILLAR_COUNT := 22
const SOUTH_EEL_WOLF_COUNT := 5
const SOUTH_URCHIN_BACK_COUNT := 6
# three drowned-town ruin clusters (deco only this slice — M3.d houses their
# content); named now so later anchors/callings have somewhere real to point.
const DROWNED_RUIN_1_POS := Vector2(TILE * 14, TILE * 84)
const DROWNED_RUIN_2_POS := Vector2(TILE * 74, TILE * 96)
const DROWNED_RUIN_3_POS := Vector2(TILE * 40, TILE * 118)

# M3.b (REEF-FOREST-SPEC §5): Vessa's and Ghal's fallen shrines, deterministic
# constants like every other shrine (NOT seeded-random — no spawn-count change).
# Both south of SCARP_Y, well apart from each other and from the Stair of Hulls
# (WORLD.x*TILE/2, SCARP_Y): Vessa west and shallow (~1600px from the Stair, the
# roads-and-currents god closer to the gate she watches travelers use), Ghal
# east and deep (~2050px from the Stair, the wild proper — his country is the
# far end of the band). Distance between the two: ~2640px.
const VESSA_SHRINE_POS := Vector2(TILE * 8, NORTH_H * TILE + TILE * 30)
const GHAL_SHRINE_POS := Vector2(WORLD.x * TILE - TILE * 8, NORTH_H * TILE + TILE * 50)

# M3.c (REEF-FOREST-SPEC §4/§6): the Anglermother's fixed reef arena — deep in
# the band, well clear of every other anchor (>700px from the nearest: the
# Stair, both M3.b shrines, the drowned-town ruin clusters). A DETERMINISTIC
# constant like the other named anchors above, not seeded-random — her ring,
# the keystone kneel-spot, and the arena-darkness override (_tint_for_minute)
# all want one stable position that exists from world-gen regardless of the
# hour (she is dormant by day at this same spot, never despawned — see
# enemy.gd is_attackable/_physics_process).
const ANGLERMOTHER_RING_POS := Vector2(TILE * 60, TILE * 108)
const ANGLERMOTHER_ARENA_RADIUS := 420.0   # first guess: a fight-sized clearing, well inside her boss-leash range

# M3.c §6: every boss ring that can carry a keystone. Shellback's is here even
# though he predates keystones entirely — REEF-FOREST-SPEC's own instruction
# ("the game pays its debts"): an unclaimed dict entry just means "not yet
# claimed", which is exactly what an old world that never had the chance IS.
const KEYSTONE_RINGS := {
	"creature-old-shellback": BOSS_RING_POS,
	"creature-anglermother": ANGLERMOTHER_RING_POS,
}

# STYLE-BIBLE salt-shallows palette (placeholder blocks, right colors)
const ITEM_COLORS := {
	"item-driftwood": Color("a08768"), "item-wreck-timber": Color("6e5138"),
	"item-ship-cloth": Color("d9d2bf"), "item-salt": Color("f2efe8"),
	"item-bronze-salvage": Color("b87333"), "item-rope": Color("8a7a5c"),
	# STYLE-BIBLE Reef Forest sub-palette: muted purples, bone-white coral,
	# teal shadow, pearl glints (cold-palette bias — these are "left things").
	"item-coralwood": Color("8a7a9c"), "item-reef-iron": Color("5c6b6a"),
	"item-pearl": Color("e8e2e8"), "item-anemone-silk": Color("b9a8c9"),
}

func _ready() -> void:
	_setup_input()
	var args := OS.get_cmdline_user_args()
	if "--fresh" in args:
		skip_autoload = true
	if "--server" in args:
		net_mode = "server"
	for a: String in args:
		if a.begins_with("--connect="):
			net_mode = "client"
			_net_connect_addr = a.trim_prefix("--connect=")
	if not registry.load_all():
		push_error("registry failed: %s" % ", ".join(registry.load_errors))
		get_tree().quit(1)
		return
	devotion = DevotionSystem.new(registry)
	village = VillageSystem.new(registry)
	works = WorksSystem.new(registry, devotion)
	verdict = VerdictSystem.new(registry)
	sanctum = SanctumSystem.new(registry)
	godhead = GodheadSystem.new(registry)
	beast = BeastSystem.new(registry)
	# announce an instinct the moment it ignites (villager Arms talents surface
	# passively in the sheet instead — beasts get the immediate line because
	# there's no sheet moment as satisfying as "Fang has learned: Deathgrip")
	beast.instinct_ignited.connect(func(id: int, instinct_id: String) -> void:
		var rec: Dictionary = beast.beasts.get(id, {})
		if rec.is_empty():
			return
		for ins: Dictionary in registry.get_entity(str(rec.creature_id)).get("tame", {}).get("instincts", []):
			if str(ins.id) == instinct_id:
				_message_to(int(rec.owner_pid), "%s has learned: %s — %s" % [str(rec.name), str(ins.name), str(ins.text)])
				return)
	# the Salt Shallows test world = one biome keystone down -> cap 40% (VILLAGER-
	# AND-GODHEAD-SPEC Part II §1). Reef Forest / the Drop arrivals raise this to
	# 2 / 3 later (cap 70% / 100%) — presentation will call set_biomes_cleared()
	# again wherever a biome keystone death is recorded.
	godhead.set_biomes_cleared(1)
	sanctum.offense_laid.connect(func(p: int, god_id: String, _item: String) -> void:
		verdict.record(p, "gods", -3.0, "an offense laid before %s" % god_id, clock.day)
		godhead.offense_laid(god_id)   # the Offertory's `offends` lane gets teeth (Part II §3)
		message = "%s turns from the altar. The flats remember what you laid there." % str(registry.get_entity(god_id).name)
		_refresh_hud())
	inventory = InventorySystem.new(registry)
	stats = StatsSystem.new()
	stats.register(acting_pid, 60.0, 60.0)   # unfed floor — food raises the ceiling
	abilities = AbilitiesSystem.new(registry)
	abilities.earn(acting_pid, 6)            # the flats have already tempered you a little
	abilities.changed.connect(func(p: int) -> void: _recompute_vitals(p))
	devotion.ledger_event.connect(func(p: int, l: String, a: float, n: String) -> void: verdict.record(p, l, a, n, clock.day))
	village.ledger_event.connect(func(l: String, a: float, n: String) -> void: verdict.record(acting_pid, l, a, n, clock.day))

	_build_ground()
	_spawn_resource_nodes()
	_spawn_south_band()
	player = DSPlayer.new()
	player.position = Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)
	add_child(player)
	_attach_camera()
	_spawn_enemies()
	_spawn_shrines()
	_spawn_survivor()
	clock.sim_day.connect(_on_sim_day)
	daynight = CanvasModulate.new()
	add_child(daynight)
	_build_hud()
	sound = SoundKit.new()
	add_child(sound)
	clock.sim_minute.connect(_on_sim_minute)
	_refresh_hud()

	if not skip_autoload and net_mode != "client" and FileAccess.file_exists(save_path):
		load_game()
	if net_mode == "server":
		_start_server()
	elif net_mode == "client":
		_start_client()
	elif _active_callings(acting_pid).is_empty() and _done_callings(acting_pid).is_empty():
		_draw_calling(acting_pid)   # a first calling, to show the journal exists
	if net_mode != "server":
		player.set_display_name(_local_display_name())   # your name over your own head
	if "--screenshot-sheet" in OS.get_cmdline_user_args():
		abilities.earn(acting_pid, 6)
		for i in 4:
			abilities.allocate(acting_pid, "virtue-grit")
		for i in 3:
			abilities.allocate(acting_pid, "virtue-hunger")
		_toggle_sheet(true)
		_screenshot_and_quit()
	elif "--screenshot-craft" in OS.get_cmdline_user_args():
		for it: String in ["item-driftwood", "item-rope", "item-bronze-salvage", "item-wreck-timber", "item-salt", "item-crab-meat"]:
			inventory.add(acting_pid, it, 8)
		works.place("work-workbench", acting_pid, player.position + Vector2(40, 0))
		_toggle_menu(true, "craft")
		_screenshot_and_quit()
	elif "--screenshot-build" in OS.get_cmdline_user_args():
		attuned_for(acting_pid).append("god-halor")
		_toggle_menu(true, "build")
		_screenshot_and_quit()
	elif "--screenshot-journal" in OS.get_cmdline_user_args():
		attuned_for(acting_pid).append("god-halor")
		_active_callings(acting_pid).append({"id": "calling-the-letter-still-walking", "step": "s3"})
		_toggle_journal(true)
		_screenshot_and_quit()
	elif "--screenshot-taken" in OS.get_cmdline_user_args():
		var raider: DSEnemy = null
		for e in enemies:
			if is_instance_valid(e) and e.creature_id == "creature-raider":
				raider = e
				break
		if raider != null:
			raider.surrender()
			player.position = raider.position
			intent_capture(raider)
			player.position = camp_center if camp_center != Vector2.INF else Vector2(WORLD.x*TILE/2, NORTH_H*TILE/2)
			for v: DSVillager in villagers:
				if v.is_captive:
					v.position = player.position + Vector2(50, 0)
		_toggle_village(true)
		_screenshot_and_quit()
	elif "--screenshot-offertory" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-salt", 12)
		inventory.add(acting_pid, "item-wreck-timber", 10)
		inventory.add(acting_pid, "item-bronze-salvage", 4)
		# offerings come from the community stores now
		village_stock["item-salt"] = 15
		village_stock["item-smoked-crab"] = 6
		village_stock["item-storm-glass"] = 2
		village_stock["item-crab-meat"] = 3
		village_stock["item-wreck-timber"] = 2
		inventory.add(acting_pid, "item-remnant-shellback", 1)
		_harness_found_village()
		intent_build("work-altar-halor")
		var alt := sanctum.altar_for("god-halor")
		intent_sanctum(alt, "item-salt")
		intent_sanctum(alt, "item-remnant-shellback")
		_toggle_offertory(true, alt)
		_screenshot_and_quit()
	elif "--screenshot-village" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-wreck-timber", 20)
		inventory.add(acting_pid, "item-salt", 20)
		_harness_found_village()
		intent_build("work-workbench")
		intent_build("work-smokehouse")
		survivor.rescue()
		survivor.position = village_heart()
		var _spread := 0
		for v: DSVillager in villagers:
			v.def_class = ["class-salvager", "class-brinewife", "class-smith", "class-reef-runner"][villagers.find(v) % 4]
			v.rescue()
			_spread += 1
			v.position = village_heart() + Vector2(cos(_spread * 1.3), sin(_spread * 1.3)) * (56.0 + _spread * 14.0)
		village_stock["item-smoked-crab"] = 4
		village.tribesmen[survivor.tribesman_id].bloomed = true
		_on_sim_day(1)
		_toggle_village(true)
		_screenshot_and_quit()
	elif "--screenshot-village-stores" in OS.get_cmdline_user_args():
		_harness_found_village()
		# a deliberately long, varied inventory — the case that used to run off the panel
		village_stock = {"item-driftwood": 12, "item-wreck-timber": 22, "item-salt": 34,
			"item-bronze-salvage": 9, "item-rope": 6, "item-ship-cloth": 3, "item-storm-glass": 2,
			"item-smoked-crab": 15, "item-crab-meat": 4, "item-salt-ration": 5, "item-driftwood-club": 1}
		survivor.rescue()
		_toggle_village(true)
		village_tab = "stores"
		_render_village()
		_screenshot_and_quit()
	elif "--screenshot-home" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-salt", 8)
		inventory.add(acting_pid, "item-wreck-timber", 12)
		inventory.add(acting_pid, "item-driftwood", 12)
		inventory.add(acting_pid, "item-ship-cloth", 4)
		_harness_found_village()
		var heart := work_pos("work-hearth")
		# bind the hearth as your rest point — it should glow
		for hid: Variant in works.placed:
			if str(works.placed[hid].work_id) == "work-hearth":
				respawn_bind[acting_pid] = int(hid)
		player.position = heart + Vector2(90, 30)
		intent_build("work-driftwood-cot")   # a hut, off to the side
		# rescue folk and tuck in whoever the hut actually has a bunk for
		survivor.rescue()
		for v: DSVillager in villagers:
			v.rescue()
		for v: DSVillager in all_villagers():
			if house_slot_for(v) != Vector2.INF:
				v.housed = true
				v.visible = false
		clock.minute_of_day = 22 * 60
		player.position = heart
		_screenshot_and_quit()
	elif "--screenshot-doll" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-bronze-knife", 1)
		inventory.add(acting_pid, "item-salt-cloak", 1)
		inventory.add(acting_pid, "item-driftwood-club", 1)
		inventory.add(acting_pid, "item-smoked-crab", 3)
		inventory.add(acting_pid, "item-salt", 12)
		equip_toggle(acting_pid, "item-bronze-knife")
		equip_toggle(acting_pid, "item-salt-cloak")
		_toggle_doll(true)
		_screenshot_and_quit()
	elif "--screenshot-camp" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-wreck-timber", 12)
		inventory.add(acting_pid, "item-rope", 4)
		inventory.add(acting_pid, "item-driftwood", 40)
		_harness_found_village()                  # the hearth plants the camp ring
		intent_build("work-workbench")
		# lay an L of wall: two horizontal, then a rotated vertical turning the corner
		var base := camp_center + Vector2(0, 120)
		for i in 3:
			player.position = base + Vector2(i * 34 - 40, 0)
			intent_build("work-driftwood-wall")
		for j in 3:
			player.position = base + Vector2(28, j * 30 - 40)
			intent_build("work-driftwood-wall")
			var last := works._next_id - 1
			_rotate_work(last)   # turn the side pieces upright
		player.position = base + Vector2(-10, 10)
		_screenshot_and_quit()
	elif "--screenshot-boss" in OS.get_cmdline_user_args():
		player.position = Vector2(TILE * 9.0, TILE * 7.0)
		_screenshot_and_quit()
	elif "--screenshot-drill" in OS.get_cmdline_user_args():
		inventory.add(acting_pid, "item-wreck-timber", 8)
		inventory.add(acting_pid, "item-rope", 4)
		inventory.add(acting_pid, "item-salt", 10)
		inventory.add(acting_pid, "item-bronze-salvage", 2)
		_harness_found_village()
		intent_build("work-drill-yard")
		survivor.rescue()
		village.tribesmen[survivor.tribesman_id].faith = 60.0
		survivor.def_patron = "god-halor"
		var drill_inst_id := -1
		for iid: Variant in works.placed:
			if str(works.placed[iid].work_id) == "work-drill-yard":
				drill_inst_id = int(iid)
		player.position = work_pos("work-drill-yard")
		_toggle_drill(true, drill_inst_id)
		_screenshot_and_quit()
	elif "--screenshot" in OS.get_cmdline_user_args():
		_screenshot_and_quit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not skip_autoload:
		save_game()

## --- persistence: the flats remember -------------------------------------------
func save_game() -> void:
	if net_mode == "client":
		return  # the server owns the world
	var s := SaveSystem.to_save(clock, devotion, village, works, verdict, godhead, beast)
	s["game"] = {
		"inventory": inventory.inventories.duplicate(true),
		"player_stats": stats.actors.get(acting_pid, {}).duplicate(true),
		"player_pos": [player.position.x, player.position.y],
		"attuned": attuned.duplicate(true),
		"chapels": _chapels_to_dict(),
		"camp": [camp_center.x, camp_center.y] if camp_center != Vector2.INF else null,
		"rites_done_today": rites_done_today.duplicate(),
		"harvested_indices": harvested_indices.duplicate(),
		"bosses_dead": bosses_dead.duplicate(),
		"keystones_claimed": keystones_claimed.duplicate(),
		"abilities": abilities.state.duplicate(true),
		"consumed_hp": consumed_hp.duplicate(true),
		"equipped": equipped.duplicate(true),
		"net_players": net_players.duplicate(), "next_pid": next_pid,
		"survivor": {"rescued": survivor.rescued if survivor != null else false,
			"tribesman_id": survivor.tribesman_id if survivor != null else -1,
			"pos": [survivor.position.x, survivor.position.y] if survivor != null else [0, 0]},
		"pool": villagers.map(func(v: DSVillager) -> Dictionary:
			return {"nid": int(v.get_meta("nid", 0)), "rescued": v.rescued, "tid": v.tribesman_id,
				"cls": v.def_class, "job": v.job_work_id, "x": v.position.x, "y": v.position.y,
				"name": v.display_name, "traits": v.def_traits, "patron": v.def_patron,
				"captive": v.is_captive, "held": v.days_held, "task": v.task, "help": v.needs_help,
				"warm": v.warden_weapon, "warr": v.warden_armor,
				"on_road": v.on_road, "comp_pid": v.companion_pid}),
		"villager_nid": _villager_nid,
		"village_stock": village_stock.duplicate(),
		"callings": callings.duplicate(true),
		"callings_done": callings_done.duplicate(true),
		"respawn_bind": respawn_bind.duplicate(),
		"baits": baits.map(func(n: Node2D) -> Dictionary:
			return {"id": int(n.get_meta("bait_id")), "item": str(n.get_meta("item_id")),
				"x": n.position.x, "y": n.position.y, "pid": int(n.get_meta("dropper_pid")),
				"day": int(n.get_meta("day_dropped"))}),
		"node_left": _node_left_dict(),
		"sanctum": sanctum.to_save(),
		"message": message,
		"lantern_wreck_inspected": lantern_wreck_inspected.duplicate(),
		"lantern_verse3_taken": lantern_verse3_taken.duplicate(),
		"tide_bell_rang_today": tide_bell_rang_today,
		# M3.a migration (REEF-FOREST-SPEC §1): world_size records the map this
		# save was written against. World-gen itself never reads the save (see
		# _ready() — _build_ground/_spawn_resource_nodes/_spawn_south_band/
		# _spawn_enemies all run unconditionally, before load_game() is ever
		# called), so a pre-band save needs no special generation step — the
		# south band is already standing by the time load_game() runs. This
		# field is the record of that fact, and how _save_predates_band() detects one.
		"world_size": [WORLD.x, WORLD.y],
		"scarp_crossed": scarp_crossed,
		# beast_system.to_save() (via SaveSystem above) carries the roster + trust
		# ledgers; this is the presentation-only overlay it doesn't know about —
		# position, the porter's own bag, and the downed timer (same law as
		# villager companions: HP itself is NOT persisted, same precedent as the pool above).
		"beast_pool": beasts.map(func(b: DSBeast) -> Dictionary:
			return {"id": b.beast_id, "x": b.position.x, "y": b.position.y,
				"bag": b._porter_bag.duplicate(), "downed": b.downed, "downed_until": b.downed_until}),
	}
	SaveSystem.write_file(save_path, s)

## REEF-FOREST-SPEC §1 migration detection: true when `g` (the save's "game"
## dict) predates the Reef Forest band — no world_size at all, or one shorter
## than today's WORLD. World-gen doesn't branch on this (see _ready(): it's
## unconditional, both bands, every boot) — it only gates the one-time
## welcome line in load_game() above.
func _save_predates_band(g: Dictionary) -> bool:
	var ws: Array = g.get("world_size", [WORLD.x, NORTH_H])
	var saved_h := int(ws[1]) if ws.size() > 1 else NORTH_H
	return saved_h < WORLD.y

func load_game() -> void:
	var s := SaveSystem.read_file(save_path)
	if s.is_empty():
		return
	SaveSystem.apply(s, clock, devotion, village, works, verdict, godhead, beast)
	var g: Dictionary = s.get("game", {})
	inventory.inventories = SaveSystem._int_keys(g.get("inventory", {}))
	if g.has("player_stats"):
		stats.actors[acting_pid] = g.player_stats
	var pp: Array = g.get("player_pos", [WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0])
	player.position = Vector2(float(pp[0]), float(pp[1]))
	if g.has("attuned"):
		attuned = SaveSystem._int_keys(g.get("attuned", {}))
	else:
		attuned = {1: g.get("attuned_gods", [])}
	net_players = g.get("net_players", {})
	next_pid = int(g.get("next_pid", 1))
	var camp: Variant = g.get("camp", null)
	if camp != null:
		camp_center = Vector2(float(camp[0]), float(camp[1]))
		_update_camp_ring()
	# the ring belongs to the hearth now — if this world has one, center on it
	# (migrates old saves founded by whatever-you-dropped-first)
	if work_pos("work-hearth") != Vector2.INF:
		_recenter_on_hearth()
	rites_done_today = g.get("rites_done_today", {})
	lantern_wreck_inspected = SaveSystem._int_keys(g.get("lantern_wreck_inspected", {}))
	lantern_verse3_taken = SaveSystem._int_keys(g.get("lantern_verse3_taken", {}))
	tide_bell_rang_today = bool(g.get("tide_bell_rang_today", false))
	# REEF-FOREST-SPEC §1 migration: additive. World-gen already ran (both
	# bands — see _ready()) before this function was ever called, so there is
	# nothing left to build; this only restores the one-shot crossing flag,
	# defaulting sanely off godhead's own restored biomes_cleared for a save
	# that predates the flag but somehow already recorded the crossing.
	scarp_crossed = bool(g.get("scarp_crossed", godhead.biomes_cleared() >= 2))
	message = str(g.get("message", "The flats are as you left them."))
	if _save_predates_band(g):
		message += "\nThe world holds more of it now than when you left — south of the old rim, the reef is standing."
	# world state: remove harvested nodes, rebuild work visuals, restore the boss & Anna
	# (JSON floats -> ints: Array.has is TYPE-STRICT — 40 in [40.0] is false)
	harvested_indices = (g.get("harvested_indices", []) as Array).map(func(v: Variant) -> int: return int(v))
	for node in resource_nodes.duplicate():
		if int(node.get_meta("idx", -1)) in harvested_indices:
			resource_nodes.erase(node)
			node.queue_free()
	chapels.clear()
	var chapel_dict: Dictionary = g.get("chapels", {})
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		_spawn_work_visual(int(inst_id), str(inst.work_id), Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))), chapel_dict)
	_recompute_memorial()
	# M3.c migration (data bug 2): a single global boss_dead -> per-boss
	# bosses_dead, keyed by creature id. An old save's boss_dead:true meant
	# Shellback — the only boss that existed then — so it migrates to exactly
	# that entry; a save already on the new shape just carries its dict over.
	if g.has("bosses_dead"):
		bosses_dead = (g.get("bosses_dead", {}) as Dictionary).duplicate()
	else:
		bosses_dead = {"creature-old-shellback": true} if bool(g.get("boss_dead", false)) else {}
	keystones_claimed = (g.get("keystones_claimed", {}) as Dictionary).duplicate()
	if g.has("abilities"):
		abilities.state = SaveSystem._int_keys(g.get("abilities", {}))
	else:
		# pre-Tally save: back-pay everything the flats already owe this player
		var back_pay := 6 + clock.day * 2 + (2 if bosses_dead.get("creature-old-shellback", false) else 0) + (g.get("attuned_gods", []) as Array).size() \
			+ (1 if bool(g.get("survivor", {}).get("rescued", false)) else 0)
		abilities.state[1] = {"earned": back_pay, "alloc": {}}
		message += "\nThe flats have been keeping count: %d TEMPER owed. [T] to spend it." % back_pay
	consumed_hp = SaveSystem._int_keys(g.get("consumed_hp", {})) if g.has("consumed_hp") else {1: float(g.get("consumed_hp_bonus", 0.0))}
	equipped = SaveSystem._int_keys(g.get("equipped", {}))
	_recompute_vitals()
	for e in enemies.duplicate():
		if is_instance_valid(e) and e.is_boss and bool(bosses_dead.get(e.creature_id, false)):
			stats.unregister(e)
			enemies.erase(e)
			e.queue_free()
	# night-only creatures (REEF-FOREST-SPEC §2/§4): re-derive from the loaded
	# clock rather than persisting them — they're fully ephemeral (gone by
	# dawn), so a save/load just needs to re-sync to whatever hour it landed on.
	_night_creatures_active = false
	_sync_night_creatures()
	var sv: Dictionary = g.get("survivor", {})
	if bool(sv.get("rescued", false)) and survivor != null:
		survivor.rescued = true
		survivor.tribesman_id = int(sv.get("tribesman_id", -1))
		survivor.set_label_name()
		var sp: Array = sv.get("pos", [0, 0])
		survivor.position = Vector2(float(sp[0]), float(sp[1]))
	# restore the roster: pool bodies exist from _ready; captured captives are recreated
	village_stock = g.get("village_stock", {})
	callings = SaveSystem._int_keys(g.get("callings", {}))
	callings_done = SaveSystem._int_keys(g.get("callings_done", {}))
	respawn_bind = SaveSystem._int_keys(g.get("respawn_bind", {}))
	_apply_node_left(g.get("node_left", {}))
	sanctum.from_save(g.get("sanctum", {}))
	_villager_nid = maxi(_villager_nid, int(g.get("villager_nid", _villager_nid)))
	for pd: Dictionary in g.get("pool", []):
		var v: DSVillager = null
		for w: DSVillager in villagers:
			if int(w.get_meta("nid", -1)) == int(pd.nid):
				v = w
				break
		if v == null:                       # a captured/dynamic villager — recreate the body
			v = DSVillager.new()
			v.host = self
			v.set_meta("nid", int(pd.nid))
			v.display_name = str(pd.get("name", "someone"))
			v.def_traits = pd.get("traits", [])
			add_child(v)
			villagers.append(v)
		v.def_class = str(pd.get("cls", v.def_class))
		v.def_patron = str(pd.get("patron", "god-halor"))
		v.job_work_id = str(pd.get("job", ""))
		v.position = Vector2(float(pd.x), float(pd.y))
		v.is_captive = bool(pd.get("captive", false))
		v.days_held = int(pd.get("held", 0))
		v.task = str(pd.get("task", ""))
		v.warden_weapon = str(pd.get("warm", ""))
		v.warden_armor = str(pd.get("warr", ""))
		v.on_road = bool(pd.get("on_road", false))
		v.companion_pid = int(pd.get("comp_pid", -1))
		if bool(pd.rescued):
			v.rescued = true
			v.tribesman_id = int(pd.get("tid", -1))
			var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
			v.set_mood(str(rec.get("expression", "steady")))
			if v.on_road:
				stats.register(v, village.villager_max_hp(v.tribesman_id))
		v.set_label_name()
	for b: DSBeast in beasts.duplicate():
		stats.unregister(b)
		beasts.erase(b)
		b.queue_free()
	for bpd: Dictionary in g.get("beast_pool", []):
		var bid := int(bpd.id)
		if not beast.beasts.has(bid):
			continue   # a wild ledger-only entry, or a save from before this beast existed
		var b := _spawn_beast(bid, Vector2(float(bpd.x), float(bpd.y)), false)
		b._porter_bag = (bpd.get("bag", {}) as Dictionary).duplicate()
		b.downed = bool(bpd.get("downed", false))
		b.downed_until = float(bpd.get("downed_until", 0.0))
		b._refresh_label()
	# bait (Part III §2, the Shepherd's Way): ground drops persist across a
	# save/load, same "clear then restore" shape as the beast bodies above.
	for n in baits.duplicate():
		baits.erase(n)
		n.queue_free()
	for btd: Dictionary in g.get("baits", []):
		_spawn_bait_node(str(btd.item), Vector2(float(btd.x), float(btd.y)), int(btd.pid), int(btd.day), int(btd.id))
	_refresh_hud()

## Where the first instance of a work stands (villager duty posts).
func work_pos(work_id: String) -> Vector2:
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		if str(inst.work_id) == work_id:
			return Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	return Vector2.INF

func _chapels_to_dict() -> Dictionary:
	var out := {}
	for god_id: String in chapels:
		out[god_id] = [chapels[god_id].x, chapels[god_id].y]
	return out

func _physics_process(delta: float) -> void:
	_net_tick(delta)
	if net_mode != "client":
		clock.advance(delta)
		stats.tick(delta)
		_tick_healing_bath(delta)
		_check_scarp_crossing(acting_pid, player.position.y)   # the host's own (offline/local-server) player
		for pid: Variant in petrify.keys():
			if int(petrify[pid]) > 0:
				petrify[pid] = int(petrify[pid]) - 1
		for pid: Variant in blood_scent.keys():   # Ghal's Blood-Scent (M3.b), same shape as petrify above
			if int(blood_scent[pid]) > 0:
				blood_scent[pid] = int(blood_scent[pid]) - 1
	if petrify_frames > 0:
		petrify_frames -= 1
		if petrify_frames == 0:
			player.modulate = Color.WHITE
			message = "The salt lets you go. Halor's strength is spent — worship gives it back."
			_refresh_hud()
	if blood_scent_frames > 0:
		blood_scent_frames -= 1
	if storm_flash > 0.0:
		storm_flash = maxf(storm_flash - delta * 2.0, 0.0)
		daynight.color = daynight.color.lerp(Color(1.6, 1.6, 1.7), storm_flash)
	_update_prompt()
	_update_boss_bar()
	_refresh_bars()
	if net_mode != "server":
		_glow_t += delta
		_marker_accum += delta
		if _marker_accum > 0.25:   # structure refresh is throttled; the pulse is per-frame
			_marker_accum = 0.0
			_update_markers()
		_pulse_markers()

## The big red bar appears when you walk into a boss's world.
func _update_boss_bar() -> void:
	if boss_bar == null:
		return
	var near_boss: DSEnemy = null
	for e in enemies:
		if is_instance_valid(e) and e.is_boss and player.position.distance_to(e.position) < 420.0:
			near_boss = e
			break
	var show := near_boss != null
	boss_bar.visible = show
	(boss_bar.get_meta("back") as ColorRect).visible = show
	boss_name.visible = show
	if show:
		var creature := registry.get_entity(near_boss.creature_id)
		boss_name.text = str(creature.name)
		var max_hp := float(creature.get("stats", {}).get("hp", 100))
		boss_bar.size.x = 396.0 * clampf(stats.hp(near_boss) / max_hp, 0.0, 1.0)

## The floating [E] prompt above the survivor's head — mirrors intent_interact's priority.
func _update_prompt() -> void:
	if player == null or player.prompt == null:
		return
	player.prompt.text = current_prompt()

func current_prompt() -> String:
	for s in shrines:
		if player.position.distance_to(s.position) < interact_range() and s.get_meta("god_id") not in attuned_for(my_pid):
			return "[E] Kneel"
	if _keystone_takes_e() != "":
		return "[E] Dedicate the keystone"
	if player.position.distance_to(LANTERN_WRECK_POS) < interact_range() and not lantern_wreck_inspected.get(my_pid, false):
		return "[E] Inspect the wreck"
	if survivor != null and not survivor.rescued and player.position.distance_to(survivor.position) < interact_range():
		return "[E] Rescue her"
	if _offertory_takes_e() >= 0:
		return "[E] The offertory"
	var rest := _rest_point_takes_e()
	if rest >= 0:
		return "(your rest point)" if int(respawn_bind.get(my_pid, -1)) == rest else "[E] Rest here"
	for god_id: String in chapels:
		if acting_pos().distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return "[E] Enshrine the remnant"
			return "[E] Hold the rite" if not rites_done_today.get(god_id, false) else "(rite already held today)"
	var pw := nearest_work(player.position)
	if pw >= 0:
		var winst: Dictionary = works.placed[pw]
		if bool(winst.get("in_use", false)):
			return "(the %s is working)" % str(registry.get_entity(str(winst.work_id)).name).to_lower()
		return "[E] Tend the %s" % str(registry.get_entity(str(winst.work_id)).name).to_lower()
	var best := harvest_range()
	var best_node: Area2D = null
	for node in resource_nodes:
		if is_instance_valid(node) and player.position.distance_to(node.position) < best:
			best = player.position.distance_to(node.position)
			best_node = node
	if best_node != null:
		var item_id := str(best_node.get_meta("item_id"))
		var item_name := str(registry.get_entity(item_id).get("name", ""))
		if int(best_node.get_meta("hits", 1)) > 1:
			var verb := "Cut" if item_id in ["item-driftwood", "item-wreck-timber"] else "Mine"
			return "[E] %s %s (%d left)" % [verb, item_name, int(best_node.get_meta("left", 1))]
		return "[E] Gather %s" % item_name
	for e in enemies:
		if is_instance_valid(e) and player.position.distance_to(e.position) < ATTACK_RANGE:
			return "[SPACE] Attack"
	return ""

func _unhandled_input(event: InputEvent) -> void:
	# click-and-drag placed works: grab, ghost, drop (synced in multiplayer)
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and not menu_open and not sheet_open and net_mode != "server":
		if (event as InputEventMouseButton).pressed:
			var mouse := get_global_mouse_position()
			for inst_id: Variant in work_visuals:
				if is_instance_valid(work_visuals[inst_id]) \
						and (work_visuals[inst_id] as Node2D).position.distance_to(mouse) < 30.0:
					drag_work_id = int(inst_id)
					(work_visuals[drag_work_id] as Node2D).modulate.a = 0.55
					break
		elif drag_work_id >= 0:
			var visual := work_visuals[drag_work_id] as Node2D
			visual.modulate.a = 1.0
			var snapped_pos := (get_global_mouse_position() / 16.0).round() * 16.0
			visual.position = snapped_pos
			if net_mode == "client":
				rpc_id(1, "srv_intent", "move_work", [drag_work_id, snapped_pos.x, snapped_pos.y])
			else:
				_move_work(drag_work_id, snapped_pos)
			drag_work_id = -1
		return
	if event is InputEventMouseMotion and drag_work_id >= 0:
		(work_visuals[drag_work_id] as Node2D).position = (get_global_mouse_position() / 16.0).round() * 16.0
		return
	# right-click a placed piece to spin it 90°; SHIFT+right-click to reclaim it
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT \
			and (event as InputEventMouseButton).pressed and not menu_open and not sheet_open and net_mode != "server":
		var mouse := get_global_mouse_position()
		var demolish := (event as InputEventMouseButton).shift_pressed
		for inst_id: Variant in work_visuals:
			if is_instance_valid(work_visuals[inst_id]) \
					and (work_visuals[inst_id] as Node2D).position.distance_to(mouse) < 30.0:
				var act := "demolish_work" if demolish else "rotate_work"
				if net_mode == "client":
					rpc_id(1, "srv_intent", act, [int(inst_id)])
				elif demolish:
					_demolish_work(int(inst_id))
				else:
					_rotate_work(int(inst_id))
				break
		return
	if journal_open and event is InputEventKey and event.pressed:
		var jkey := (event as InputEventKey).physical_keycode
		if jkey == KEY_ESCAPE or jkey == KEY_J:
			_toggle_journal(false)
			return
		if jkey >= KEY_1 and jkey <= KEY_9:
			if net_mode == "client":
				rpc_id(1, "srv_intent", "journal", [int(jkey - KEY_1)])
			else:
				journal_interact(acting_pid, int(jkey - KEY_1))
			return
	if village_panel_open and event is InputEventKey and event.pressed:
		var vkey := (event as InputEventKey).physical_keycode
		if vkey == KEY_ESCAPE or vkey == KEY_V:
			_toggle_village(false)
			return
		if vkey == KEY_G:
			if net_mode == "client":
				rpc_id(1, "srv_intent", "give_food", [])
			else:
				intent_give_food()
			return
		if vkey == KEY_TAB:
			sfx("ui")
			# from the sheet, TAB goes home to the roster; otherwise it flips roster/stores
			village_tab = "stores" if village_tab == "roster" else "roster"
			_render_village()
			return
		# [1-9] on the stores: take one of that item into your pack (test-era
		# rule, Jeff 2026-07-18: every player has access to the village and
		# its gear — ownership is a later problem). [0] pages.
		if village_tab == "stores" and vkey >= KEY_0 and vkey <= KEY_9:
			if vkey == KEY_0:
				sfx("ui")
				village_store_page += 1
				_render_village()
				return
			var sids := _store_entry_ids()
			var sidx := village_store_page * 9 + int(vkey - KEY_1)
			if sidx < sids.size():
				if net_mode == "client":
					rpc_id(1, "srv_intent", "stores_take", [str(sids[sidx])])
				else:
					intent_stores_take(str(sids[sidx]))
					_render_village()
			return
		# [1-9] on the roster: open that villager's character sheet
		if vkey >= KEY_1 and vkey <= KEY_9 and village_tab == "roster":
			var vroster := all_villagers().filter(func(x: DSVillager) -> bool: return x.rescued and x.tribesman_id >= 0)
			var vidx := int(vkey - KEY_1)
			if vidx < vroster.size():
				sfx("ui")
				village_sheet_tid = (vroster[vidx] as DSVillager).tribesman_id
				village_tab = "sheet"
				_render_village()
			return
	if doll_open and event is InputEventKey and event.pressed:
		var dkey := (event as InputEventKey).physical_keycode
		if dkey >= KEY_1 and dkey <= KEY_9:
			intent_equip_index(int(dkey - KEY_1))
			return
		if dkey == KEY_ESCAPE or dkey == KEY_I:
			_toggle_doll(false)
			return
	if sheet_open and event is InputEventKey and event.pressed:
		var skey := (event as InputEventKey).physical_keycode
		if skey >= KEY_1 and skey <= KEY_6:
			var virtues := registry.all_of("virtue")
			var virtue_id := str(virtues[int(skey - KEY_1)].id)
			if net_mode == "client":
				rpc_id(1, "srv_intent", "deallocate" if (event as InputEventKey).shift_pressed else "allocate", [virtue_id])
			elif (event as InputEventKey).shift_pressed:
				abilities.deallocate(acting_pid, virtue_id)
			else:
				abilities.allocate(acting_pid, virtue_id)
			_toggle_sheet(true)
			return
		if skey == KEY_ESCAPE or skey == KEY_T:
			_toggle_sheet(false)
			return
	if menu_open and event is InputEventKey and event.pressed:
		var key := (event as InputEventKey).physical_keycode
		var options := menu_works() if menu_mode == "build" else craftable_recipes()
		var page_count := int(max(1, ceil(float(options.size()) / MENU_PER_PAGE)))
		if key == KEY_0 and page_count > 1:
			menu_page = (menu_page + 1) % page_count
			if menu_mode == "build":
				_render_build_menu()
			else:
				_render_craft_menu()
			return
		if key >= KEY_1 and key < KEY_1 + MENU_PER_PAGE:   # only the keys this page actually uses
			var idx := menu_page * MENU_PER_PAGE + int(key - KEY_1)
			if idx < options.size():
				if menu_mode == "build":
					intent_build(str(options[idx]))
				else:
					intent_craft(str(options[idx]))
				_toggle_menu(false)
			return
		if key == KEY_ESCAPE or (key == KEY_B and menu_mode == "build") or (key == KEY_C and menu_mode == "craft"):
			_toggle_menu(false)
			return
		# the OTHER menu key falls through to switch modes below
	if offertory_open and event is InputEventKey and event.pressed:
		var okey := (event as InputEventKey).physical_keycode
		if okey >= KEY_1 and okey <= KEY_9:
			var oidx := int(okey - KEY_1)
			if oidx < offertory_items.size():
				var entry: Dictionary = offertory_items[oidx]
				intent_sanctum(offertory_inst, str(entry.id), str(entry.op))
			return
		if okey == KEY_ESCAPE or okey == KEY_E:
			sfx("ui")
			_toggle_offertory(false)
			return
		return   # the altar holds your attention; other keys wait
	if drill_open and event is InputEventKey and event.pressed:
		var dkey := (event as InputEventKey).physical_keycode
		if dkey >= KEY_1 and dkey <= KEY_9:
			var didx := int(dkey - KEY_1)
			if didx < drill_items.size():
				if drill_step == "villager":
					drill_villager_id = int(drill_items[didx])
					drill_step = "class"
					_render_drill()
				else:
					intent_drill_train(drill_villager_id, str(drill_items[didx]))
					_toggle_drill(false)
			return
		if dkey == KEY_ESCAPE:
			if drill_step == "class":
				drill_step = "villager"
				_render_drill()
			else:
				_toggle_drill(false)
			return
		if dkey == KEY_E:
			sfx("ui")
			_toggle_drill(false)
			return
		return   # the yard holds your attention; other keys wait
	if rename_open and event is InputEventKey and event.pressed:
		var rkey := (event as InputEventKey).physical_keycode
		if rkey >= KEY_1 and rkey <= KEY_9:
			var ridx := int(rkey - KEY_1)
			if ridx < rename_items.size():
				intent_rename_beast(rename_beast_id, ridx)
				_toggle_rename(false)
			return
		if rkey == KEY_ESCAPE or rkey == KEY_M:
			sfx("ui")
			_toggle_rename(false)
			return
		return   # the naming holds your attention; other keys wait
	if keystone_open and event is InputEventKey and event.pressed:
		var kkey := (event as InputEventKey).physical_keycode
		if kkey >= KEY_1 and kkey <= KEY_9:
			var kidx := int(kkey - KEY_1)
			if kidx < keystone_items.size():
				intent_dedicate_keystone(keystone_boss_id, kidx)
				_toggle_keystone(false)
			return
		if kkey == KEY_ESCAPE or kkey == KEY_E:
			sfx("ui")
			_toggle_keystone(false)
			return
		return   # the keystone holds your attention; other keys wait
	if event.is_action_pressed("interact"):
		# standing at an altar, E opens the Offertory (the god's inventory);
		# a pending chapel rite that's closer keeps its claim on E
		var altar := _offertory_takes_e()
		if altar >= 0 and not menu_open:
			sfx("ui")
			_toggle_offertory(true, altar)
			return
		var drill := _drill_takes_e()
		if drill >= 0 and not menu_open and altar < 0:
			sfx("ui")
			_toggle_drill(true, drill)
			return
		var keystone_boss := _keystone_takes_e()
		if keystone_boss != "" and not menu_open and altar < 0 and drill < 0:
			sfx("ui")
			_toggle_keystone(true, keystone_boss)
			return
		intent_interact()
	elif event.is_action_pressed("craft"):
		sfx("ui")
		_toggle_menu(not (menu_open and menu_mode == "craft"), "craft")
	elif event.is_action_pressed("build"):
		sfx("ui")
		_toggle_menu(not (menu_open and menu_mode == "build"), "build")
	elif event.is_action_pressed("eat"):
		intent_eat()
	elif event.is_action_pressed("attack"):
		intent_attack()
	elif event.is_action_pressed("cast"):
		intent_cast("inv-pillar-of-salt")
	elif event.is_action_pressed("cast_2"):
		intent_cast("inv-call-squall")
	elif event.is_action_pressed("cast_3"):
		intent_cast("inv-slack-tide")
	elif event.is_action_pressed("cast_4"):
		intent_cast("inv-returning-wave")
	elif event.is_action_pressed("cast_5"):
		intent_cast("inv-rip-current")
	elif event.is_action_pressed("cast_6"):
		intent_cast("inv-undertow")
	elif event.is_action_pressed("cast_7"):
		intent_cast("inv-shepherds-voice")
	elif event.is_action_pressed("cast_8"):
		intent_cast("inv-blood-scent")
	elif event.is_action_pressed("rename_beast"):
		_kennel_rename_takes_key()
	elif event.is_action_pressed("consume"):
		intent_consume_remnant()
	elif event.is_action_pressed("sheet"):
		sfx("ui")
		_toggle_sheet(not sheet_open)
	elif event.is_action_pressed("inventory"):
		sfx("ui")
		_toggle_doll(not doll_open)
	elif event.is_action_pressed("village"):
		sfx("ui")
		_toggle_village(not village_panel_open)
	elif event.is_action_pressed("journal"):
		sfx("ui")
		_toggle_journal(not journal_open)
	elif event.is_action_pressed("give_food"):
		if net_mode == "client":
			rpc_id(1, "srv_intent", "give_food", [])
		else:
			intent_give_food()
	elif event.is_action_pressed("offer_bait"):
		intent_offer_bait()
	elif event.is_action_pressed("save"):
		save_game()
		message = "The flats will remember. (saved)"
		_refresh_hud()

## --- intents (the only door into the sim from presentation) --------------------
## E is contextual: kneel at a shrine, rescue the stranded, hold a rite, else harvest.
func interact_range() -> float:
	return INTERACT_RANGE + abilities.mod_add(acting_pid, "interact-range")

func harvest_range() -> float:
	return HARVEST_RANGE + abilities.mod_add(acting_pid, "interact-range")

func intent_interact() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "interact", [])
		return true
	for s in shrines:
		var god_id: String = s.get_meta("god_id")
		if acting_pos().distance_to(s.position) < interact_range() and god_id not in attuned_for(acting_pid):
			return intent_kneel(god_id)
	if acting_pos().distance_to(LANTERN_WRECK_POS) < interact_range() and not lantern_wreck_inspected.get(acting_pid, false):
		return intent_inspect_wreck()
	# what you're standing ON wins: a chapel's rite before a nearby stranger
	for god_id: String in chapels:
		if acting_pos().distance_to(chapels[god_id]) < interact_range():
			if _carrying_remnant():
				return intent_enshrine(god_id)
			return intent_rite(god_id)
	# BEASTS AT HEEL (Part III): a beaten raider on their knees binds for the
	# yoke; a beaten (kneeling) or ever-peaceful tameable beast feeds instead —
	# two doors off the same "surrendered" state, and an ambient beast (a
	# crab) never needed beating down at all to open its door.
	for e in enemies:
		if not is_instance_valid(e) or acting_pos().distance_to(e.position) >= interact_range():
			continue
		if e.surrendered and e.subduable:
			return intent_capture(e)
		if (e.surrendered or e.peaceful) and not registry.get_entity(e.creature_id).get("tame", {}).is_empty():
			return intent_feed_wild(e)
	# YOUR OWN tamed beast: revive if downed, empty a full porter bag, else
	# toggle the heel/stay slot — checked before the survivor/villager doors
	# so a beast that wandered near a stranger doesn't lose your [E] to them.
	for b: DSBeast in beasts:
		if b.owner_pid == acting_pid and acting_pos().distance_to(b.position) < interact_range():
			return intent_beast_interact(b)
	if survivor != null and not survivor.rescued and acting_pos().distance_to(survivor.position) < interact_range():
		return intent_rescue()
	# a tent or hearth you're standing right on — bind your respawn here
	var rest := _rest_point_takes_e()
	if rest >= 0:
		return intent_set_respawn(rest)
	# a stranded stranger to rescue, or a villager to hear out
	for v: DSVillager in all_villagers():
		if acting_pos().distance_to(v.position) < interact_range():
			if v.is_captive:
				return intent_hold_captive(v)
			if not v.rescued:
				return intent_rescue_villager(v)
			if v.on_road and v.downed:
				return intent_revive_companion(v)
			return intent_interact_villager(v)
	var near_work := nearest_work(acting_pos())
	if near_work >= 0:
		return intent_tend(near_work)
	return intent_harvest()

## A rest point (tent/hearth) claims [E] to set your respawn — but only when it's
## the nearest thing under you, so a villager milling at the hearth still gets your
## [E] to talk when you're right on them. Returns the inst id, or -1.
func _rest_point_takes_e() -> int:
	var best := -1
	var best_d := interact_range()
	for inst_id: Variant in works.placed:
		if not registry.get_entity(str(works.placed[inst_id].work_id)).get("restPoint", false):
			continue
		var inst: Dictionary = works.placed[inst_id]
		var d: float = acting_pos().distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
		if d < best_d:
			best_d = d
			best = int(inst_id)
	if best < 0:
		return -1
	for v: DSVillager in all_villagers():
		if v.rescued and acting_pos().distance_to(v.position) < best_d:
			return -1   # a villager is closer — your [E] is theirs
	return best

## Bind this player's respawn to a rest point. You wake here on death until you
## set another (drop a tent on a far quest, bind it; come home, re-bind the hearth).
func intent_set_respawn(inst_id: int) -> bool:
	respawn_bind[acting_pid] = inst_id
	sfx("ui")
	var work := registry.get_entity(str(works.placed[inst_id].work_id))
	message = "Your rest point is set: the %s. Fall out there and you'll wake here." % str(work.name).to_lower()
	_refresh_hud()
	return true

## The Taken: bind a surrendered raider. They become a captive (origin "taken")
## — grievance and susceptibility maxed, Ur-Noth's easiest tinder — held at your
## yoke-post until you break them or unbind them.
func intent_capture(raider: DSEnemy) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = _villager_nid
	var v := DSVillager.new()
	v.host = self
	_villager_nid += 1
	v.set_meta("nid", _villager_nid)
	v.display_name = NAME_POOL[rng.randi() % NAME_POOL.size()]
	v.def_class = CLASS_POOL[rng.randi() % CLASS_POOL.size()]
	v.def_traits = ["trait-bitter"]
	v.def_patron = ""
	v.position = raider.position
	v.rescued = true
	v.is_captive = true
	v.tribesman_id = village.add_tribesman(v.display_name, v.def_class, "taken", ["trait-bitter"], "", _starting_arms_for(v.def_class))
	add_child(v)
	villagers.append(v)
	stats.unregister(raider)
	enemies.erase(raider)
	raider.queue_free()
	sfx("build")
	message = "You bind %s and march them home. A captive is fast labor and slow poison — the yoke-post holds them.\nBreak them at the Salt-Wheel, or hold them well and Unbind them free." % v.display_name
	_refresh_hud()
	return true

## Interact with a held captive at the yoke-post: Unbind (kind, after patience)
## if no Salt-Wheel, else offer the choice via the panel.
func intent_hold_captive(v: DSVillager) -> bool:
	if works.count_of("work-salt-wheel") > 0 and v.days_held < 3:
		message = "%s glares. Break them at the Salt-Wheel [tend it], or keep them fed and warded %d more day(s) to Unbind them." % [v.display_name, 3 - v.days_held]
	elif v.days_held >= 3:
		village.unbind(v.tribesman_id)
		v.is_captive = false
		v.def_patron = "god-halor"
		assign_job(v)
		v.set_mood("content")
		sfx("bloom")
		message = "You strike the bindings from %s. They stand slowly — and stay, of their own will. The gods mark it." % v.display_name
	else:
		message = "%s is bound (day %d). Fed and warded, they'll come round in %d more day(s) — then Unbind them." % [v.display_name, v.days_held, 3 - v.days_held]
	_refresh_hud()
	return true

## Rescue a stranded survivor (not Anna — the pool strangers).
func intent_rescue_villager(v: DSVillager) -> bool:
	v.rescue()
	abilities.earn(acting_pid, 1)
	var cls := str(registry.get_entity(v.def_class).get("name", "survivor")).to_lower()
	message = "%s, a %s, follows you home. Give them work and a full belly and they'll keep the flats at bay." % [v.display_name, cls]
	_refresh_hud()
	return true

## The [E] verb on a rescued, free villager: talk (unchanged), or — if they
## hold an Arms class and aren't already someone's companion — a second [E]
## on the same visit asks them to walk with you instead of talking again.
func intent_interact_villager(v: DSVillager) -> bool:
	if v.on_road and v.companion_pid == acting_pid:
		return intent_dismiss_companion(v)
	if _recruit_eligible(v):
		if v._recruit_armed:
			return intent_recruit(v)
		v._recruit_armed = true
		intent_talk(v)
		message += "\n[E] them again: 'Walk with me?'"
		_refresh_hud()
		return true
	return intent_talk(v)

func _party_has_room(pid: int) -> bool:
	var cap := int(village.vtune.get("partyCap", 1))
	var n := 0
	for v: DSVillager in all_villagers():
		if v.on_road and v.companion_pid == pid:
			n += 1
	return n < cap

func _recruit_eligible(v: DSVillager) -> bool:
	return v.rescued and not v.is_captive and not v.on_road \
		and village.arms_level(v.tribesman_id) > 0 and _party_has_room(acting_pid)

## Recruit: party cap from tuning (villagers.json partyCap). They pack food
## (a provisioning cost is flavor text at EA — no larder debit yet), drop their
## task, and fall in beside you.
func intent_recruit(v: DSVillager) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "recruit", [int(v.get_meta("nid", 0))])
		return true
	if not _recruit_eligible(v):
		return false
	v.on_road = true
	v.companion_pid = acting_pid
	v.fought_on_road = false
	v._recruit_armed = false
	v.task = ""
	village.tribesmen[v.tribesman_id].on_road = true
	stats.register(v, village.villager_max_hp(v.tribesman_id))
	message = "%s packs food and falls in beside you. 'Walk with me' — and they do." % v.display_name
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## "Stay here" (or walking home and toggling off): back to the task pool at
## the next dawn. A safe return after fighting earns expeditionReturn XP.
func intent_dismiss_companion(v: DSVillager) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "dismiss", [int(v.get_meta("nid", 0))])
		return true
	var at_home := v.position.distance_to(village_heart()) < DSVillager.SETTLE_RADIUS
	if v.fought_on_road and at_home:
		village.grant_xp(v.tribesman_id, "expeditionReturn")
	v.on_road = false
	v.companion_pid = -1
	v.fought_on_road = false
	village.tribesmen[v.tribesman_id].on_road = false
	stats.unregister(v)
	message = "%s stays here." % v.display_name
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## Revive a downed companion at 30% HP — stand over them and press [E].
func intent_revive_companion(v: DSVillager) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "revive", [int(v.get_meta("nid", 0))])
		return true
	if not village.is_downed(v.tribesman_id):
		return false
	village.revive(v.tribesman_id)
	if stats.actors.has(v):
		stats.actors[v].hp = village.villager_max_hp(v.tribesman_id) * 0.3
	v.downed = false
	v.apply_downed_visual()
	message = "%s comes back around." % v.display_name
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## --- BEASTS AT HEEL (VILLAGER-AND-GODHEAD-SPEC Part III) ---------------------
## The Shepherd's Way: feed a peaceful (crab) or kneeling (mercy-beaten hound)
## tameable creature. Always consumes the [E] press with a diegetic result —
## the UI law is "show the numbers," win or not.
func intent_feed_wild(e: DSEnemy) -> bool:
	if net_mode == "client":
		# a client's enemy is a MIRROR — its nid rides as node meta (cl_world_sync),
		# never the server-only enemy_net_ids bookkeeping _enemy_nid() assigns
		rpc_id(1, "srv_intent", "feed_beast", [int(e.get_meta("nid", -1))])
		return true
	if e == null or not is_instance_valid(e):
		return false
	var tm: Dictionary = registry.get_entity(e.creature_id).get("tame", {})
	if tm.is_empty():
		return false
	var wild := abilities.score(acting_pid, "virtue-wild")
	var cname := str(registry.get_entity(e.creature_id).name)
	if not beast.can_tame(wild, e.creature_id):
		var tier := int(tm.get("tier", 1))
		var needed_wild := int(beast.tune.get("wildTierGate", {}).get(str(tier), 999))
		message = "%s watches you, unconvinced — you are not yet quiet enough inside. (Needs WILD %d; you have %d.)" % [cname, needed_wild, wild]
		_refresh_hud()
		return true
	var craved := str(tm.get("cravedFoodItemId", ""))
	if craved == "" or inventory.count(acting_pid, craved) <= 0:
		var want := str(registry.get_entity(craved).get("name", "the right food")) if craved != "" else "anything it wants"
		message = "%s noses at you, hungry — you don't have %s to offer." % [cname, want]
		_refresh_hud()
		return true
	# a same sim-day repeat feed is a no-op on the sim's own trust ledger (the
	# "no farming a full stack in one sitting" decision, beast_system.gd's own
	# comment) — so it must not cost a meal either, or the food vanishes for
	# nothing. Only the FIRST feed of the day pays.
	var nid := _enemy_nid(e)
	var already_fed_today := int(beast.wild_trust.get(nid, {}).get("last_meal_day", -999999999)) == clock.day
	if not already_fed_today:
		inventory.pay(acting_pid, [{"itemId": craved, "qty": 1}])
	var ghal_rank := int(devotion.state.get(acting_pid, {}).get("god-ghal", {}).get("rank", 0))
	var post_boost := 2 if _near_taming_post(acting_pos()) else 1   # M3.b: the Taming-Post doubles this meal's trust
	var result := beast.feed_wild(nid, e.creature_id, acting_pid, clock.day, ghal_rank, post_boost)
	sfx("ui")
	if bool(result.tamed):
		var bid := int(result.id)
		var pos := e.position
		stats.unregister(e)
		enemies.erase(e)
		e.queue_free()
		_spawn_beast(bid, pos, true)
		message = "%s — TAMED. It falls in at your heel." % str(beast.beasts.get(bid, {}).get("name", "Beast"))
	else:
		message = "%s — trust %d/%d." % [cname, int(result.trust), int(result.needed)]
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## The Shepherd's Way, AS THE SPEC NAMES IT FIRST (VILLAGER-AND-GODHEAD-SPEC
## Part III §2): "Drop the species' craved food on the ground and stand off;
## the beast comes, eats, and trusts." Jeff's playtest bug, and the reason
## this exists: a hound/eel-wolf's AGGRO_RADIUS (170px, enemy.gd) outruns
## INTERACT_RANGE (56px) — once one starts chasing you, you can never walk
## back in close enough to hand-feed it via intent_feed_wild above. [O] sets
## down ONE unit of whatever the NEAREST wild tameable beast within reach
## craves — IF you're carrying it — and backs away for you; enemy.gd's own
## AI (not this function) is what actually breaks the beast off its chase to
## come eat it. Always resolves with a diegetic result — same UI law as
## intent_feed_wild: say what happened, numbers and all.
const BAIT_SCAN_RADIUS := 500.0   # "a generous radius" per the brief

func intent_offer_bait() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "offer_bait", [])
		return true
	var pos := acting_pos()
	var nearest: DSEnemy = null
	var nearest_d := BAIT_SCAN_RADIUS
	for e in enemies:
		if not is_instance_valid(e):
			continue
		if registry.get_entity(e.creature_id).get("tame", {}).is_empty():
			continue
		var d := pos.distance_to(e.position)
		if d <= nearest_d:
			nearest_d = d
			nearest = e
	if nearest == null:
		message = "Nothing here wants what you're carrying."
		_refresh_hud()
		return true
	var tm: Dictionary = registry.get_entity(nearest.creature_id).get("tame", {})
	var craved := str(tm.get("cravedFoodItemId", ""))
	var cname_lower := str(registry.get_entity(nearest.creature_id).name).to_lower()
	if craved == "" or inventory.count(acting_pid, craved) <= 0:
		var want := str(registry.get_entity(craved).get("name", "something")).to_lower() if craved != "" else "anything"
		message = "You have nothing a %s would cross the flats for. It wants %s." % [cname_lower, want]
		_refresh_hud()
		return true
	inventory.pay(acting_pid, [{"itemId": craved, "qty": 1}])
	_spawn_bait_node(craved, pos, acting_pid, clock.day)
	sfx("ui")
	var item_name := str(registry.get_entity(craved).name).to_lower()
	message = "You set down %s — a %s might come for it." % [item_name, cname_lower]
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## A ground bait node: NOT added to resource_nodes (it isn't hit-harvestable
## and a porter crab's hoovering loop must not vacuum it). forced_id lets a
## client mirror (cl_world_sync) or a save/load restore reuse the SERVER's
## stable id instead of minting a fresh local one — same reasoning as
## _spawn_beast's bid parameter.
func _spawn_bait_node(item_id: String, pos: Vector2, dropper_pid: int, day: int, forced_id: int = -1) -> Node2D:
	var bid := forced_id
	if bid < 0:
		bid = _next_bait_id
		_next_bait_id += 1
	elif bid >= _next_bait_id:
		_next_bait_id = bid + 1
	var n := Node2D.new()
	n.position = pos
	n.set_meta("bait_id", bid)
	n.set_meta("item_id", item_id)
	n.set_meta("dropper_pid", dropper_pid)
	n.set_meta("day_dropped", day)
	var visual := SpriteKit.sprite(NODE_SPRITES.get(item_id, "none"), Vector2(12, 12), ITEM_COLORS.get(item_id, Color("c9a648")))
	n.add_child(visual)
	add_child(n)
	baits.append(n)
	return n

## enemy.gd's own bait-seeking AI reads this: the nearest bait matching a
## given creature's craved food, within `radius` of `pos`. A hound never
## notices a crab's smoked-crab bait and vice versa — bait only draws the
## species it was actually dropped for.
func nearest_bait_for(pos: Vector2, item_id: String, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for n in baits:
		if not is_instance_valid(n) or str(n.get_meta("item_id", "")) != item_id:
			continue
		var d := pos.distance_to(n.position)
		if d <= best_d:
			best_d = d
			best = n
	return best

## Called by enemy.gd when a bait-seeking beast reaches its bait (~eatRadius).
## The bait is consumed EITHER WAY — an under-WILD dropper's bait still costs
## the food and teaches the gate (can_tame gates the OUTCOME of eating, never
## whether bait gets dropped or eaten at all — see intent_offer_bait, which
## never checks WILD). A qualified dropper's meal runs through the EXACT SAME
## beast.feed_wild the hand-feed path (intent_feed_wild above) uses, so a full
## trust completes the tame identically either way. Either way the beast
## calms briefly afterward (pacify, tuning/beasts.json bait.calmSeconds) —
## the loop should read as trust, not a feeding-frenzy exploit.
func beast_eat_bait(e: DSEnemy, bait_node: Node2D) -> void:
	if not is_instance_valid(bait_node):
		return
	var dropper_pid := int(bait_node.get_meta("dropper_pid", -1))
	var cname := str(registry.get_entity(e.creature_id).name)
	var calm_seconds: float = float(beast.tune.get("bait", {}).get("calmSeconds", 8))
	baits.erase(bait_node)
	bait_node.queue_free()
	var wild := abilities.score(dropper_pid, "virtue-wild")
	if not beast.can_tame(wild, e.creature_id):
		e.pacify(calm_seconds)
		_message_to(dropper_pid, "%s takes the food and pads off, still wild — it isn't yours to keep yet." % cname)
		if net_mode == "server":
			rpc("cl_world_sync", _world_sync())
		return
	var nid := _enemy_nid(e)
	var ghal_rank := int(devotion.state.get(dropper_pid, {}).get("god-ghal", {}).get("rank", 0))
	var post_boost := 2 if _near_taming_post(bait_node.position) else 1   # the Taming-Post doubles a baited meal too
	var result := beast.feed_wild(nid, e.creature_id, dropper_pid, clock.day, ghal_rank, post_boost)
	sfx("ui", e.position)
	if bool(result.tamed):
		var bid := int(result.id)
		var pos := e.position
		stats.unregister(e)
		enemies.erase(e)
		e.queue_free()
		_spawn_beast(bid, pos, true)
		_message_to(dropper_pid, "%s — TAMED. It falls in at your heel." % str(beast.beasts.get(bid, {}).get("name", "Beast")))
	else:
		e.pacify(calm_seconds)
		_message_to(dropper_pid, "%s — trust %d/%d." % [cname, int(result.trust), int(result.needed)])
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Bait spoils at dawn if uneaten (tuning/beasts.json bait.spoilAtDawn) — a
## day_dropped stamp older than today's clock.day means it sat through a full
## night with nobody home for dinner. Own step, same "testable in isolation"
## shape as _dawn_drill_training/_beast_dawn_feeding.
func _bait_spoil_dawn() -> Array[String]:
	var notes: Array[String] = []
	if not bool(beast.tune.get("bait", {}).get("spoilAtDawn", true)):
		return notes
	for n in baits.duplicate():
		if is_instance_valid(n) and int(n.get_meta("day_dropped", clock.day)) < clock.day:
			baits.erase(n)
			n.queue_free()
			notes.append("Yesterday's bait spoiled, untouched.")
	return notes

## Your own tamed beast: revive if downed; else a full porter bag empties to
## your pack first (a second press that same visit toggles heel/stay); else
## toggle the heel slot (cap 1; a sulking, unfed beast refuses the call home).
func intent_beast_interact(b: DSBeast) -> bool:
	if b != null and b.downed:
		return intent_revive_beast(b)
	if net_mode == "client":
		rpc_id(1, "srv_intent", "beast_interact", [b.beast_id if b != null else -1])
		return true
	if b == null or not beast.beasts.has(b.beast_id):
		return false
	var rec: Dictionary = beast.beasts[b.beast_id]
	# hand-feeding a TAMED beast: craved food in pack + they haven't eaten today
	# → the day's meal, by hand. Without this a pre-kennel tame sulks forever
	# with no recourse (the kennel is the automatic path, never the only one).
	var craved := str(registry.get_entity(b.creature_id).get("tame", {}).get("cravedFoodItemId", ""))
	if craved != "" and not bool(rec.fed_today) and inventory.count(acting_pid, craved) > 0:
		inventory.pay(acting_pid, [{"itemId": craved, "qty": 1}])
		rec.fed_today = true
		rec.mood = "keen"
		message = "%s eats from your hand. Whatever else the day brings, this part is settled." % b.display_name
		_refresh_hud()
		if net_mode == "server":
			rpc("cl_world_sync", _world_sync())
		return true
	if beast_role(b.creature_id) == "porter" and not b._porter_bag.is_empty():
		var bits: Array[String] = []
		for item_id: String in b._porter_bag.keys():
			inventory.add(b.owner_pid, item_id, int(b._porter_bag[item_id]))
			bits.append("%d× %s" % [int(b._porter_bag[item_id]), str(registry.get_entity(item_id).name)])
		b._porter_bag.clear()
		message = "%s empties its bag into your pack: %s." % [b.display_name, ", ".join(bits)]
		_refresh_hud()
		if net_mode == "server":
			rpc("cl_world_sync", _world_sync())
		return true
	if not b.at_heel:
		if str(rec.mood) == "sulking":
			message = "%s turns away. Feed your animals." % b.display_name
			_refresh_hud()
			return true
		if beasts.any(func(x: DSBeast) -> bool: return x != b and x.owner_pid == b.owner_pid and x.at_heel):
			message = "Only one beast can walk at your heel. Send the other home first."
			_refresh_hud()
			return true
	b.at_heel = not b.at_heel
	rec.at_heel = b.at_heel
	b.kenneled = not b.at_heel and works.count_of("work-kennel") > 0
	rec.kenneled = b.kenneled
	message = "%s falls in at your heel." % b.display_name if b.at_heel else "%s stays." % b.display_name
	b._refresh_label()
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## Revive a downed beast at 30% HP — stand over them and press [E]. Crabs are
## exempt by decision (they never go down at all — damage_beast() no-ops them).
func intent_revive_beast(b: DSBeast) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "beast_revive", [b.beast_id if b != null else -1])
		return true
	if b == null or not b.downed:
		return false
	b.downed = false
	b.downed_until = 0.0
	if stats.actors.has(b):
		stats.actors[b].hp = beast.beast_max_hp(b.beast_id) * 0.3
	message = "%s comes back around." % b.display_name
	b._refresh_label()
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## --- the rename modal (M3.b, at the kennel) ----------------------------------------
## [M] on a KENNELED beast opens a numbered pick: the current name, then the
## species' namePool (REEF-FOREST-SPEC §5). This finds/opens PURELY client-side,
## same as _drill_takes_e/_toggle_drill — the beast roster (position, kenneled,
## owner) already mirrors to every client via cl_world_sync, so no server round
## trip is needed just to open the menu; only the actual rename is an intent.
func _kennel_rename_takes_key() -> void:
	var target: DSBeast = null
	var best := interact_range()
	for b: DSBeast in beasts:
		if b.owner_pid == acting_pid and b.kenneled:
			var d := acting_pos().distance_to(b.position)
			if d < best:
				best = d
				target = b
	if target == null:
		message = "No kenneled beast stands close enough to rename."
		_refresh_hud()
		return
	sfx("ui")
	_toggle_rename(true, target.beast_id)

func _toggle_rename(open: bool, beast_id: int = -1) -> void:
	rename_open = open
	rename_beast_id = beast_id if open else -1
	var m: Dictionary = modals.get("rename", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	_render_rename()

## The offer list is deterministic off the beast's CURRENT display_name + its
## species' namePool — same list built again, unmutated, when the pick lands in
## intent_rename_beast (server-authoritative: the client's render is a preview,
## not the source of truth).
func _rename_offer(b: DSBeast) -> Array:
	var offer: Array = [b.display_name]
	for n: Variant in registry.get_entity(b.creature_id).get("tame", {}).get("namePool", []):
		if str(n) != b.display_name:
			offer.append(str(n))
	return offer

func _render_rename() -> void:
	var m: Dictionary = modals.get("rename", {})
	if m.is_empty() or not rename_open:
		return
	var b := _beast_by_id(rename_beast_id)
	if b == null:
		_toggle_rename(false)
		return
	rename_items = _rename_offer(b)
	var lines: Array[String] = ["Rename %s:" % b.display_name, ""]
	for i in rename_items.size():
		lines.append("  %d. %s%s" % [i + 1, str(rename_items[i]), "  (keep it)" if i == 0 else ""])
	(m.body as Label).text = "\n".join(lines)
	(m.footer as Label).text = "[1-%d] choose a name   ·   [M] close" % rename_items.size()

## Server-authoritative intent: recomputes the SAME deterministic offer list off
## the beast's current name (not whatever the client's stale render showed) and
## applies the pick to both the sim roster (beast_system.beasts[id].name — what
## world_sync mirrors) and the presentation body (display_name).
func intent_rename_beast(beast_id: int, idx: int) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "rename_beast", [beast_id, idx])
		return true
	if not beast.beasts.has(beast_id):
		return false
	var b := _beast_by_id(beast_id)
	if b == null:
		return false
	var offer := _rename_offer(b)
	if idx < 0 or idx >= offer.size():
		return false
	var new_name := str(offer[idx])
	beast.beasts[beast_id].name = new_name
	b.display_name = new_name
	b._refresh_label()
	message = "%s it is." % new_name
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

## Some arrivals come pre-trained (VILLAGER-AND-GODHEAD-SPEC Part I §1): wardens
## arrive Warrior 1; a god's priest arrives Acolyte 1 (they meet the faith/patron
## gate by construction — priests serve a god). Everyone else starts untrained.
func _starting_arms_for(class_id: String) -> String:
	match class_id:
		"class-warden": return "arms-warrior"
		"class-priest": return "arms-acolyte"
		_: return ""

func _villager_by_tid(tid: int) -> DSVillager:
	for v: DSVillager in all_villagers():
		if v.tribesman_id == tid:
			return v
	return null

## A companion action arrives over the wire keyed by nid (stable across client/
## server instances, unlike array indices); resolve and dispatch, or no-op if
## the mirror hasn't caught up yet.
func _net_villager_intent(nid: int, kind: String) -> void:
	var v := _villager_by_nid(nid)
	if v == null:
		return
	match kind:
		"recruit": intent_recruit(v)
		"dismiss": intent_dismiss_companion(v)
		"revive": intent_revive_companion(v)

func _villager_by_nid(nid: int) -> DSVillager:
	for v: DSVillager in villagers:
		if int(v.get_meta("nid", -1)) == nid:
			return v
	return null

func _villager_name(tid: int) -> String:
	var v := _villager_by_tid(tid)
	return v.display_name if v != null else "someone"

## has_memorial is presentation-set (sim never reads works directly, per its own
## comment) — recomputed wherever works are counted: build, reclaim, load, dawn.
func _recompute_memorial() -> void:
	village.has_memorial = works.count_of("work-memorial") > 0

## Talk to a villager: hear them, and — if their door is a heard grievance —
## opening up IS meeting their Key. They bloom.
func intent_talk(v: DSVillager) -> bool:
	var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
	if rec.is_empty():
		return false
	var key := str(rec.get("key", ""))
	if not bool(rec.get("key_met", false)) and (key == "grievance-heard" or key.begins_with("respect") or key == "confided-in" or key == "audience-kept" or key == "left-alone" or key == "trusted-with-stores"):
		village.meet_key(v.tribesman_id)
		v.set_mood("content")
		sfx("bloom")
		message = "%s talks, and something loosens. They bloom — you'll see it in their work." % v.display_name
	else:
		var m := str(rec.get("expression", "steady"))
		var line := "'The flats are quiet today. That's the most you can ask of them.'"
		if m == "poorFood" or _stock_food_total() == 0:
			line = "'There's not much in the stores. A person works better fed.'"
		elif m in ["slacking", "spreadingDoubt", "pettyTheft"]:
			line = "'I don't know why I stay, some days. ...but I stay.'"
		elif bool(rec.get("bloomed", false)):
			line = "'Good to have somewhere to be. Thank you for that.'"
		message = "%s: %s" % [v.display_name, line]
	# THEIR WAYS: talking is how a social trait's tell gets noticed — an
	# immediate message, unlike the dawn report's daily batch.
	for tid: String in village.talk_discovery(v.tribesman_id, clock.day):
		var tr: Dictionary = registry.get_entity(tid)
		message += "\nYou've come to know %s: %s. %s" % [v.display_name, str(tr.get("name", "?")), str(tr.get("discovery", ""))]
	_refresh_hud()
	return true

## Where HOME is: the hearth if one burns, else a chapel, else the workbench,
## else the world's center. Anna settles here; so will everyone after her.
## Set / move the camp anchor and redraw its ring. Server broadcasts on change.
## The hearth is the heart: the build ring centers on it, and there is no village
## without one. Re-derive the center from the hearth after any build / move /
## reclaim — reclaim the hearth and the ring dissolves until you raise another.
func _recenter_on_hearth() -> void:
	camp_center = work_pos("work-hearth")
	_update_camp_ring()

## A soft additive halo — reads as a glow against the pale flats. Stacked rings
## fake a falloff without a shader.
func _make_glow(radius: float, color: Color) -> Node2D:
	var root := Node2D.new()
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for ring in 3:
		var poly := Polygon2D.new()
		var pts := PackedVector2Array()
		var r := radius * (1.0 - ring * 0.28)
		for i in 20:
			var a := TAU * i / 20.0
			pts.append(Vector2(cos(a), sin(a)) * r)
		poly.polygon = pts
		poly.color = Color(color.r, color.g, color.b, color.a)
		poly.material = mat
		root.add_child(poly)
	return root

## Markers on the world: your bound rest point glows warm, and any hut with
## someone asleep inside shows a lit window + a sleeper count. Client-only,
## rebuilt on a throttle from synced state.
func _update_markers() -> void:
	# --- your rest point, glowing so you can find it across the flats ---------
	if _rest_glow == null:
		_rest_glow = _make_glow(38.0, Color(1.0, 0.70, 0.32, 0.24))   # a hearth-warm ember, spottable from afar
		_rest_glow.z_index = -6
		add_child(_rest_glow)
	var bound := int(respawn_bind.get(my_pid, -1))
	if works.placed.has(bound):
		var b: Dictionary = works.placed[bound]
		_rest_glow.visible = true
		_rest_glow.position = Vector2(float(b.get("x", 0)), float(b.get("y", 0)))
	else:
		_rest_glow.visible = false
	# --- huts with sleepers: a lit window and how many are home ----------------
	var occ := _occupied_huts()
	for inst_id: int in _hut_markers.keys():
		if not works.placed.has(inst_id) or not occ.has(inst_id):
			var m: Dictionary = _hut_markers[inst_id]
			if is_instance_valid(m.glow):
				m.glow.queue_free()
			if is_instance_valid(m.label):
				m.label.queue_free()
			_hut_markers.erase(inst_id)
	for inst_id: int in occ:
		var pos := Vector2(float(works.placed[inst_id].get("x", 0)), float(works.placed[inst_id].get("y", 0)))
		if not _hut_markers.has(inst_id):
			var glow := _make_glow(16.0, Color(1.0, 0.78, 0.42, 0.20))
			glow.z_index = -5
			add_child(glow)
			var label := _world_label("", Vector2(0, -30))
			label.add_theme_color_override("font_color", Color("c98a3a"))
			add_child(label)
			_hut_markers[inst_id] = {"glow": glow, "label": label}
		var mk: Dictionary = _hut_markers[inst_id]
		(mk.glow as Node2D).position = pos + Vector2(0, 2)   # low, like light from a doorway
		(mk.label as Label).position = pos + Vector2(-70, -30)
		(mk.label as Label).text = "· %d asleep ·" % int(occ[inst_id])

## Which huts have someone sleeping inside, and how many. Derived from the same
## deterministic bunk assignment the villagers walk to.
func _occupied_huts() -> Dictionary:
	var occ := {}
	for v: DSVillager in all_villagers():
		if not v.housed:
			continue
		var slot := house_slot_for(v)
		if slot == Vector2.INF:
			continue
		for inst_id: Variant in works.placed:
			if int(registry.get_entity(str(works.placed[inst_id].work_id)).get("houses", 0)) <= 0:
				continue
			var hp := Vector2(float(works.placed[inst_id].get("x", 0)), float(works.placed[inst_id].get("y", 0)))
			if hp.distance_to(slot) < 2.0:
				occ[int(inst_id)] = int(occ.get(inst_id, 0)) + 1
				break
	return occ

## The gentle breathing of the glows — cheap, every frame.
func _pulse_markers() -> void:
	var pulse := 0.75 + 0.25 * sin(_glow_t * 2.2)
	if _rest_glow != null and _rest_glow.visible:
		_rest_glow.modulate.a = pulse
	for inst_id: int in _hut_markers:
		var g: Node2D = _hut_markers[inst_id].glow
		if is_instance_valid(g):
			g.modulate.a = pulse

func _update_camp_ring() -> void:
	if net_mode == "server":
		return
	if camp_ring == null:
		camp_ring = Line2D.new()
		camp_ring.width = 3.0
		camp_ring.default_color = Color(0.42, 0.36, 0.26, 0.65)   # a salt-line drawn in the dust
		camp_ring.z_index = -7
		# a dashed ring of stakes reads better than a solid circle in pixel art
		var pts := PackedVector2Array()
		var seg := 64
		for i in range(seg + 1):
			if i % 2 == 0:   # dash: skip every other segment
				if pts.size() > 0:
					camp_ring.points = pts   # (Line2D can't do gaps; use posts instead)
			var a := TAU * i / float(seg)
			pts.append(Vector2(cos(a), sin(a)) * CAMP_RADIUS)
		camp_ring.points = pts
		add_child(camp_ring)
		# little boundary stakes at the compass points
		for k in 8:
			var a := TAU * k / 8.0
			var stake := SpriteKit.sprite("salt_pillar", Vector2(6, 12), Color("cfd8d2"))
			stake.position = Vector2(cos(a), sin(a)) * CAMP_RADIUS
			stake.modulate = Color(1, 1, 1, 0.8)
			stake.scale = Vector2(0.6, 0.6)
			camp_ring.add_child(stake)
	camp_ring.visible = camp_center != Vector2.INF
	if camp_center != Vector2.INF:
		camp_ring.position = camp_center

func village_heart() -> Vector2:
	var hearth := work_pos("work-hearth")
	if hearth != Vector2.INF:
		return hearth
	if camp_center != Vector2.INF:
		return camp_center
	for wid: String in ["work-chapel", "work-workbench"]:
		var pos := work_pos(wid)
		if pos != Vector2.INF:
			return pos
	return Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)

## The nearest placed work in reach that isn't a chapel (chapels have rites).
func nearest_work(from: Vector2) -> int:
	var best := interact_range()
	var found := -1
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		if str(inst.work_id) == "work-chapel":
			continue
		var d := from.distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
		if d < best:
			best = d
			found = int(inst_id)
	return found

## Tend a work: set it WORKING for the day (use is worship — its god gets the
## trickle). Tend again to hear about it instead.
func intent_tend(inst_id: int) -> bool:
	var inst: Dictionary = works.placed[inst_id]
	var work := registry.get_entity(str(inst.work_id))
	# the Salt-Wheel grinds a captive into the Broken — the grim shortcut
	if str(inst.work_id) == "work-salt-wheel":
		return intent_salt_wheel(inst_id)
	var god_id: String = work.get("godId", "neutral")
	var god_line := ""
	if god_id != "neutral":
		god_line = " %s's work — kept in use, it feeds them favor." % str(registry.get_entity(god_id).name)
	var what := str(work.get("purpose", work.get("text", "")))
	if not bool(inst.get("in_use", false)):
		works.set_in_use(inst_id, true)
		sfx("craft")
		message = "You tend the %s — WORKING until dawn.%s\n%s" % [str(work.name).to_lower(), god_line, what]
	else:
		message = "The %s is working.%s\n%s" % [str(work.name).to_lower(), god_line, what]
	_refresh_hud()
	return true

## The Salt-Wheel: grind the nearest held captive into the Broken. Fast, dark,
## and the flats will know — priests mutter, Ur-Noth warms.
##
## NOT wired to godhead.grim_rite_drain() (VILLAGER-AND-GODHEAD-SPEC Part II
## §3's "-0.5% per rite from a god of your choice"): this is Ur-Noth flavor
## (feeds his own devotion_system favor via work_favor_hour below), but it
## isn't the spec's grim rite — it doesn't drain a CHOSEN god's Godhead, and
## it isn't a Verdict ledger entry the way the spec's grim rite must be.
## grim_rite_drain stays unwired until an actual "pick a god to bleed" verb
## exists; it's still callable (tested in run_tests.gd's _test_godhead).
func intent_salt_wheel(inst_id: int) -> bool:
	var captive: DSVillager = null
	for v: DSVillager in all_villagers():
		if v.is_captive:
			captive = v
			break
	if captive == null:
		message = "The Salt-Wheel stands ready and hungry. It wants a captive; you have none."
		_refresh_hud()
		return true
	works.set_in_use(inst_id, true)
	village.break_captive(captive.tribesman_id)
	captive.is_captive = false
	captive.def_patron = ""
	assign_job(captive)
	captive.set_mood("steady")
	devotion.work_favor_hour(acting_pid, "god-ur-noth", 8.0)
	sfx("consume")
	message = "The Salt-Wheel turns. %s goes in bitter and comes out Broken — obedient, tireless, empty. A warm voice, pleased.\nYour people will not meet your eye today." % captive.display_name
	_refresh_hud()
	return true

func _carrying_remnant() -> bool:
	for item_id: String in inventory._inv(acting_pid).keys():
		if registry.get_entity(item_id).get("category", "") == "remnant":
			return true
	return false

const KNEEL_HINTS := {
	"god-halor": "[Q] Pillar of Salt, when the pinch comes.",
	"god-maren": "[R] Call the Squall, when they crowd you.",
	"god-neris": "[Z] Slack Tide, when they crowd you. [N] The Returning Wave, to mend.",
	"god-vessa": "[H] Rip-Current, to run through them. [K] Undertow, to pull one close.",
	"god-ghal": "[U] The Shepherd's Voice, to calm and feed a beast. [L] Blood-Scent, to track.",
}

func intent_kneel(god_id: String) -> bool:
	if not devotion.attune(acting_pid, god_id):
		return false
	attuned_for(acting_pid).append(god_id)
	var god := registry.get_entity(god_id)
	message = "You kneel at the fallen shrine. %s: '%s'\n%s is with you — %s Their strength is not endless.\n%s — godhead %d%% (cap %d%%)." % [
		str(god.voice.tone).split(";")[0], str(god.voice.sampleLine),
		str(god.name).to_upper(), str(KNEEL_HINTS.get(god_id, "")),
		str(god.name).to_upper(), int(godhead.godhead(god_id)), int(godhead.cap())]
	sfx("kneel")
	if god_id == "god-maren":
		inventory.add(acting_pid, "item-harpoon-verse", 1)
		message += "\nTucked in the shrine-stones: a VERSE OF THE HARPOON-SONG. Whalers say there are three."
	elif god_id == "god-halor":
		inventory.add(acting_pid, "item-lantern-verse", 1)
		message += "\nTucked in the shrine-stones: a VERSE OF THE KEEPER'S TALE. The homestead god keeps the keepers' stories too — they say there are three."
	abilities.earn(acting_pid, 1)   # kneeling to a god tempers you
	_toggle_menu(false)
	_refresh_hud()
	return true

## The Lighthouse-Keeper's Lantern, verse 2: one of the three beached wrecks
## on the flats (see _build_ground) carries the keeper's second verse. The
## wreck itself is a permanent landmark — it never depletes — so the grant is
## tracked per player instead of by the world losing the item.
func intent_inspect_wreck() -> bool:
	lantern_wreck_inspected[acting_pid] = true
	inventory.add(acting_pid, "item-lantern-verse", 1)
	sfx("harvest")
	message = "You pick through the ribs of the beached wreck. Wedged under a bulkhead, dry for decades: a VERSE OF THE KEEPER'S TALE.\nKeepers say there are three."
	_refresh_hud()
	return true

## Cast an invocation and hand its data-defined effects to the executor.
func intent_cast(invocation_id: String = "inv-pillar-of-salt") -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "cast", [invocation_id])
		return true
	# Godhead (Part II §4): a guttered or consumed god grants NO magic, for
	# everyone — checked before devotion.cast() so a dead god never even spends
	# your Vigor. Diegetic block, not a silent no-op (the UI law holds here too).
	var found0 := devotion._find_invocation(invocation_id)
	if not found0.is_empty() and (godhead.is_guttered(found0.god_id) or godhead.is_consumed(found0.god_id)):
		message = "%s is a silence where a voice was — nothing answers." % str(registry.get_entity(found0.god_id).name)
		_refresh_hud()
		return false
	var inv: Dictionary = devotion.cast(acting_pid, invocation_id)
	if inv.is_empty():
		var found := devotion._find_invocation(invocation_id)
		if not found.is_empty() and found.god_id in attuned_for(acting_pid):
			message = "%s has nothing left to give. Build them a chapel; hold a rite." % str(registry.get_entity(found.god_id).name)
			_refresh_hud()
		return false
	# Godhead (Part II §2, the one formula): effective = base_magnitude x
	# blessing_dim(vigor, already gated above by can_cast) x godhead.
	var gh_mult := godhead.effective_mult(found0.god_id)
	_effect_note = ""
	for effect: Dictionary in inv.get("effects", []):
		_apply_effect(_godhead_scale_effect(effect, gh_mult))
	# cost relief: storms make Maren generous; Squall-Born makes her yours
	var found2 := devotion._find_invocation(invocation_id)
	if found2.get("god_id", "") == "god-maren":
		var relief := 0.0
		if is_storm_day():
			relief += 0.5
		if invocation_id == "inv-call-squall":
			relief += 1.0 - abilities.mod_mult(acting_pid, "squall-cost-mult")
		if relief > 0.0:
			devotion._restore(acting_pid, "god-maren",
				float(found2.inv.vigorCost) * devotion.max_vigor("god-maren") * minf(relief, 0.9))
	# UI law (Part II §2): the cast bar always shows live-computed strength.
	message = "%s  (%d%% strength)" % [str(inv.text), int(gh_mult * 100.0)]
	if _effect_note != "":
		message += "\n" + _effect_note
	_refresh_hud()
	return true

## Godhead (Part II §2): scale one invocation effect dict by the god's
## effective_mult before it reaches the executor — mirrors the pattern
## companion_channel() already used for the Acolyte's channelStrength.
## Plain magnitudes/durations scale linearly. Strike-COUNT magnitudes
## (lightning-strikes) floor instead — the spec's own worked example: 3
## strikes x 40% = 1.2, which reads as 1 strike, not 2; a min of 1 always
## fires ("a 10% squall is pathetic but not invisible"). Radii scale at HALF
## weight (`1 - (1-godhead)/2`) — verified against the spec's exact table:
## an 8m radius at 40% -> 5.6m, at 10% -> 4.4m.
func _godhead_scale_effect(effect: Dictionary, mult: float) -> Dictionary:
	var scaled: Dictionary = effect.duplicate(true)
	if scaled.has("magnitude"):
		var mag := float(scaled.magnitude)
		if str(scaled.get("type", "")) == "lightning-strikes":
			scaled.magnitude = maxi(1, int(mag * mult))
		else:
			scaled.magnitude = mag * mult
	if scaled.has("duration"):
		scaled.duration = float(scaled.duration) * mult
	if scaled.has("radius"):
		scaled.radius = float(scaled.radius) * (1.0 - (1.0 - mult) / 2.0)
	return scaled

## The effect executor: data-defined invocation effects become world changes.
func _apply_effect(effect: Dictionary) -> void:
	match str(effect.get("type", "")):
		"petrify-invulnerable":
			sfx("cast_pillar")
			petrify[acting_pid] = int(float(effect.get("duration", 6)) * 60.0 * abilities.mod_mult(acting_pid, "petrify-mult"))
			if acting_pid == my_pid:
				petrify_frames = int(petrify[acting_pid])
				player.modulate = Color("cfd0ce")
		"aoe-knockdown":
			var radius := float(effect.get("radius", 8)) * TILE
			for e in enemies.duplicate():
				if is_instance_valid(e) and acting_pos().distance_to(e.position) <= radius:
					e.stun(2.5)
		"lightning-strikes":
			var strikes := int(effect.get("magnitude", 3))
			var radius := float(effect.get("radius", 8)) * TILE
			var in_range := enemies.filter(func(e: DSEnemy) -> bool:
				return is_instance_valid(e) and acting_pos().distance_to(e.position) <= radius)
			in_range.sort_custom(func(a: DSEnemy, b: DSEnemy) -> bool:
				return acting_pos().distance_to(a.position) < acting_pos().distance_to(b.position))
			for i in mini(strikes, in_range.size()):
				var target: DSEnemy = in_range[i]
				_flash_bolt(target.position)
				sfx("bolt", target.position)
				target.on_hit()
				if stats.damage(target, 25.0):
					_on_enemy_killed(target)
		"time-slip":
			# Neris's Slack Tide: "for a held breath, the world forgets to move.
			# You do not." — a brief stun/slow on everything crowding the caster,
			# the same executor aoe-knockdown uses (DSEnemy.stun), keyed by the
			# invocation's duration rather than a fixed 2.5s.
			var slip_radius := float(effect.get("radius", 6)) * TILE
			var slip_dur := float(effect.get("duration", 3))
			for e in enemies.duplicate():
				if is_instance_valid(e) and acting_pos().distance_to(e.position) <= slip_radius:
					e.stun(slip_dur)
		"heal-over-time":
			# Neris's The Returning Wave: "what was taken from you comes back —
			# slowly, the way tides do." Regen on the caster via the stats system
			# (StatsSystem.apply_hot), not an instant chunk.
			stats.apply_hot(acting_pid, float(effect.get("magnitude", 0)), float(effect.get("duration", 1)))
		"dash-through":
			# Vessa's Rip-Current: "the old current takes you — through them,
			# past them, gone." A straight position teleport (not a move_and_slide
			# glide), so there is no frame where the caster is standing inside an
			# enemy's attack range long enough for its cooldown to fire — that IS
			# "no collision damage taken during it." magnitude is TILES.
			var dash_tiles := float(effect.get("magnitude", 12))
			var dir := _acting_facing()
			var origin := acting_pos()
			var dest := origin + dir * dash_tiles * TILE
			dest.x = clampf(dest.x, TILE, float(WORLD.x - 1) * TILE)
			dest.y = clampf(dest.y, TILE, float(WORLD.y - 1) * TILE)
			sfx("cast_dash", origin)
			# warp_player carries the caster's own body too: a remote caster's
			# client is snapped by RPC, or their next position packet would
			# quietly undo the dash.
			warp_player(acting_pid, dest)
			if bool(effect.get("params", {}).get("carriesAllies", false)):
				for v: DSVillager in all_villagers():
					if v.on_road and v.companion_pid == acting_pid and origin.distance_to(v.position) <= DASH_CARRY_RADIUS:
						v.position = dest + v._slot_offset()
				for b: DSBeast in beasts:
					if b.owner_pid == acting_pid and b.at_heel and origin.distance_to(b.position) <= DASH_CARRY_RADIUS:
						b.position = dest + b._heel_offset()
		"forced-pull":
			# Vessa's Undertow: "the sea used to decide where things stood. For a
			# moment, so do you." DECISION (data's "to-or-from-caster" left it
			# open; keeping it simple per the brief): always TOWARD the caster,
			# never away. magnitude is tiles of pull, clamped so the target can't
			# overshoot past the caster's feet.
			var puller_pos := acting_pos()
			var pulled := _nearest_hostile(puller_pos, UNDERTOW_PULL_RADIUS)
			if pulled != null:
				var pull_dist := float(effect.get("magnitude", 10)) * TILE
				var to_caster: Vector2 = puller_pos - pulled.position
				var travel := minf(pull_dist, maxf(to_caster.length() - 20.0, 0.0))
				pulled.position += to_caster.normalized() * travel
				sfx("cast_pull", pulled.position)
		"pacify-beast":
			# Ghal's Shepherd's Voice: "one word in the old tongue of the deep
			# pastures." Nearest hostile within SHEPHERDS_VOICE_RADIUS stops being
			# hostile for `duration` seconds — reuses the surrendered visual tint
			# WITHOUT setting the permanent `surrendered` flag (DSEnemy.pacify(),
			# not DSEnemy.surrender()); it un-pacifies on its own when the timer runs out.
			var calmed := _nearest_hostile(acting_pos(), SHEPHERDS_VOICE_RADIUS)
			if calmed != null:
				calmed.pacify(float(effect.get("duration", 20)))
				sfx("cast_pacify", calmed.position)
				# CRITICAL INTEGRATION (REEF-FOREST-SPEC §5): "calm a beast
				# instantly AND feed_wild counts it as a meal." On a TAMEABLE
				# species this calls the SAME feed_wild path a hand-feed uses —
				# the invocation itself is the offering, so no food is spent from
				# the pack. beast_system's own same-day cap ("only the FIRST feed
				# of a sim-day advances trust") is what guards double-feeding;
				# nothing extra is needed here to respect it.
				var tm: Dictionary = registry.get_entity(calmed.creature_id).get("tame", {})
				if not tm.is_empty():
					var nid := _enemy_nid(calmed)
					var ghal_rank := int(devotion.state.get(acting_pid, {}).get("god-ghal", {}).get("rank", 0))
					var post_boost := 2 if _near_taming_post(calmed.position) else 1
					var result := beast.feed_wild(nid, calmed.creature_id, acting_pid, clock.day, ghal_rank, post_boost)
					if bool(result.tamed):
						var bid := int(result.id)
						var pos := calmed.position
						stats.unregister(calmed)
						enemies.erase(calmed)
						calmed.queue_free()
						_spawn_beast(bid, pos, true)
						_effect_note = "%s falls calm — TAMED. It falls in at your heel." % str(beast.beasts.get(bid, {}).get("name", "Beast"))
					else:
						_effect_note = "%s falls calm. The Voice counts as a meal — trust %d/%d." % [
							str(registry.get_entity(calmed.creature_id).name), int(result.trust), int(result.needed)]
				else:
					_effect_note = "%s falls calm. Whatever it meant to do, it forgets to." % str(registry.get_entity(calmed.creature_id).name)
		"track-target":
			# Ghal's Blood-Scent: "the dried sea keeps no secrets from a nose it
			# made." Implemented as a personal HUD bearing line (same grammar as
			# _direction_hints' shrine/raider lines) naming the nearest hostile of
			# ANY kind, for `duration` real seconds — frame-counted exactly like
			# `petrify` (server truth in `blood_scent`, client display mirror in
			# `blood_scent_frames`, synced via _player_state/cl_player_state).
			blood_scent[acting_pid] = int(float(effect.get("duration", 300)) * 60.0)
			if acting_pid == my_pid:
				blood_scent_frames = int(blood_scent[acting_pid])
		_:
			pass  # unimplemented effect types are silently inert at this stage

## The local player's own facing (WASD-driven) when acting for themselves;
## a remote co-op caster has no local Node to read .facing off, so this falls
## back to their last-seen movement direction from the position stream (see
## `_pid_facing`, updated in srv_pos). Defaults to "south" (Vector2.DOWN),
## the same default player.gd itself starts with.
func _acting_facing() -> Vector2:
	if acting_pid == my_pid and player != null:
		return player.facing
	return _pid_facing.get(acting_pid, Vector2.DOWN)

func _flash_bolt(at: Vector2) -> void:
	var bolt := ColorRect.new()
	bolt.size = Vector2(3, 40)
	bolt.position = at + Vector2(-1, -40)
	bolt.color = Color("c9a648")
	add_child(bolt)
	get_tree().create_timer(0.25).timeout.connect(bolt.queue_free)

## Every player's current position, keyed by pid — single-player/offline reads
## straight off the body; a real server reads the synced avatars dict. Shared
## by anything that needs "who's standing where" outside combat's nearest_threat.
func _active_player_positions() -> Dictionary:
	if net_mode == "server":
		return avatars.duplicate()
	return {acting_pid: player.position}

const HEALING_BATH_RADIUS := 90.0
const HEALING_BATH_HP_PER_SEC := 2.0
const HEALING_BATH_STAMINA_MULT := 1.5

# M3.b invocation numbers (first-guess, invented — none of these ride the
# data files, since they're targeting/AOE ranges, the same convention as
# aoe-knockdown/lightning-strikes' own radius defaults above):
const DASH_CARRY_RADIUS := 120.0     # Rip-Current: a road companion/beast this close to the CASTER'S START rides along
const UNDERTOW_PULL_RADIUS := 280.0  # Undertow: "a sensible radius" per the brief — roughly aoe-knockdown's 8-tile reach, +2
const SHEPHERDS_VOICE_RADIUS := 250.0  # Shepherd's Voice: has to out-reach a melee swing to be worth casting
const TAMING_POST_RADIUS := 150.0      # work-taming-post's own $comment: "within ~150px" — CRAFT-AND-BUILD-SPEC Part 3

## Ghal's Taming-Post (M3.b): is `pos` within earshot of any placed Taming-Post?
## Presentation-side geometry, same reasoning as ghal_rank — beast_system never
## reads `works` directly.
func _near_taming_post(pos: Vector2) -> bool:
	for inst_id: Variant in works.placed:
		if str(works.placed[inst_id].work_id) == "work-taming-post":
			var inst: Dictionary = works.placed[inst_id]
			if pos.distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))) < TAMING_POST_RADIUS:
				return true
	return false

## Neris's Healing Bath: stand within ~90px and mend — +2 HP/sec, stamina
## regen x1.5 (StatsSystem.bath_mult, alongside the virtue-driven regen_mult).
## Counts as in-use on any day someone bathed (favor trickles the same as any
## other tended work; dawn resets in_use like everything else).
func _tick_healing_bath(delta: float) -> void:
	var bath_insts: Array[int] = []
	var bath_positions: Array[Vector2] = []
	for inst_id: Variant in works.placed:
		if str(works.placed[inst_id].work_id) == "work-healing-bath":
			var inst: Dictionary = works.placed[inst_id]
			bath_insts.append(int(inst_id))
			bath_positions.append(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
	if bath_insts.is_empty():
		return
	var any_bathed := false
	var positions := _active_player_positions()
	for pid: Variant in positions:
		var pos: Vector2 = positions[pid]
		var bathing := false
		for bpos: Vector2 in bath_positions:
			if pos.distance_to(bpos) < HEALING_BATH_RADIUS:
				bathing = true
				break
		if not bathing or not stats.actors.has(pid):
			if stats.actors.has(pid):
				stats.actors[pid].bath_mult = 1.0
			continue
		any_bathed = true
		var a: Dictionary = stats.actors[pid]
		a.hp = minf(float(a.hp) + HEALING_BATH_HP_PER_SEC * delta, stats.max_hp(pid))
		a.bath_mult = HEALING_BATH_STAMINA_MULT
	if any_bathed:
		for inst_id: int in bath_insts:
			works.set_in_use(inst_id, true)

func intent_rescue() -> bool:
	survivor.rescue()
	abilities.earn(acting_pid, 1)   # saving someone tempers you differently
	message = "%s, of the drowned coast towns. She follows you home — give her a hearth and she'll keep it.\nShe is devout: her prayers feed Halor a little every day." % survivor.display_name
	_check_village_keys()  # if her need already stands built, she blooms on arrival
	_refresh_hud()
	return true

## Worship audio: play this god's own chant if its WAV is present in assets/sfx/,
## otherwise fall back to the shared rite bell. Data-driven (god.worshipChant), so
## dropping in a new chant file makes it play with no code change.
func _play_worship(god_id: String) -> void:
	var chant := str(registry.get_entity(god_id).get("worshipChant", ""))
	if chant != "" and net_mode != "server" and SoundKit.stream(chant) != null:
		sfx(chant)
	else:
		sfx("rite")

func intent_rite(god_id: String) -> bool:
	if rites_done_today.get(god_id, false):
		message = "The rite is held once a day. The gods keep slow time."
		_refresh_hud()
		return false
	rites_done_today[god_id] = true
	# an Acolyte of this god, present at their own chapel, calls it their sparring —
	# worship IS training (VILLAGER-AND-GODHEAD-SPEC Part I §2, XP source riteLed)
	for v: DSVillager in all_villagers():
		if v.rescued and not v.is_captive and v.def_patron == god_id \
				and str(village.tribesmen.get(v.tribesman_id, {}).get("arms", {}).get("class_id", "")) == "arms-acolyte":
			village.grant_xp(v.tribesman_id, "riteLed")
	_play_worship(god_id)   # this god's chant, if we have it — else the old rite bell
	# the Sanctum: this god's altar bears the rite up (or sours it — offenses count)
	var altar := sanctum.altar_for(god_id)
	var splendor := sanctum.splendor(altar) if altar >= 0 else 1.0
	devotion.rite_day(acting_pid, god_id, "chapel", 1, splendor)
	# Godhead (Part II §3): the same rite feeds the god's WORLD-level body, not
	# just your own Vigor — Splendor bears it up here too (same altar, same job).
	var gh_delta := godhead.rite_day(god_id, "chapel", splendor)
	var god_name := str(registry.get_entity(god_id).name)
	if splendor > 1.05:
		message = "You lead the rite at %s's chapel. The altar's splendor bears it up (×%.1f)." % [god_name, splendor]
	elif splendor < 0.95:
		message = "You lead the rite at %s's chapel — but something on the altar sours it (×%.1f)." % [god_name, splendor]
	else:
		message = "You lead the rite at %s's chapel. The shrine-light steadies a little." % god_name
	message += "  %s +%.2f%% Godhead (now %.1f%%)" % [god_name, gh_delta, godhead.godhead(god_id)]
	_refresh_hud()
	return true

## The Offertory: one toggle verb, server-authoritative. If the item is on the
## altar (relic slot or bag) it comes back to your pack; if it's in your pack it
## goes to the altar — relics to the god's worn slots, goods to the bag.
func intent_sanctum(inst_id: int, item_id: String, op: String = "auto") -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "sanctum", [inst_id, item_id, op])
		return true
	if not sanctum.is_altar(inst_id):
		return false
	var god_id := str(sanctum.state[inst_id].god_id)
	# an item can sit on the altar AND in your pack, so the modal says which way
	# it means ("take" from the altar rows, "lay" from the pack rows); "auto"
	# keeps the old toggle order for callers that don't care
	# relics are personal (pack <-> altar); offerings are communal (STORES <-> altar)
	if op != "lay" and sanctum.take_relic(inst_id, item_id):
		inventory.add(acting_pid, item_id, 1)
		message = "You lift %s from the altar." % str(registry.get_entity(item_id).name)
	elif op == "take" or (op == "auto" and int(sanctum.state[inst_id].bag.get(item_id, 0)) > 0):
		var back := sanctum.withdraw(inst_id, item_id)
		if back <= 0:
			return false
		village_stock[item_id] = int(village_stock.get(item_id, 0)) + back
		message = "The offering returns to the stores (×%d)." % back
	else:
		if sanctum.relic_points(item_id) > 0.0 and inventory.count(acting_pid, item_id) > 0:
			if not sanctum.place_relic(inst_id, item_id, devotion.favor_tier(acting_pid, god_id)):
				message = "The altar's slots are full — %s holds only so many stories." % str(registry.get_entity(god_id).name)
				_refresh_hud()
				return false
			inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
			message = "You set %s on the altar. It belongs to a story now." % str(registry.get_entity(item_id).name)
		elif int(village_stock.get(item_id, 0)) > 0:
			# one from the stores per press — stack-splitting can come later
			village_stock[item_id] = int(village_stock[item_id]) - 1
			if int(village_stock[item_id]) <= 0:
				village_stock.erase(item_id)
			sanctum.deposit(acting_pid, inst_id, item_id, 1)
			var lane := sanctum.lane(god_id, item_id)
			match lane:
				"craves": message = "You lay one out from the stores. %s is pleased — this is craved." % str(registry.get_entity(god_id).name)
				"accepts": message = "You lay one out from the stores. It is accepted."
				"ignores": message = "You lay one out. %s does not stoop to notice." % str(registry.get_entity(god_id).name)
		else:
			return false
	sfx("rite")
	if offertory_open:
		_toggle_offertory(true, inst_id)
	_refresh_hud()
	return true

func intent_harvest() -> bool:
	var nearest: Area2D = null
	var best := harvest_range()
	for node in resource_nodes:
		if not is_instance_valid(node):
			continue
		var d := acting_pos().distance_to(node.position)
		if d < best:
			best = d
			nearest = node
	if nearest == null:
		return false
	# CRAFT-AND-BUILD-SPEC Part 1 Law 2: one tool per tier, best-in-pack —
	# the Bronze Mattock's tool.tier:2 (shipped inert at M2.75) goes live here.
	var tier_needed := int(registry.get_entity(str(nearest.get_meta("item_id"))).get("gather", {}).get("tierRequired", 0))
	if tier_needed > 0 and _best_tool_tier(acting_pid) < tier_needed:
		message = "This needs %s in your pack — bare hands won't cut it here." % _tool_name_for_tier(tier_needed)
		_refresh_hud()
		return false
	sfx("harvest", nearest.position)
	# a workable node yields one unit per swing and wears down; a simple pickup
	# (cloth, storm-glass) comes up whole like it always did
	if int(nearest.get_meta("hits", 1)) > 1:
		inventory.add(acting_pid, nearest.get_meta("item_id"),
			1 + int(abilities.mod_add(acting_pid, "harvest-bonus-qty")))
		_deplete_node(nearest, 1)
		_refresh_hud()
		return true
	inventory.add(acting_pid, nearest.get_meta("item_id"),
		int(nearest.get_meta("qty")) + int(abilities.mod_add(acting_pid, "harvest-bonus-qty")))
	if str(nearest.get_meta("item_id")) == "item-storm-glass" and inventory.count(acting_pid, "item-harpoon-verse") == 2:
		inventory.add(acting_pid, "item-harpoon-verse", 1)
		message = "Folded inside the storm-glass, impossibly: the LAST VERSE of the harpoon-song.\nYou know the whole making now. It wants a rite at a chapel — bronze, storm-glass, and good timber."
	harvested_indices.append(int(nearest.get_meta("idx", -1)))
	resource_nodes.erase(nearest)
	nearest.queue_free()
	_refresh_hud()
	return true

## Best mattock-class tool tier currently in PACK — tools have no doll slot
## (item.schema.json "slot" is weapon/armor/trinket only), so "equipped" isn't
## meaningful here; CRAFT-AND-BUILD-SPEC Part 1 Law 2 is best-in-pack instead.
func _best_tool_tier(pid: int) -> int:
	var best := 0
	for item_id: String in inventory._inv(pid).keys():
		if int(inventory._inv(pid).get(item_id, 0)) <= 0:
			continue
		var t := int(registry.get_entity(item_id).get("tool", {}).get("tier", 0))
		if t > best:
			best = t
	return best

## Names the tool a gather-gated node is waiting for, for the refusal message
## (the UI law: never gate silently — say what's missing).
func _tool_name_for_tier(tier: int) -> String:
	for item: Dictionary in registry.all_of("item"):
		if int(item.get("tool", {}).get("tier", 0)) == tier:
			return str(item.get("name", "a better tool"))
	return "a better tool"

## Wear a workable node down by `amount` hits. Spent nodes vanish (and rejoin the
## dawn-respawn pool via harvested_indices); live ones shrink so you can read
## how much is left at a glance.
func _deplete_node(node: Area2D, amount: int) -> void:
	var left := int(node.get_meta("left", 1)) - amount
	if left <= 0:
		harvested_indices.append(int(node.get_meta("idx", -1)))
		resource_nodes.erase(node)
		node.queue_free()
		return
	node.set_meta("left", left)
	var hits := maxi(int(node.get_meta("hits", 1)), 1)
	node.scale = Vector2.ONE * (0.55 + 0.45 * float(left) / float(hits))

## Partially-worked nodes, for save + sync: {idx: hits left}. Fresh nodes derive
## from item data and spent ones ride harvested_indices, so only the in-between
## state needs carrying.
func _node_left_dict() -> Dictionary:
	var out := {}
	for node in resource_nodes:
		if is_instance_valid(node) and int(node.get_meta("left", 1)) < int(node.get_meta("hits", 1)):
			out[int(node.get_meta("idx", -1))] = int(node.get_meta("left", 1))
	return out

func _apply_node_left(d: Dictionary) -> void:
	for node in resource_nodes:
		if not is_instance_valid(node):
			continue
		var idx := int(node.get_meta("idx", -1))
		if d.has(idx) or d.has(str(idx)):   # JSON round-trips keys to strings
			var left := int(d.get(idx, d.get(str(idx), 1)))
			node.set_meta("left", left)
			var hits := maxi(int(node.get_meta("hits", 1)), 1)
			node.scale = Vector2.ONE * (0.55 + 0.45 * float(left) / float(hits))

const BOARD_ROAD_LEASH_MULT := 1.25   # Vessa's Board-Road: CRAFT-AND-BUILD-SPEC Part 3, "villager leash +25% along roads" — verbatim

## The risk dial: how far this task's workers will range right now. Desperation
## stretches the leash; comfort shortens it to the home fields.
func _task_leash(task: String) -> float:
	var need := clampf(float(_need_priority().get(task, 0.0)), 0.0, 1.0)
	var far := REEF_LEASH_FAR if task in REEF_TASKS else FORAGE_LEASH_FAR
	var leash := lerpf(FORAGE_LEASH_NEAR, far, need)
	# M3.b: a Board-Road standing anywhere in the village extends every task's
	# reach by 25% — SIMPLIFICATION (the spec's own words: "villager leash +25%
	# along roads"): this multiplies the whole computed leash rather than
	# modeling per-tile pathing along an actual road network. A real road-graph
	# (villagers routing tile-by-tile along placed Board-Roads specifically) is
	# a later refinement; "any road stands" is the honest v0.
	if works.count_of("work-board-road") > 0:
		leash *= BOARD_ROAD_LEASH_MULT
	return leash

## The nearest live node bearing this item within `leash` of `from` — how a
## villager decides whether the wood is worth the walk.
func _nearest_node_of(item_id: String, from: Vector2, leash: float) -> Area2D:
	var best_d := leash
	var best: Area2D = null
	for node in resource_nodes:
		if not is_instance_valid(node) or str(node.get_meta("item_id")) != item_id:
			continue
		var d := from.distance_to(node.position)
		if d < best_d:
			best_d = d
			best = node
	return best

## F eats the first food in your pack. Two slots; a full belly refuses.
func intent_eat() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "eat", [])
		return true
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		var fstats: Dictionary = item.get("stats", {})
		if not fstats.has("foodHp"):
			continue
		if not stats.eat(acting_pid, float(fstats.foodHp), float(fstats.foodStamina), float(fstats.get("foodMinutes", 8)) * 60.0):
			message = "You're full. Come back to the rest of it when this wears off."
			_refresh_hud()
			return false
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		sfx("eat")
		message = "%s. You feel it in your arms — food is preparation here, not maintenance." % str(item.name)
		_refresh_hud()
		return true
	message = "Nothing to eat. The crabs are mostly harmless and excellent soup."
	_refresh_hud()
	return false

## The build menu: what you can raise, grouped by whose it is. A god's works
## appear once you're attuned — recipes arrive with faith.
func menu_works() -> Array:
	# no village yet? found it with the Great Hearth (buildable even before you
	# kneel to Halor — raising it courts him anyway), or pitch a personal shelter
	if work_pos("work-hearth") == Vector2.INF:
		var founding := ["work-hearth"]
		for work: Dictionary in registry.all_of("work"):
			if work.get("respawn", false):
				founding.append(str(work.id))
		return founding
	var order := ["neutral", "god-halor", "god-maren", "god-neris", "god-vessa", "god-ghal"]
	var visible_sets := ["neutral"]
	visible_sets.append_array(attuned_for(my_pid))
	var out: Array = []
	for god_id: String in order:
		if god_id not in visible_sets:
			continue
		for work: Dictionary in registry.all_of("work"):
			if work.get("godId", "") == god_id and not work.get("grim", false):
				out.append(str(work.id))
	# grim works whisper when you hold a captive — the Salt-Wheel wants a customer
	if _has_captive():
		out.append("work-salt-wheel")
	return out

func _has_captive() -> bool:
	for v: DSVillager in all_villagers():
		if v.is_captive:
			return true
	return false

func _toggle_build_menu(open: bool) -> void:
	_toggle_menu(open, "build")

func _cost_str(cost: Array) -> String:
	var bits: Array[String] = []
	for c: Dictionary in cost:
		bits.append("%s×%d" % [str(registry.get_entity(str(c.itemId)).get("name", c.itemId)), int(c.qty)])
	return ", ".join(bits)

## Recipes you can see: tree recipes always; legend recipes only once you hold
## their fragments.
func craftable_recipes() -> Array:
	var out: Array = []
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "legend":
			var frags := int(recipe.get("unlock", {}).get("fragments", 0))
			if frags > 0 and inventory.count(acting_pid, str(recipe.get("fragmentItemId", ""))) < frags:
				continue
		out.append(str(recipe.id))
	return out

func _toggle_menu(open: bool, mode: String = "build") -> void:
	menu_open = open
	menu_mode = mode
	menu_page = 0
	var m: Dictionary = modals.get("menu", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	if mode == "build":
		_render_build_menu()
	else:
		_render_craft_menu()

## The footer of the craft/build modal: how to act, plus the page turn.
func _menu_footer(verb: String, close_key: String, page: int, page_count: int, shown: int) -> void:
	var foot := "[1-%d] %s   ·   [%s] close" % [maxi(shown, 1), verb, close_key]
	if page_count > 1:
		foot += "   ·   page %d/%d — [0] for more" % [page + 1, page_count]
	(modals.menu.footer as Label).text = foot

func _render_build_menu() -> void:
	if menu_title != null:
		menu_title.text = "BUILD"
	var options := menu_works()
	var page_count := int(max(1, ceil(float(options.size()) / MENU_PER_PAGE)))
	menu_page = clamp(menu_page, 0, page_count - 1)
	var start := menu_page * MENU_PER_PAGE
	var end := int(min(start + MENU_PER_PAGE, options.size()))
	var founding := work_pos("work-hearth") == Vector2.INF
	var lines: Array[String] = []
	if founding:
		lines.append("· found your village ·")
	var last_god := ""
	for i in range(start, end):
		var work := registry.get_entity(str(options[i]))
		var god_id: String = work.get("godId", "neutral")
		if not founding and god_id != last_god:
			last_god = god_id
			lines.append("· %s ·" % ("salvage" if god_id == "neutral" else str(registry.get_entity(god_id).name) + "'s works"))
		var afford := _afford_via(work.get("buildCost", []))
		var afford_tag: String = {"pack": "", "stores": "  (the stores will cover it)", "no": "  (can't afford — pack and stores together)"}[afford]
		lines.append("%d. %s%s" % [i - start + 1, str(work.name), afford_tag])
		lines.append("     %s" % str(work.get("purpose", work.get("text", ""))))
		lines.append("     cost: %s" % _cost_str(work.get("buildCost", [])))
	if founding:
		lines.append("· the hearth is the heart — everything else grows around it ·")
	elif attuned_for(my_pid).size() < 2:
		lines.append("· more works open when you kneel at new shrines ·")
	menu_label.text = "\n".join(lines)
	_menu_footer("raise it", "B", menu_page, page_count, end - start)

func _render_craft_menu() -> void:
	if menu_title != null:
		menu_title.text = "CRAFT"
	var options := craftable_recipes()
	var page_count := int(max(1, ceil(float(options.size()) / MENU_PER_PAGE)))
	menu_page = clamp(menu_page, 0, page_count - 1)
	var start := menu_page * MENU_PER_PAGE
	var end := int(min(start + MENU_PER_PAGE, options.size()))
	var lines: Array[String] = []
	for i in range(start, end):
		var recipe := registry.get_entity(str(options[i]))
		var item := registry.get_entity(str(recipe.output.itemId))
		var station: String = recipe.get("stationWorkId", "")
		if station == "":
			station = str(recipe.get("ritual", {}).get("atWorkId", ""))
		var afford := _afford_via(recipe.get("inputs", []))
		var have_station := station == "" or works.count_of(station) > 0
		var tag := ""
		if not have_station:
			tag = "  (needs %s)" % str(registry.get_entity(station).name)
		elif afford == "stores":
			tag = "  (the stores will cover it)"
		elif afford == "no":
			tag = "  (can't afford — pack and stores together)"
		var where := "  @ %s" % str(registry.get_entity(station).name) if station != "" else "  (by hand)"
		lines.append("%d. %s ×%d%s" % [i - start + 1, str(item.name), int(recipe.output.qty), tag])
		lines.append("     %s%s" % [_cost_str(recipe.get("inputs", [])), where])
	if options.is_empty():
		lines.append("Nothing to make yet — gather materials, raise a workbench.")
	menu_label.text = "\n".join(lines)
	_menu_footer("make it", "C", menu_page, page_count, end - start)

func intent_craft(recipe_id: String) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "craft", [recipe_id])
		return true
	_stores_cover(registry.get_entity(recipe_id).get("inputs", []))   # in camp, the stores chip in
	var ok := inventory.craft(acting_pid, recipe_id, works)
	if ok:
		sfx("craft")
		var station: String = registry.get_entity(recipe_id).get("stationWorkId", "")
		if station != "":
			for inst_id: Variant in works.placed:
				if str(works.placed[inst_id].work_id) == station:
					works.set_in_use(int(inst_id), true)   # using it IS use
					break
		var recipe := registry.get_entity(recipe_id)
		if recipe.get("track", "") == "legend":
			var item := registry.get_entity(str(recipe.output.itemId))
			message = "THE RITE IS DONE. %s is yours.\n%s" % [str(item.name).to_upper(), str(item.get("legend", {}).get("history", ""))]
	_refresh_hud()
	return ok

func intent_craft_first() -> void:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "craft_first", [])
		return
	# a known legend always takes precedence — you don't accidentally make rope instead
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "legend" and intent_craft(str(recipe.id)):
			return
	for recipe: Dictionary in registry.all_of("recipe"):
		if recipe.get("track", "") == "tree" and intent_craft(str(recipe.id)):
			return

## Swing at the nearest enemy in arc range. Costs stamina — tired arms miss nothing, they just can't.
func intent_attack() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "attack", [])
		return true
	var target: DSEnemy = null
	var best := ATTACK_RANGE
	for e in enemies:
		if not is_instance_valid(e) or not e.is_attackable():
			continue   # a nightOnly boss dormant by day (the Anglermother) can't even be targeted
		var d := acting_pos().distance_to(e.position)
		if d < best:
			best = d
			target = e
	if target == null:
		return false
	if not stats.spend_stamina(acting_pid, attack_stamina_cost()):
		message = "Too winded to swing. Breath comes back — or food raises the ceiling."
		_refresh_hud()
		return false
	_flash_swing(target.position)
	sfx("swing")
	sfx("hit", target.position)
	target.on_hit()
	if equipped_item(acting_pid, "weapon") == "item-marens-own-harpoon" \
			or abilities.talent_active(acting_pid, "talent-bolt-marked"):
		_flash_bolt(target.position)   # strike true and the bolt comes down on your mark
		sfx("bolt", target.position)
	# a raider beaten low SURRENDERS instead of dying — subdue, don't slay
	if target.subduable and not target.surrendered:
		var max_hp := float(registry.get_entity(target.creature_id).get("stats", {}).get("hp", 60))
		if stats.hp(target) - attack_damage() <= max_hp * 0.25:
			stats.actors[target].hp = max_hp * 0.25
			target.surrender()
			message = "The raider drops to their knees, spent. [E] to bind them for the yoke — or walk away."
			_refresh_hud()
			return true
	# a tameable beast beaten low enough KNEELS instead of dying — mercy-taming,
	# the same door the Taken get (gated on YOUR WILD meeting its tame tier)
	if _mercy_kneel_check(target, attack_damage(), acting_pid):
		message = "%s kneels, spent — worn down enough to be won over. [E] with its craved food to tame it, or press on." % str(registry.get_entity(target.creature_id).name)
		_refresh_hud()
		return true
	if stats.damage(target, attack_damage()):
		_on_enemy_killed(target)
	return true

func equipped_item(pid: int, slot: String) -> String:
	return str(equipped.get(pid, {}).get(slot, ""))

## Equipped-GEAR effects (the Lighthouse-Keeper's Lantern's trinket effects,
## and any future weapon/armor effect keyed the same way) — the item-driven
## companion to abilities.mod_mult (virtue talents). Multiplicative across
## every worn slot; unmatched effect types are inert (x1), same convention.
func equipped_mod_mult(pid: int, effect_type: String) -> float:
	var total := 1.0
	for slot: String in ["weapon", "armor", "trinket"]:
		var item_id := equipped_item(pid, slot)
		if item_id == "":
			continue
		for eff: Dictionary in registry.get_entity(item_id).get("effects", []):
			if str(eff.get("type", "")) == effect_type:
				total *= float(eff.get("magnitude", 1.0))
	return total

## Equip an item from the pack into its doll slot; any current occupant returns
## to the pack. Toggling an already-equipped item unequips it.
func equip_toggle(pid: int, item_id: String) -> void:
	var item := registry.get_entity(item_id)
	var slot: String = str(item.get("slot", ""))
	if slot == "":
		return
	if not equipped.has(pid):
		equipped[pid] = {}
	var current: String = equipped_item(pid, slot)
	if current == item_id:                       # unequip
		equipped[pid].erase(slot)
		inventory.add(pid, item_id, 1)
	else:
		if inventory.count(pid, item_id) <= 0:
			return
		inventory.pay(pid, [{"itemId": item_id, "qty": 1}])
		if current != "":
			inventory.add(pid, current, 1)       # old piece back to the pack
		equipped[pid][slot] = item_id
	_recompute_vitals(pid)

func attack_damage() -> float:
	# your EQUIPPED weapon decides the swing; bare hands otherwise
	var w := equipped_item(acting_pid, "weapon")
	var dmg := ATTACK_DAMAGE
	if w != "":
		dmg = float(registry.get_entity(w).get("stats", {}).get("damage", ATTACK_DAMAGE))
	dmg = abilities.mod_add(acting_pid, "melee-damage", dmg)
	dmg = abilities.mod_add(acting_pid, "bolt-on-swing", dmg)
	return dmg

func armor_defense(pid: int) -> float:
	var a := equipped_item(pid, "armor")
	return float(registry.get_entity(a).get("stats", {}).get("defense", 0.0)) if a != "" else 0.0

func attack_stamina_cost() -> float:
	return maxf(ATTACK_STAMINA - abilities.mod_add(acting_pid, "attack-cost-reduction"), 5.0)

## Recompute everything the virtues touch on the body. Called on every
## allocation change, load, and remnant consumption.
func _recompute_vitals(pid: int = -1) -> void:
	if pid < 0:
		pid = acting_pid
	var a: Dictionary = stats.actors.get(pid, {})
	if a.is_empty():
		return
	a.base_hp = 60.0 + float(consumed_hp.get(pid, 0.0)) + abilities.mod_add(pid, "base-hp")
	a.food_slots = StatsSystem.FOOD_SLOTS + int(abilities.mod_add(pid, "food-slots"))
	a.regen_mult = abilities.mod_mult(pid, "stamina-regen-mult")
	a.eat_mult = abilities.mod_mult(pid, "eat-restore-mult")
	a.hp = minf(float(a.hp), stats.max_hp(pid))
	_refresh_bars()
	if sheet_open:
		_toggle_sheet(true)

## A short slash flash toward the target — SPACE should feel like something.
func _flash_swing(toward: Vector2) -> void:
	var dir := (toward - player.position).normalized()
	var slash := ColorRect.new()
	slash.size = Vector2(22, 4)
	slash.rotation = dir.angle()
	slash.position = player.position + dir * 20.0
	slash.color = Color("f7f5ee")
	add_child(slash)
	get_tree().create_timer(0.1).timeout.connect(slash.queue_free)

## Where a fallen player wakes: their own nearest personal shelter (tent), else
## the village hearth, else the middle of the flats. Per-player — your tent is
## yours. Death position seeds "nearest" so several tents wake you at the closest.
func _respawn_point(pid: int) -> Vector2:
	# the rest point you chose, if it still stands
	var bound := int(respawn_bind.get(pid, -1))
	if bound >= 0 and works.placed.has(bound):
		var b: Dictionary = works.placed[bound]
		return Vector2(float(b.get("x", 0)), float(b.get("y", 0)))
	# else fall back: your nearest tent, the hearth, the middle of the flats
	var from: Vector2 = avatars.get(pid, player.position) if net_mode == "server" else player.position
	var best := Vector2.INF
	var best_d := INF
	for inst_id: Variant in works.placed:
		var inst: Dictionary = works.placed[inst_id]
		if int(inst.get("owner", -1)) != pid:
			continue
		if not registry.get_entity(str(inst.work_id)).get("respawn", false):
			continue
		var p := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
		var d: float = from.distance_to(p)
		if d < best_d:
			best_d = d
			best = p
	if best != Vector2.INF:
		return best
	var hearth := work_pos("work-hearth")
	if hearth != Vector2.INF:
		return hearth
	return Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)

func damage_player(amount: float, pid: int = -1) -> void:
	if pid < 0:
		pid = my_pid
	if int(petrify.get(pid, 0)) > 0:
		return  # the salt holds
	# Tide-Shell (crab, tier 6): once a sim-day, a hit meant for the OWNER is
	# absorbed whole — "my crab took the hit for me," never party mitigation
	# math (Decision #10: guards the player only).
	for b: DSBeast in beasts:
		if b.owner_pid == pid and b.at_heel and beast_role(b.creature_id) == "porter" \
				and not b._tide_shell_used_today and beast_has_instinct(b.beast_id, "block-hit-for-owner"):
			b._tide_shell_used_today = true
			b.flash_tide_shell()
			_message_to(pid, "%s takes it on the shell." % b.display_name)
			return
	amount = maxf(amount - armor_defense(pid), 1.0)   # worn scale turns the worst of it
	# The Returning: what goes out comes back — once a day, even you
	if abilities.talent_active(pid, "talent-the-returning") and not cheat_death_used.get(pid, false) \
			and stats.hp(pid) - amount <= 0.0:
		cheat_death_used[pid] = true
		stats.actors[pid].hp = 1.0
		if pid == my_pid:
			sfx("rite")
		if pid == my_pid:
			message = "The tide takes you out — and brings you back. Once a day, Neris keeps that promise."
			_refresh_hud()
		_net_push_state(pid)
		_refresh_bars()
		return
	if pid == my_pid:
		sfx("grunt")
	if stats.damage(pid, amount):
		if pid == my_pid:
			sfx("death")
		# The Waker of the Drowned (VILLAGER-AND-GODHEAD-SPEC Part II §5): Ur-
		# Noth alone restores the dead. BEFORE respawn — dying writes NO ledger
		# entries of its own (design law: dying is ledger-neutral); this is pure
		# Godhead accounting plus one whisper line. `message` is set
		# unconditionally (not gated by pid == my_pid) because it's what
		# _net_push_state below actually delivers to the DYING player's own
		# peer — the existing player_state/message channel every other
		# server-side event already rides.
		var attuned_urnoth := "god-ur-noth" in attuned_for(pid)
		var wr: Dictionary = godhead.player_death(pid, clock.day, attuned_urnoth)
		var ledger_line: String
		if bool(wr.washed):
			ledger_line = "THE DARK TAKES YOU.   UR-NOTH carries his own  (±0%)"
		else:
			ledger_line = "THE DARK TAKES YOU.   UR-NOTH +%.1f%% Godhead  (now %.1f%%)" % [float(wr.fed), godhead.godhead("god-ur-noth")]
		var whisper := _waker_whisper_line(pid, int(wr.lifetime), str(wr.whisper_pool))
		message = "%s\n\"%s\"" % [ledger_line, whisper]
		# you wake where you're sheltered: your own tent, else the hearth, else
		# the middle of the flats. (Death penalty otherwise stays pride-only.)
		var wake := _respawn_point(pid)
		warp_player(pid, wake)   # remote players must actually WAKE there, not just on paper
		stats.heal_full(pid)
		if pid == my_pid:
			_refresh_hud()
	_net_push_state(pid)
	_refresh_bars()

## The Waker's whisper-on-wake (§5): one line, drawn from ur-noth.json's
## wakerWhispers pool for this lifetime-death-count (milestones checked first,
## exact count match), seeded per (pid, lifetime) so replay/sync is stable —
## the same death always whispers the same line, on host and any mirror alike.
func _waker_whisper_line(pid: int, lifetime: int, pool: String) -> String:
	var ww: Dictionary = registry.get_entity("god-ur-noth").get("wakerWhispers", {})
	var milestones: Dictionary = ww.get("milestones", {})
	if milestones.has(str(lifetime)):
		return str(milestones[str(lifetime)])
	var lines: Array = ww.get(pool, [])
	if lines.is_empty():
		return "..."
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("waker:%d:%d" % [pid, lifetime])
	return str(lines[rng.randi_range(0, lines.size() - 1)])

## Server: push a player's state to their peer (after damage etc. outside intents).
func _net_push_state(pid: int) -> void:
	if net_mode != "server":
		return
	for peer_id: Variant in peers:
		if int(peers[peer_id]) == pid:
			rpc_id(int(peer_id), "cl_player_state", _player_state(pid))
			return

## Move a player's BODY authoritatively — the one thing cl_positions can't do.
## Clients own their own position (cl_positions skips pid == my_pid), so a
## server-side relocation of a REMOTE player is silently undone by their next
## position packet. Any server code that relocates someone must call this:
## respawn (the Waker — remote players never actually woke at their rest point
## before this) and Rip-Current's dash both do.
func warp_player(pid: int, pos: Vector2) -> void:
	if net_mode == "server":
		avatars[pid] = pos
	if pid == my_pid and player != null:
		player.position = pos
	if net_mode != "server":
		return
	for peer_id: Variant in peers:
		if int(peers[peer_id]) == pid:
			rpc_id(int(peer_id), "cl_warp", pos.x, pos.y)
			return

## The client's own body, snapped by the server. Authoritative and reliable:
## dropping this packet would leave a player standing where they died.
@rpc("authority", "reliable")
func cl_warp(x: float, y: float) -> void:
	if player != null:
		player.position = Vector2(x, y)

func _on_enemy_killed(enemy: DSEnemy) -> void:
	sfx("kill", enemy.position)
	var creature := registry.get_entity(enemy.creature_id)
	_calling_kill_credit(acting_pid, enemy.creature_id)   # a "kill" step's counter, if the acting player is carrying one
	for drop: Dictionary in creature.get("drops", []):
		var qty := int(drop.qty)
		if enemy.creature_id == "creature-scuttle-crab" and str(drop.itemId) == "item-crab-meat":
			qty += int(abilities.mod_add(acting_pid, "crab-bonus-drop"))  # the respectful way
		inventory.add(acting_pid, str(drop.itemId), qty)
	if enemy.is_boss:
		bosses_dead[enemy.creature_id] = true   # M3.c: per-boss now, not a single global flag
		abilities.earn(acting_pid, 2)   # nothing tempers like a king
		if enemy.creature_id == "creature-old-shellback":
			# the wreck-ring opens: his hoard becomes salvage ground (Shellback
			# only — the Anglermother's reef arena has no wreck to salvage)
			var hoard_rng := RandomNumberGenerator.new()
			hoard_rng.seed = 77
			for i in 6:
				var item := "item-bronze-salvage" if i % 2 == 0 else "item-wreck-timber"
				var pos := enemy.spawn_pos + Vector2(hoard_rng.randf_range(-120, 120), hoard_rng.randf_range(-100, 100))
				var def_idx := node_defs.size()
				node_defs.append({"item_id": item, "pos": pos, "idx": def_idx})
				_spawn_one_node(item, pos, def_idx)
	var remnant_id: String = creature.get("remnantItemId", "")
	if remnant_id != "":
		inventory.add(acting_pid, remnant_id, 1)
		if enemy.creature_id == "creature-old-shellback":
			message = "%s falls — the oldest sailor left, out of his depth at last. His wreck-ring is yours to salvage.\nSomething divine remains in him. A warm, reasonable voice: 'They'd ask you to feed it to them. I only ever ask you to eat.'\n[E] at a chapel to ENSHRINE it — or [X] to consume it. Some doors only open once." % str(creature.name)
		else:
			message = "%s goes dark and still — the lure gutters out, and for the first time the water here is just water.\nSomething divine remains in her: Old Ghal's own strength, embodied in the reef's great mother. A warm, reasonable voice: 'They'd ask you to feed it to them. I only ever ask you to eat.'\n[E] at a chapel to ENSHRINE it — or [X] to consume it. Some doors only open once." % str(creature.name)
	# Arms XP (VILLAGER-AND-GODHEAD-SPEC Part I §2): the killing blow OR simply
	# being in the fight earns kill-assist credit — covers wardens on duty,
	# road companions, and anyone else classed and close enough to have helped.
	var tier := _creature_tier(enemy.creature_id)
	for v: DSVillager in all_villagers():
		if v.rescued and not v.is_captive and village.arms_level(v.tribesman_id) > 0 \
				and v.position.distance_to(enemy.position) < WARDEN_DEFEND_RADIUS:
			village.grant_xp(v.tribesman_id, "killAssist", tier)
	# beasts, same law: being in the fight (yours or not) earns kill-assist
	for b: DSBeast in beasts:
		if not b.downed and b.position.distance_to(enemy.position) < WARDEN_DEFEND_RADIUS:
			beast.grant_xp(b.beast_id, "killAssist", tier)
	stats.unregister(enemy)
	enemies.erase(enemy)
	enemy.queue_free()
	_refresh_hud()

## Tier for kill-assist XP: small fauna (crabs) barely count, hounds/raiders are
## the main verb, bosses are the big meal. Derived from the creature's own
## archetype — no new data field needed.
func _creature_tier(creature_id: String) -> int:
	match str(registry.get_entity(creature_id).get("archetype", "")):
		"boss": return 2
		"ambient", "ambient-armored": return 0
		_: return 1

## The Verdict, in your hands: consume a remnant for permanent strength —
## and the god it belonged to dims, for everyone, forever. Godhead (Part II
## §4) is what "dims" MEANS now: consumed() is the one truly irreversible
## act, locking that god's Godhead at 0 forever — no rite, tithe, trickle, or
## enshrine can ever revive them again. (This absorbs what used to be a
## separate ad-hoc verdict.god_world_strength dim with no real gameplay
## consumer; verdict_system keeps only the player-ledger "remnants" deed.)
func intent_consume_remnant() -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "consume", [])
		return true
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", "god-halor")
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		sfx("consume")
		consumed_hp[acting_pid] = float(consumed_hp.get(acting_pid, 0.0)) + 15.0 + abilities.mod_add(acting_pid, "consume-bonus-hp")
		_recompute_vitals()
		verdict.remnant_consume(acting_pid, god_id)
		godhead.consumed(god_id)   # the one irreversible act (Part II §4)
		message = "You eat what was left of a god's strength. You feel MAGNIFICENT.\nSomewhere, %s grows quieter — for everyone, forever. Their Godhead falls to 0%% and stays there. The warm voice sounds pleased." % str(registry.get_entity(god_id).name)
		_refresh_hud()
		return true
	return false

func intent_enshrine(god_id_of_chapel: String) -> bool:
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		if item.get("category", "") != "remnant":
			continue
		var god_id: String = item.get("remnantOf", god_id_of_chapel)
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": 1}])
		verdict.remnant_enshrine(acting_pid, god_id)
		var gh_delta := godhead.enshrine_remnant(god_id)   # the mirror of consumed() — feeds instead of locking
		message = "You set the remnant in the chapel-stone. %s steadies — the whole world's worth of them (Godhead +%.1f%%, now %.1f%%).\nThe warm voice says nothing at all." % [str(registry.get_entity(god_id).name), gh_delta, godhead.godhead(god_id)]
		_refresh_hud()
		return true
	return false

## --- the keystone moment (REEF-FOREST-SPEC §6, VILLAGER-AND-GODHEAD-SPEC Part II §3) ---
## A dead boss's ring: BOSS_RING_POS (Shellback, retroactive — his kneel-spot
## stands unclaimed for any world where he died before keystones existed) and
## ANGLERMOTHER_RING_POS. Which gods a kneeling player may dedicate the
## keystone to: attuned to THEM, and living — not guttered (godhead <= 0) and
## not consumed (godhead_system.is_consumed). Same "attuned, living" filter is
## used both to render the modal and to validate the pick server-side.
func _keystone_eligible_gods(pid: int) -> Array:
	var out: Array = []
	for god_id: String in attuned_for(pid):
		if not godhead.is_consumed(god_id) and not godhead.is_guttered(god_id):
			out.append(god_id)
	return out

## Which dead boss's keystone (if any) stands unclaimed within [E] reach right
## now. Returns the creature id, or "" — mirrors _drill_takes_e/_offertory_takes_e's
## "takes_e" shape (a pure lookup, no mutation).
func _keystone_takes_e() -> String:
	for creature_id: String in KEYSTONE_RINGS:
		if not bool(bosses_dead.get(creature_id, false)):
			continue
		if bool(keystones_claimed.get(creature_id, false)):
			continue
		if acting_pos().distance_to(KEYSTONE_RINGS[creature_id]) < interact_range():
			return creature_id
	return ""

func _toggle_keystone(open: bool, creature_id: String = "") -> void:
	keystone_open = open
	keystone_boss_id = creature_id if open else ""
	var m: Dictionary = modals.get("keystone", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	_render_keystone()

func _render_keystone() -> void:
	var m: Dictionary = modals.get("keystone", {})
	if m.is_empty() or not keystone_open:
		return
	var boss_name := str(registry.get_entity(keystone_boss_id).get("name", keystone_boss_id))
	keystone_items = _keystone_eligible_gods(my_pid)
	var cap := godhead.cap()
	var lines: Array[String] = ["%s's keystone waits here, unclaimed." % boss_name, "",
		"Dedicate it to ONE god — +8%% one-time, inside the cap (%.0f%%):" % cap]
	if keystone_items.is_empty():
		lines.append("  (you are attuned to no living god right now)")
	for i in keystone_items.size():
		var god_id: String = keystone_items[i]
		var god_name := str(registry.get_entity(god_id).name).to_upper()
		lines.append("  %d. %s — %.0f%%" % [i + 1, god_name, godhead.godhead(god_id)])
	(m.body as Label).text = "\n".join(lines)
	(m.footer as Label).text = "[1-%d] dedicate   ·   [E]/[ESC] close" % maxi(keystone_items.size(), 1)

## Server-authoritative: recomputes the SAME deterministic eligible-gods list
## off current attunement/godhead state (not the client's cached render), same
## justification as intent_rename_beast's _rename_offer recomputation. One
## keystone per boss per world — keystones_claimed locks it after the first pick.
func intent_dedicate_keystone(creature_id: String, idx: int) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "dedicate_keystone", [creature_id, idx])
		return true
	if not bool(bosses_dead.get(creature_id, false)) or bool(keystones_claimed.get(creature_id, false)):
		return false
	var eligible := _keystone_eligible_gods(acting_pid)
	if idx < 0 or idx >= eligible.size():
		return false
	var god_id: String = eligible[idx]
	var old_val := godhead.godhead(god_id)
	var delta := godhead.keystone_dedicate(god_id)
	var new_val := godhead.godhead(god_id)
	keystones_claimed[creature_id] = true
	verdict.keystone_dedicated(acting_pid, god_id)
	var god_name := str(registry.get_entity(god_id).name).to_upper()
	# UI law (REEF-FOREST-SPEC §6): the prompt/confirmation print the numbers —
	# "+8% — MAREN 31% -> 39% (cap 70%)". `delta` (not a hardcoded 8) so a
	# cap-clamped pick prints the number that ACTUALLY landed.
	message = "+%.0f%% — %s %.0f%% -> %.0f%% (cap %.0f%%)" % [delta, god_name, old_val, new_val, godhead.cap()]
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return true

func intent_build(work_id: String) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "build", [work_id])
		return true
	var work := registry.get_entity(work_id)
	if work.is_empty():
		return false
	var pos := acting_pos() + Vector2(40, 0)
	var has_hearth := work_pos("work-hearth") != Vector2.INF
	# a personal shelter (the tent) pitches anywhere — no village, no ring; it's
	# your bedroll on the open flats. Everything else obeys the hearth's ring.
	if not work.get("respawn", false):
		if not has_hearth:
			if work_id != "work-hearth":
				message = "Raise a Great Hearth first — the village grows around its fire.  (or pitch a tent to shelter.)"
				_refresh_hud()
				return false
		elif pos.distance_to(camp_center) > CAMP_RADIUS:
			message = "Too far from the hearth. Build within the ring."
			_refresh_hud()
			return false
	var stores_drawn := _stores_cover(work.get("buildCost", []))   # in camp, the community stores chip in
	if not inventory.pay(acting_pid, work.get("buildCost", [])):
		message = "Not enough to raise the %s — your pack and the stores together." % str(work.name).to_lower()
		_refresh_hud()
		return false
	var inst_id := works.place(work_id, acting_pid, pos)
	sanctum.register(inst_id, work_id)
	var build_msg := ""
	if work_id == "work-hearth":
		_recenter_on_hearth()   # the ring centers on the hearth, always
		if not has_hearth:
			build_msg = "You raise the Great Hearth. The village will grow around its fire."
	elif work.get("respawn", false):
		build_msg = "You pitch the %s. Fall out there and you'll wake here." % str(work.name).to_lower()
	if sanctum.is_altar(inst_id):
		build_msg = "The %s stands. Stand at it [E] to lay relics and offerings — splendor bears your rites up." % str(work.name).to_lower()
	sfx("build", pos)
	if work_id == "work-chapel":
		# dedicate to the first attuned god who lacks one
		for god_id: String in attuned_for(acting_pid):
			if not chapels.has(god_id):
				build_msg = "A chapel to %s, raised from wreck-timber. Hold rites here [E] — their strength returns through worship." % str(registry.get_entity(god_id).name)
				break
	# every other work was building in total silence before (Jeff: "I can't
	# build from the stores" — half of that was this: a success with no
	# message reads exactly like a no-op). Every build gets SOME confirmation.
	if build_msg == "":
		build_msg = "The %s stands." % str(work.name)
	if stores_drawn > 0:
		build_msg += "  (the stores provided what your pack lacked)"
	message = build_msg
	_spawn_work_visual(inst_id, work_id, pos, {})
	_reassign_all_jobs()
	_check_village_keys()
	_recompute_memorial()
	_refresh_hud()
	return true

## --- the sheet: what the sea left in you ------------------------------------------
func _toggle_sheet(open: bool) -> void:
	sheet_open = open
	var m: Dictionary = modals.get("sheet", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	var lines := ["what the sea left in you",
		"Temper: %d unspent (of %d)" % [abilities.available(acting_pid), abilities.earned(acting_pid)], ""]
	(m.footer as Label).text = "[1-6] raise a virtue   ·   [SHIFT+1-6] take back   ·   [T] close"
	var virtues := registry.all_of("virtue")
	for i in virtues.size():
		var v: Dictionary = virtues[i]
		var s := abilities.score(acting_pid, str(v.id))
		var pips := ""
		for p in AbilitiesSystem.VIRTUE_CAP:
			pips += "●" if p < s else "·"
		lines.append("%d. %-8s %s %2d   (%s)" % [i + 1, str(v.name), pips, s, str(registry.get_entity(str(v.godId)).name)])
		for talent: Dictionary in v.talents:
			var lit := s >= int(talent.threshold)
			lines.append("    %s %s (%d) — %s" % ["■" if lit else "□", str(talent.name), int(talent.threshold), str(talent.text)])
	sheet_label.text = "\n".join(lines)

## --- the pack & the paper doll ----------------------------------------------
## Equippable things you can act on: currently-equipped first (to unequip),
## then equippable items sitting in the pack.
func equippable_list() -> Array:
	var out: Array = []
	for slot: String in ["weapon", "armor", "trinket"]:
		var cur := equipped_item(acting_pid, slot)
		if cur != "":
			out.append(cur)
	for item_id: String in inventory._inv(acting_pid).keys():
		if str(registry.get_entity(item_id).get("slot", "")) != "" and item_id not in out:
			out.append(item_id)
	return out

func _toggle_doll(open: bool) -> void:
	doll_open = open
	var m: Dictionary = modals.get("doll", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	(m.footer as Label).text = "[1..] equip / unequip   ·   [I] close"
	var weapon := equipped_item(acting_pid, "weapon")
	var armor := equipped_item(acting_pid, "armor")
	var lines: Array[String] = []
	lines.append("        WEAPON: %s%s" % [
		str(registry.get_entity(weapon).name) if weapon != "" else "— bare hands —",
		"  (%d dmg)" % int(attack_damage()) if true else ""])
	lines.append("        ARMOR:  %s%s" % [
		str(registry.get_entity(armor).name) if armor != "" else "— none —",
		"  (−%d dmg)" % int(armor_defense(acting_pid)) if armor != "" else ""])
	lines.append("        health %d / %d" % [int(stats.hp(acting_pid)), int(stats.max_hp(acting_pid))])
	lines.append("")
	var equippable := equippable_list()
	if equippable.size() > 0:
		lines.append("EQUIP:")
		for i in equippable.size():
			var it := registry.get_entity(str(equippable[i]))
			var slot := str(it.get("slot", ""))
			var worn := equipped_item(acting_pid, slot) == str(equippable[i])
			var stat := ""
			if slot == "weapon":
				stat = "  %d dmg" % int(it.get("stats", {}).get("damage", 0))
			elif slot == "armor":
				stat = "  −%d dmg" % int(it.get("stats", {}).get("defense", 0))
			lines.append("  %d. %s%s%s" % [i + 1, str(it.name), stat, "   ✓ worn — press to remove" if worn else ""])
		lines.append("")
	lines.append("PACK:")
	var any := false
	for item_id: String in inventory._inv(acting_pid).keys():
		lines.append("  %s ×%d" % [str(registry.get_entity(item_id).name), inventory.count(acting_pid, item_id)])
		any = true
	if not any:
		lines.append("  (empty hands)")
	doll_label.text = "\n".join(lines)

func intent_equip_index(i: int) -> void:
	var equippable := equippable_list()
	if i < 0 or i >= equippable.size():
		return
	var item_id := str(equippable[i])
	if net_mode == "client":
		rpc_id(1, "srv_intent", "equip", [item_id])
	else:
		equip_toggle(acting_pid, item_id)
	if doll_open:
		_toggle_doll(true)

## --- the village panel ------------------------------------------------------
func _toggle_village(open: bool) -> void:
	var was_open := village_panel_open
	village_panel_open = open
	var m: Dictionary = modals.get("village", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	if open and not was_open:
		village_tab = "roster"   # a fresh open always starts on the roster; refreshes-while-open keep your tab
	_render_village()

## Redraws whichever tab is active. Called both on open and as a refresh (dawn,
## world_sync, after [G]) — must NEVER reset village_tab itself, or a background
## refresh would yank you off the tab you're reading.
func _render_village() -> void:
	var m: Dictionary = modals.get("village", {})
	if m.is_empty() or not village_panel_open:
		return
	if village_tab == "sheet":
		var srec: Dictionary = village.tribesmen.get(village_sheet_tid, {})
		if srec.is_empty():
			village_tab = "roster"   # they died or left while the sheet was open
	var tab_hint := "[TAB] %s" % ("view the stores" if village_tab == "roster" else "back to the roster")
	if village_tab == "roster":
		tab_hint = "[1-9] a villager's sheet   ·   " + tab_hint
	(m.footer as Label).text = "the flats manage their own labor   ·   %s   ·   [G] pool your goods   ·   [V] close" % tab_hint
	match village_tab:
		"stores":
			(m.title as Label).text = "THE VILLAGE — STORES"
			_render_village_stores()
		"sheet":
			(m.title as Label).text = "THE VILLAGE — %s" % _sheet_villager_name().to_upper()
			_render_villager_sheet()
		_:
			(m.title as Label).text = "THE VILLAGE"
			_render_village_roster()

func _sheet_villager_name() -> String:
	for v: DSVillager in all_villagers():
		if v.tribesman_id == village_sheet_tid:
			return v.display_name
	return "?"

## The villager character sheet (Jeff, 2026-07-17: "do we have a way to see
## our villager character sheets?"). Everything shown is something the player
## could legitimately know: trade, arms, gear, patron, origin, mood — and
## TRAITS ONLY IF DISCOVERED (the disposition axes stay hidden by design law:
## inner lives are read by attention, never by menu).
func _render_villager_sheet() -> void:
	var rec: Dictionary = village.tribesmen.get(village_sheet_tid, {})
	var vn: DSVillager = null
	for v: DSVillager in all_villagers():
		if v.tribesman_id == village_sheet_tid:
			vn = v
	if rec.is_empty() or vn == null:
		village_panel.text = "They are gone."
		return
	var lines: Array[String] = []
	# the person
	var trade: Dictionary = registry.get_entity(vn.def_class)
	lines.append("TRADE: %s — %s" % [str(trade.get("name", "?")), str(trade.get("text", ""))])
	var origin_word: String = {
		"rescued": "rescued from the flats — they remember who found them",
		"taken": "taken — brought in under the yoke",
		"broken": "broken at the Salt-Wheel — obedient, and empty where the fight was",
	}.get(str(rec.get("origin", "rescued")), "came in off the flats")
	lines.append("CAME TO YOU: %s" % origin_word)
	var patron := str(rec.get("patron_god_id", ""))
	lines.append("PATRON: %s" % (str(registry.get_entity(patron).get("name", "?")) if patron != "" else "keeps no god"))
	if bool(rec.get("bloomed", false)):
		lines.append("BLOOMED — whatever they needed, they found it here. It shows in everything.")
	else:
		lines.append("MOOD: %s" % vn._mood_word())
	lines.append("")
	# the arms
	var arms_txt := _arms_display(village_sheet_tid)
	if arms_txt == "":
		lines.append("ARMS: untrained — a Drill-Yard could change that")
	else:
		lines.append("ARMS: %s" % arms_txt)
		for t: Dictionary in village.ignited_talents(village_sheet_tid):
			lines.append("   · %s — %s" % [str(t.get("name", "?")), str(t.get("text", ""))])
		var lvl := village.arms_level(village_sheet_tid)
		var cls_id := str(rec.get("arms", {}).get("class_id", ""))
		for t: Dictionary in registry.get_entity(cls_id).get("talents", []):
			if int(t.get("tier", 99)) > lvl:
				lines.append("   next: %s at level %d" % [str(t.get("name", "?")), int(t.get("tier", 0))])
				break
	var gear := _villager_gear_note(vn)
	lines.append("GEAR: %s" % (gear.trim_prefix("armed: ") if gear != "" else "whatever their hands find"))
	lines.append("")
	# their ways — discovered traits only
	lines.append("THEIR WAYS:")
	var disc: Array = rec.get("discovered", [])
	if disc.is_empty():
		if _has_discovery_progress(village_sheet_tid):
			lines.append("   You're starting to see the shape of them.")
		else:
			lines.append("   You haven't watched them long enough to know. Their ways show in their work — attention is how you learn a person.")
	else:
		for trait_id: String in disc:
			var tr: Dictionary = registry.get_entity(str(trait_id))
			lines.append("   · %s — %s" % [str(tr.get("name", "?")), str(tr.get("text", ""))])
	# the road
	if vn.on_road:
		lines.append("")
		if vn.downed:
			lines.append("DOWN ON THE ROAD — get to them before the flats do.")
		else:
			lines.append("ON THE ROAD — walking with %s." % ("you" if vn.companion_pid == my_pid else "another"))
	if vn.is_captive:
		lines.append("")
		lines.append("HELD AT THE YOKE — day %d. The Wheel or the Unbinding; both are doors." % vn.days_held)
	village_panel.text = "\n".join(lines)

## Design law: never name an undiscovered trait — this only ever returns a
## bool, never which trait or how close. `notice` is host-only (never synced),
## so on a client mirror this reads empty and simply returns false — no hint
## until the real record arrives, which is the correct degrade.
func _has_discovery_progress(tid: int) -> bool:
	var rec: Dictionary = village.tribesmen.get(tid, {})
	var notice: Dictionary = rec.get("notice", {})
	if notice.is_empty():
		return false
	var disc: Array = rec.get("discovered", [])
	var thresholds: Dictionary = village.vtune.get("discovery", {})
	for trait_id: String in rec.get("traits", []):
		if trait_id in disc or not notice.has(trait_id):
			continue
		var axis := str(registry.get_entity(trait_id).get("axis", ""))
		if float(notice[trait_id]) > float(thresholds.get(axis, 5)) * 0.5:
			return true
	return false

## The [V] panel's Arms line: "Warrior 4 — 610/625 XP  (1 talent lit)". Reads
## purely off the tribesman record (real or the client's mirrored fake one), so
## it renders identically for host and client (UI law: no hidden math).
func _arms_display(tid: int) -> String:
	var rec: Dictionary = village.tribesmen.get(tid, {})
	var arms: Dictionary = rec.get("arms", {})
	var cls_id := str(arms.get("class_id", ""))
	if cls_id == "":
		return ""
	var level := village.arms_level(tid)
	var xp := float(arms.get("xp", 0.0))
	var xp_tune: Dictionary = village.vtune.get("xp", {})
	var c: float = float(xp_tune.get("curveConstant", 25))
	var cap: int = int(xp_tune.get("maxLevel", 10))
	var txt := "%s %d" % [str(registry.get_entity(cls_id).name), level]
	if level < cap:
		var floor_xp := c * pow(level, 2)
		var next_xp := c * pow(level + 1, 2)
		txt += " — %d/%d XP" % [int(xp - floor_xp), int(next_xp - floor_xp)]
	else:
		txt += " — MAX"
	var ignited := village.ignited_talents(tid).size()
	if ignited > 0:
		txt += "  (%d talent%s lit)" % [ignited, "" if ignited == 1 else "s"]
	return txt

## Claimed gear, generalized from the warden-only note (dawn ARMORY, §4 above)
## to every Arms-classed villager.
func _villager_gear_note(v: DSVillager) -> String:
	if v.def_class != "class-warden" and village.arms_level(v.tribesman_id) <= 0:
		return ""
	if v.warden_weapon == "" and v.warden_armor == "":
		return ""
	var arms := str(registry.get_entity(v.warden_weapon).get("name", "?")) if v.warden_weapon != "" else "bare hands"
	if v.warden_armor != "":
		arms += " + " + str(registry.get_entity(v.warden_armor).name)
	return "armed: %s" % arms.to_lower()

func _render_village_roster() -> void:
	var lines: Array[String] = []
	var roster := all_villagers().filter(func(v: DSVillager) -> bool: return v.rescued and v.tribesman_id >= 0)
	if roster.is_empty():
		lines.append("No one has joined you yet. Strangers are stranded out on the flats — find them.")
	else:
		lines.append("%-10s %-12s %-16s %s" % ["NAME", "TRADE", "DOING", "STATUS"])
		for v: DSVillager in roster:
			var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
			var cls := str(registry.get_entity(v.def_class).get("name", "?"))
			if v.is_captive:
				var covered := bool(rec.get("warden_covered", true))
				lines.append("%-10s %-12s %-16s %s" % [v.display_name.left(10), "CAPTIVE", ("warded" if covered else "UNWATCHED"),
					"break at the Salt-Wheel, or Unbind in %d day(s)" % maxi(0, 3 - v.days_held)])
				continue
			var doing: String = {"wood": "gathering wood", "food": "cooking", "salt": "boiling salt", "bronze": "salvaging bronze"}.get(v.task, "idle")
			if v.housed:
				doing = "asleep"
			if v.on_road:
				doing = "DOWN" if v.downed else "walking with you"
			var status: String = "NEEDS HELP!" if v.needs_help else ("content" if bool(rec.get("bloomed", false)) else v._mood_word())
			if v.on_road:
				status = "DOWN — bring them home" if v.downed else "on the road"
			elif not v.needs_help and not bool(rec.get("bloomed", false)):
				status += " — " + _villager_need(v, rec)
			var arms_txt := _arms_display(v.tribesman_id)
			if arms_txt != "":
				status = arms_txt + "  ·  " + status
			var gear := _villager_gear_note(v)
			if gear != "":
				status = gear + "  ·  " + status
			lines.append("%-10s %-12s %-16s %s" % [v.display_name.left(10), cls.left(11), doing.left(16), status.left(46)])
	lines.append("")
	var pri := _need_priority()
	var need_bits: Array[String] = []
	for task: String in NEED_TARGETS:
		var have: int = _stock_food_total() if task == "food" else int(village_stock.get(TASK_ITEM[task], 0))
		var mark := "!!" if float(pri[task]) > 0.6 else ("·" if float(pri[task]) < 0.1 else "")
		need_bits.append("%s %d/%d%s" % [task, have, NEED_TARGETS[task], mark])
	lines.append("NEEDS: %s   (!! = short, drives who does what)" % "   ".join(need_bits))
	lines.append("Your people eat %d food a day. Danger sends them home; clear it or post a warden." % roster.size())
	lines.append("STORES: %d kinds of goods held — [TAB] to see the full list" % _store_kinds_held())
	if not beasts.is_empty():
		lines.append("")
		var beast_bits: Array[String] = []
		for b: DSBeast in beasts:
			var species := str(registry.get_entity(b.creature_id).get("name", "beast")).to_lower()
			var lvl := beast.beast_level(b.beast_id) if beast.beasts.has(b.beast_id) else b.level
			var lit := beast.instincts_ignited(b.beast_id).size() if beast.beasts.has(b.beast_id) else b.instincts_lit
			var lit_txt := " (%d instinct%s)" % [lit, "" if lit == 1 else "s"] if lit > 0 else ""
			var where := "DOWN — [E] to revive" if b.downed else ("at your heel" if b.at_heel else ("kenneled" if b.kenneled else "waiting"))
			beast_bits.append("%s — %s %d%s, %s, %s" % [b.display_name, species, lvl, lit_txt, b.mood, where])
		lines.append("BEASTS: " + "  ·  ".join(beast_bits))
	# — the why of it: what each task scores and what gates it (debug) ————————
	lines.append("")
	lines.append("WHY THEY WORK OR REST:")
	for task: String in NEED_TARGETS:
		lines.append("  " + _task_debug_line(task, pri))
	lines.append("  the leash is the RISK dial: full stores = short (safe, surplus for the gods); low = far (danger)")
	lines.append("  idle = no task scores above 0.05 for them; tasks reassess at dawn (or when you build/rescue)")
	village_panel.text = "\n".join(lines)

func _store_kinds_held() -> int:
	var n := 0
	for item_id: String in village_stock:
		if int(village_stock[item_id]) > 0:
			n += 1
	return n

## The full community inventory — a fixed-width grid so it always fits the
## modal instead of one unbroken line running off the edge of the window.
func _render_village_stores() -> void:
	var lines: Array[String] = []
	var sids := _store_entry_ids()
	if sids.is_empty():
		lines.append("Bare shelves. [G] at the hearth pools your pack into the stores.")
	else:
		var pages := maxi(1, int(ceilf(sids.size() / 9.0)))
		village_store_page = village_store_page % pages
		lines.append("%d kind(s) of goods, %d unit(s) total%s:" % [sids.size(), _store_units_held(),
			("   —   page %d/%d, [0] for more" % [village_store_page + 1, pages]) if pages > 1 else ""])
		lines.append("")
		var start := village_store_page * 9
		for i in range(start, mini(start + 9, sids.size())):
			var item_id: String = sids[i]
			lines.append("  %d. %s ×%d" % [i - start + 1, str(registry.get_entity(item_id).get("name", item_id)), int(village_stock[item_id])])
		lines.append("")
		lines.append("[1-9] take one into your pack — the village's gear belongs to whoever's here (for now).")
	lines.append("Everything here feeds building, crafting, the kitchen, wardens' arms, and the Offertory.")
	village_panel.text = "\n".join(lines)

func _store_units_held() -> int:
	var total := 0
	for item_id: String in village_stock:
		total += int(village_stock[item_id])
	return total

## One diagnostic line per task: its need score and every gate that could stop a
## villager taking it — the answer to "why is everyone standing around?"
func _task_debug_line(task: String, pri: Dictionary) -> String:
	var have: int = _stock_food_total() if task == "food" else int(village_stock.get(TASK_ITEM[task], 0))
	var bits: Array[String] = []
	bits.append("%-6s need %.2f (%d/%d%s)" % [task, float(pri[task]), have, NEED_TARGETS[task],
		" — full: surplus work, near nodes only" if float(pri[task]) <= 0.0 and TASK_FORAGE_ITEM.has(task) else ""])
	var station: String = TASK_STATION.get(task, "")
	if station != "":
		bits.append(("station ✓" if works.count_of(station) > 0 else "station ✗ needs %s" % str(registry.get_entity(station).name).to_lower()))
	if TASK_FORAGE_ITEM.has(task):
		var leash := _task_leash(task)
		var node := _nearest_node_of(TASK_FORAGE_ITEM[task], village_heart(), leash)
		if node != null:
			bits.append("node ✓ %dpx (%d left) of %dpx leash" % [int(village_heart().distance_to(node.position)), int(node.get_meta("left", 1)), int(leash)])
		else:
			bits.append("node ✗ none within %dpx leash" % int(leash))
	return "   ".join(bits)

func _villager_need(v: DSVillager, rec: Dictionary) -> String:
	if rec.is_empty():
		return ""
	if bool(rec.get("bloomed", false)):
		return "nothing — thriving"
	var key := str(rec.get("key", ""))
	if key == "grievance-heard" or key == "confided-in" or key == "audience-kept":
		return "wants to be heard — talk to them [E]"
	if key.begins_with("shrine-access"):
		return "a chapel to their god"
	if key == "schedule-night":
		return "night work"
	if key == "right-job" or key == "promoted":
		return "the right work"
	if key == "left-alone":
		return "to be left be — don't fuss"
	return "attention — a good day or two"

## Pool the player's food into the shared stores (feed the village).
## Manage the stores: pour your food IN (feed the village), draw the materials
## your people gathered OUT into your pack.
## [G] pools your pack into the community stores. Everything goes except what's
## yours alone: equipped gear, relics, legends, god-remnants. The stores give
## back through use — building and crafting draw on them while you stand in camp,
## the kitchen cooks from them, wardens arm from them.
## Take ONE unit of an item out of the community stores into your own pack.
## Test-era communism (Jeff, 2026-07-18): every player who joins has access
## to the village and its gear; ownership is a later problem. Server
## validates against live stock, so two players racing for the last harpoon
## resolves cleanly — one gets iron, one gets a message.
func _store_entry_ids() -> Array:
	var ids := village_stock.keys().filter(func(k: String) -> bool: return int(village_stock[k]) > 0)
	ids.sort()
	return ids

func intent_stores_take(item_id: String) -> void:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "stores_take", [item_id])
		return
	if int(village_stock.get(item_id, 0)) <= 0:
		message = "The shelf is bare — someone got there first."
		_refresh_hud()
		return
	village_stock[item_id] = int(village_stock[item_id]) - 1
	if int(village_stock[item_id]) <= 0:
		village_stock.erase(item_id)
	inventory.add(acting_pid, item_id, 1)
	sfx("pickup")
	message = "You take %s from the stores. What the village holds, its people carry." % str(registry.get_entity(item_id).get("name", item_id))
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

func intent_give_food() -> void:
	var kept: Array[String] = []
	for slot: String in ["weapon", "armor", "trinket"]:
		var cur := equipped_item(acting_pid, slot)
		if cur != "":
			kept.append(cur)
	var given := 0
	for item_id: String in inventory._inv(acting_pid).keys():
		var item := registry.get_entity(item_id)
		# category "relic" catches placed legend-verses too (harpoon-verse,
		# lantern-verse) — they carry no Sanctum relic.points of their own, but
		# they're still personal quest-knowledge, never communal stock (the same
		# law "the song is knowledge — not consumed" applies at the yoke of [G]).
		if item_id in kept or not item.get("legend", {}).is_empty() \
				or str(item.get("remnantOf", "")) != "" or not item.get("relic", {}).is_empty() \
				or str(item.get("category", "")) == "relic":
			continue   # your story stays in your pack
		var n := inventory.count(acting_pid, item_id)
		if n <= 0:
			continue
		village_stock[item_id] = int(village_stock.get(item_id, 0)) + n
		inventory.pay(acting_pid, [{"itemId": item_id, "qty": n}])
		given += n
	sfx("build")
	if given > 0:
		message = "You pool %d goods into the stores. The village builds, cooks, and arms from them." % given
	else:
		message = "Nothing to pool — your pack holds only what's yours (worn gear, relics, legends)."
	if village_panel_open:
		_toggle_village(true)
	_refresh_hud()

## The stores provide: while you stand in the hearth's ring, costs you can't
## cover from your pack are drawn from the community stock.
## Returns the total units actually drawn from the stores (0 if none, or if
## out of the ring) — the caller reports it, so a stores-covered build/craft
## doesn't look like it happened for free out of nowhere.
func _stores_cover(cost: Array) -> int:
	if camp_center == Vector2.INF or acting_pos().distance_to(camp_center) > CAMP_RADIUS:
		return 0
	var drawn := 0
	for c: Dictionary in cost:
		var item_id := str(c.itemId)
		var short := int(c.qty) - inventory.count(acting_pid, item_id)
		var have := int(village_stock.get(item_id, 0))
		var take := clampi(short, 0, have)
		if take > 0:
			inventory.add(acting_pid, item_id, take)
			village_stock[item_id] = have - take
			if village_stock[item_id] <= 0:
				village_stock.erase(item_id)
			drawn += take
	return drawn

## Whether a cost line-up is affordable from the pack alone, needs the camp
## stores to chip in (only while standing in the ring — the same gate
## _stores_cover itself checks), or can't be covered even together. The build
## and craft menus render this so "the stores will cover it" never reads as
## "can't afford" (regression: Jeff couldn't tell stores-building still worked).
func _afford_via(cost: Array) -> String:
	if inventory.can_afford(acting_pid, cost):
		return "pack"
	if camp_center == Vector2.INF or acting_pos().distance_to(camp_center) > CAMP_RADIUS:
		return "no"
	for c: Dictionary in cost:
		var item_id := str(c.itemId)
		var have := inventory.count(acting_pid, item_id) + int(village_stock.get(item_id, 0))
		if have < int(c.qty):
			return "no"
	return "stores"

## --- CALLINGS: the per-player journal ---------------------------------------
func _active_callings(pid: int) -> Array:
	if not callings.has(pid):
		callings[pid] = []
	return callings[pid]

func _done_callings(pid: int) -> Array:
	if not callings_done.has(pid):
		callings_done[pid] = []
	return callings_done[pid]

func _calling_step(calling: Dictionary, step_id: String) -> Dictionary:
	for st: Dictionary in calling.get("steps", []):
		if str(st.get("id", "")) == step_id:
			return st
	return {}

## Resolve a named anchor (calling.schema.json params $comment) to a world
## position. Fixed anchors are literal; "village" and "brine-pool" track
## dynamic/nearest state. Returns Vector2.INF for anything unresolved (an
## unparamed step, or a name outside the documented list).
func _calling_anchor_pos(anchor_name: String) -> Vector2:
	match anchor_name:
		"shrine-halor", "shrine-maren", "shrine-neris":
			var god_id := "god-" + anchor_name.substr(7)
			for s in shrines:
				if str(s.get_meta("god_id", "")) == god_id:
					return s.position
			return Vector2.INF
		"wreck-west": return LANTERN_WRECK_POS
		"wreck-mid": return WRECK_MID_POS
		"wreck-east": return WRECK_EAST_POS
		"boss-ring": return BOSS_RING_POS
		"anglermother-ring": return ANGLERMOTHER_RING_POS
		"village": return village_heart()
		"brine-pool": return _nearest_brine_pool(acting_pos())
		"trench-edge": return TRENCH_EDGE_POS
		"stair-of-hulls": return STAIR_OF_HULLS_POS
		_: return Vector2.INF

func _nearest_brine_pool(from: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d := INF
	for p: Vector2 in brine_pools:
		var d := from.distance_to(p)
		if d < best_d:
			best_d = d
			best = p
	return best

## Is a parametered step's real-world condition satisfied? Steps with no
## params are always met (back-compat: old saves and unparamed steps keep
## free-continuing). `progress` is the diegetic tail shown in the journal and
## the unmet nudge — no percentages, no checkboxes (WORLD-SPEC "Callings").
func _step_met(pid: int, entry: Dictionary, step: Dictionary) -> Dictionary:
	var params: Dictionary = step.get("params", {})
	if params.is_empty():
		return {"met": true, "progress": ""}
	var t := str(step.get("type", ""))
	match t:
		"collect", "turn":
			if not params.has("itemId"):
				return {"met": true, "progress": ""}
			var item_id := str(params.itemId)
			var qty := int(params.get("qty", 1))
			var have := inventory.count(pid, item_id)
			var iname := str(registry.get_entity(item_id).get("name", item_id)).to_lower()
			return {"met": have >= qty, "progress": "%d/%d %s in hand" % [mini(have, qty), qty, iname]}
		"kill":
			var creature_id := str(params.get("creatureId", ""))
			var count := int(params.get("count", 1))
			var counters: Dictionary = entry.get("counters", {})
			var have_k := int(counters.get(str(step.id), 0))
			var cname := str(registry.get_entity(creature_id).get("name", creature_id))
			return {"met": have_k >= count, "progress": "%d/%d %s down" % [mini(have_k, count), count, cname]}
		"build":
			var work_id := str(params.get("workId", ""))
			var wname := str(registry.get_entity(work_id).get("name", work_id)).to_lower()
			var built := works.count_of(work_id) > 0
			return {"met": built, "progress": ("%s stands" % wname) if built else ("the %s does not yet stand" % wname)}
		"wait":
			var until := str(params.get("until", ""))
			if until == "storm":
				var here := is_storm_day()
				return {"met": here, "progress": "the storm is here" if here else "the storm has not yet come"}
			elif until == "storm-end":
				var passed := clock.day % 4 == 0
				return {"met": passed, "progress": "the storm has passed" if passed else "the storm has not yet passed"}
			elif until == "days":
				var need := int(params.get("days", 1))
				var since := int(entry.get("since_day", clock.day))
				var elapsed := maxi(0, clock.day - since)
				return {"met": elapsed >= need, "progress": "%d/%d days kept" % [mini(elapsed, need), need]}
			elif until == "night":
				# Open Q14, decided YES (REEF-FOREST-SPEC §7/§10): Drowned-country
				# vigils that only make sense after dark. clock.is_night() is the
				# same threshold every other night-gated system reads (SimClock.is_night_at).
				var here_night := clock.is_night()
				return {"met": here_night, "progress": "night has fallen" if here_night else "the night has not yet come"}
			return {"met": true, "progress": ""}
		"goto", "escort", "talk":
			var near := str(params.get("near", params.get("at", "")))
			if near == "":
				return {"met": true, "progress": ""}
			var target := _calling_anchor_pos(near)
			if target == Vector2.INF:
				return {"met": true, "progress": ""}   # the anchor doesn't exist in this build yet — don't gate on it
			var default_r := CAMP_RADIUS if t == "talk" else 160.0
			var radius := float(params.get("radius", default_r))
			var met := acting_pos().distance_to(target) <= radius
			return {"met": met, "progress": "you have arrived" if met else "you are not there yet"}
		_:
			return {"met": true, "progress": ""}

## Pay a met step's params, when it says to (collect/turn with consume:true —
## the goods really do leave your pack: laid on an altar, spent on a build).
func _apply_step_params(pid: int, step: Dictionary) -> void:
	var params: Dictionary = step.get("params", {})
	var t := str(step.get("type", ""))
	if (t == "collect" or t == "turn") and bool(params.get("consume", false)) and params.has("itemId"):
		inventory.pay(pid, [{"itemId": str(params.itemId), "qty": int(params.get("qty", 1))}])

## Kill credit for a "kill" step: called from the real kill handler
## (_on_enemy_killed), never faked. The counter rides on the entry dict, which
## already syncs per-pid over cl_player_state — no new net plumbing needed.
func _calling_kill_credit(pid: int, creature_id: String) -> void:
	for entry: Dictionary in _active_callings(pid):
		var calling := registry.get_entity(str(entry.id))
		var step := _calling_step(calling, str(entry.step))
		if str(step.get("type", "")) != "kill":
			continue
		var params: Dictionary = step.get("params", {})
		if params.is_empty() or str(params.get("creatureId", "")) != creature_id:
			continue
		var counters: Dictionary = entry.get("counters", {})
		counters[str(step.id)] = int(counters.get(str(step.id), 0)) + 1
		entry["counters"] = counters

## Is this calling eligible to arrive for this player right now?
func _calling_eligible(pid: int, c: Dictionary) -> bool:
	var cid := str(c.id)
	for e: Dictionary in _active_callings(pid):
		if str(e.id) == cid:
			return false
	if cid in _done_callings(pid):
		return false
	var src := str(c.get("source", ""))
	if src == "god-dream" and str(c.get("sourceGodId", "")) not in attuned_for(pid):
		return false
	if src == "tribesman" and all_villagers().filter(func(v: DSVillager) -> bool: return v.rescued).is_empty():
		return false
	return true

## Draw weight from the calling's drawWeights against this player's state.
func _calling_weight(pid: int, c: Dictionary) -> float:
	var w := 1.0
	var dw: Dictionary = c.get("drawWeights", {})
	for god_id: String in attuned_for(pid):
		w *= float(dw.get("devotion", {}).get(god_id, 1.0))
	w *= float(dw.get("biome", {}).get("biome-salt-shallows", 1.0))
	return w

## A calling finds the player: pick a weighted-random eligible one and open it.
func _draw_calling(pid: int) -> bool:
	var pool: Array = []
	var weights: Array = []
	var total := 0.0
	for c: Dictionary in registry.all_of("calling"):
		if _calling_eligible(pid, c):
			var w := _calling_weight(pid, c)
			pool.append(c)
			weights.append(w)
			total += w
	if pool.is_empty() or total <= 0.0:
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = 900 + clock.day * 7 + pid
	var roll := rng.randf() * total
	var pick: Dictionary = pool[0]
	for i in pool.size():
		roll -= float(weights[i])
		if roll <= 0.0:
			pick = pool[i]
			break
	_active_callings(pid).append({"id": str(pick.id), "step": str(pick.steps[0].id), "since_day": clock.day})
	var how := {"god-dream": "A dream comes to you", "dead-letter": "You find a letter on the flats",
		"tribesman": "One of your people asks something of you", "rumor": "A rumor reaches you",
		"chart": "An old sea-chart leads somewhere"}.get(str(pick.get("source", "")), "Something calls")
	if pid == my_pid:
		# A calling finds you: announce it even on a day the dawn report already
		# has something to say (append, never clobber — Jeff lost the village's
		# dawn-work summary to this exact overwrite before).
		var draw_msg := "%s — \"%s\". [J] to open your journal." % [how, str(pick.title)]
		message = (message + "\n" + draw_msg) if message != "" else draw_msg
		sfx("kneel")
	return true

## Act on the focused (first active) calling: choose option i, or continue (i=0).
func journal_interact(pid: int, i: int) -> void:
	var active := _active_callings(pid)
	if active.is_empty():
		return
	var entry: Dictionary = active[0]
	var calling := registry.get_entity(str(entry.id))
	var step := _calling_step(calling, str(entry.step))
	if step.is_empty():
		return
	var options: Array = step.get("options", [])
	var next_id := ""
	if options.size() > 0:
		if i < 0 or i >= options.size():
			return
		var opt: Dictionary = options[i]
		for led: Dictionary in opt.get("ledger", []):
			verdict.record(pid, str(led.ledger), float(led.amount), str(led.get("note", "")), clock.day)
		next_id = str(opt.get("next", ""))
	else:
		# a parametered step (goto/collect/build/kill/wait/escort/talk with real
		# params) refuses to advance until its real-world condition is met —
		# choice/turn-with-options steps never reach this branch, so they're
		# unaffected, and a step with NO params is met trivially (back-compat).
		var sm := _step_met(pid, entry, step)
		if not sm.met:
			# unconditional, like every other intent's report — on a listen
			# server this is what rides cl_player_state home to the client
			message = "Not yet — (%s)" % sm.progress
			return
		_apply_step_params(pid, step)
		next_id = str(step.get("next", ""))
	if next_id == "" or _calling_step(calling, next_id).is_empty():
		_complete_calling(pid, entry, calling)
	else:
		entry.step = next_id
		entry.since_day = clock.day   # fresh clock for the new step's own wait:days, if any
	if journal_open:
		_toggle_journal(true)
	_refresh_hud()

func _complete_calling(pid: int, entry: Dictionary, calling: Dictionary) -> void:
	var rewards: Dictionary = calling.get("rewards", {})
	for it: Dictionary in rewards.get("items", []):
		inventory.add(pid, str(it.itemId), int(it.qty))
	for god_id: String in rewards.get("favor", {}):
		devotion.work_favor_hour(pid, god_id, float(rewards.favor[god_id]))
	_active_callings(pid).erase(entry)
	_done_callings(pid).append(str(calling.id))
	if pid == my_pid:
		sfx("bloom")
		message = "A calling answered: \"%s\".\n%s" % [str(calling.title), str(calling.get("echo", {}).get("text", ""))]

func _toggle_journal(open: bool) -> void:
	journal_open = open
	var m: Dictionary = modals.get("journal", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	(m.footer as Label).text = "[1..] choose or continue   ·   [J] close"
	var active := _active_callings(my_pid)
	var lines: Array[String] = []
	if active.is_empty():
		lines.append("The flats have asked nothing of you yet.")
		lines.append("Kneel to a god, take in survivors, walk far — and callings will find you.")
	else:
		var entry: Dictionary = active[0]
		var calling := registry.get_entity(str(entry.id))
		var step := _calling_step(calling, str(entry.step))
		var giver: Dictionary = calling.get("giver", {})
		lines.append("» %s" % str(calling.title).to_upper())
		lines.append("  %s — %s" % [str(giver.get("name", "")), str(giver.get("wound", ""))])
		lines.append("")
		lines.append(str(step.get("text", "")))
		var has_params: bool = not (step.get("params", {}) as Dictionary).is_empty()
		var sm := _step_met(my_pid, entry, step) if has_params else {"met": true, "progress": ""}
		if has_params and str(sm.progress) != "":
			lines.append("· %s ·" % str(sm.progress))
		lines.append("")
		var options: Array = step.get("options", [])
		if options.size() > 0:
			for i in options.size():
				lines.append("  %d. %s" % [i + 1, str(options[i].text)])
		elif has_params and not bool(sm.met):
			lines.append("  1. (not yet) continue")
		else:
			lines.append("  1. continue")
		if active.size() > 1:
			lines.append("")
			lines.append("Also carried:")
			for k in range(1, active.size()):
				lines.append("  · %s" % str(registry.get_entity(str(active[k].id)).title))
	journal.text = "\n".join(lines)

## --- housing: everyone gets a bunk if there's room -----------------------------
## Deterministic: huts sorted by instance id offer `houses` bunks each; the
## roster (sorted by tribesman id) claims them in order. Returns this villager's
## hut door position, or INF if the village is short on roofs.
func house_slot_for(v: DSVillager) -> Vector2:
	var bunks: Array[Vector2] = []
	var hut_ids: Array = []
	for inst_id: Variant in works.placed:
		if int(registry.get_entity(str(works.placed[inst_id].work_id)).get("houses", 0)) > 0:
			hut_ids.append(int(inst_id))
	hut_ids.sort()
	for hid: int in hut_ids:
		var inst: Dictionary = works.placed[hid]
		var cap := int(registry.get_entity(str(inst.work_id)).get("houses", 0))
		for b in cap:
			bunks.append(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
	if bunks.is_empty():
		return Vector2.INF
	var sleepers: Array = all_villagers().filter(func(w: DSVillager) -> bool:
		return w.rescued and not w.is_captive)
	sleepers.sort_custom(func(a: DSVillager, b: DSVillager) -> bool: return a.tribesman_id < b.tribesman_id)
	var i := sleepers.find(v)
	if i < 0 or i >= bunks.size():
		return Vector2.INF   # no bunk left — the hearth-huddle keeps them
	return bunks[i]

## --- the Offertory: the altar's two halves, one numbered list -----------------
## The nearest placed altar within reach, or -1.
func _altar_near() -> int:
	var best := -1
	var best_d := interact_range() + 30.0   # a shade forgiving; altars are furniture
	for inst_id: Variant in works.placed:
		if not sanctum.is_altar(int(inst_id)):
			continue
		var inst: Dictionary = works.placed[inst_id]
		var d: float = player.position.distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
		if d < best_d:
			best_d = d
			best = int(inst_id)
	return best

## Should E open the Offertory here? The altar claims E only when it's closer
## than any chapel with a rite still pending — the day's rite always has a way in.
func _offertory_takes_e() -> int:
	var altar := _altar_near()
	if altar < 0:
		return -1
	var inst: Dictionary = works.placed[altar]
	var altar_d: float = player.position.distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
	for god_id: String in chapels:
		if not rites_done_today.get(god_id, false) \
				and player.position.distance_to(chapels[god_id]) < minf(altar_d, interact_range()):
			return -1
	return altar

func _toggle_offertory(open: bool, inst_id: int = -1) -> void:
	offertory_open = open
	offertory_inst = inst_id if open else -1
	var m: Dictionary = modals.get("offertory", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open or not sanctum.is_altar(inst_id):
		return
	var god_id := str(sanctum.state[inst_id].god_id)
	var god_name := str(registry.get_entity(god_id).name)
	offertory_title.text = "THE OFFERTORY — %s" % god_name.to_upper()
	var s: Dictionary = sanctum.state[inst_id]
	var tier := devotion.favor_tier(my_pid, god_id)
	var slots := sanctum.relic_slots(inst_id, tier)
	offertory_items = []
	var lines: Array[String] = []
	# the god's worn equipment
	lines.append("RELICS  (%d of %d slots — the god's worn stories)" % [(s.relics as Array).size(), slots])
	for relic_id: String in s.relics:
		offertory_items.append({"id": relic_id, "op": "take"})
		lines.append("  %d. %s   — displayed; press to take back" % [offertory_items.size(), str(registry.get_entity(relic_id).name)])
	if (s.relics as Array).is_empty():
		lines.append("  (bare stone — relics come from callings and great deeds)")
	lines.append("")
	# the god's pack
	lines.append("LAID OUT  (the dawn tithe takes a little each day)")
	var bag: Dictionary = s.bag
	for item_id: String in bag:
		offertory_items.append({"id": item_id, "op": "take"})
		lines.append("  %d. %s ×%d   — %s; press to take ALL back" % [offertory_items.size(),
			str(registry.get_entity(item_id).name), int(bag[item_id]), sanctum.lane(god_id, item_id)])
	if bag.is_empty():
		lines.append("  (nothing — a dry altar is just furniture)")
	lines.append("")
	# the community stores, annotated with the god's appetite — offerings are communal
	lines.append("THE STORES  (the village gives; [G] at the hearth to pool your pack)")
	var any := false
	var store_keys := village_stock.keys()
	store_keys.sort()
	for item_id: String in store_keys:
		if offertory_items.size() >= 9:
			break
		if int(village_stock[item_id]) <= 0:
			continue
		var lane := sanctum.lane(god_id, item_id)
		if lane == "ignores":
			lines.append("      %s ×%d — %s ignores this" % [str(registry.get_entity(item_id).name),
				int(village_stock[item_id]), god_name])
			continue
		offertory_items.append({"id": item_id, "op": "lay"})
		var note := lane + "; press to lay one"
		if lane == "offends":
			note = "OFFENDS — the flats will remember"
		lines.append("  %d. %s ×%d   — %s" % [offertory_items.size(),
			str(registry.get_entity(item_id).name), int(village_stock[item_id]), note])
		any = true
	if not any:
		lines.append("  (nothing %s wants on the shelves — gather what they crave)" % god_name)
	# relics stay personal: yours to place, from your own pack
	var relic_lines := 0
	for item_id: String in inventory._inv(my_pid).keys():
		if offertory_items.size() >= 9 or sanctum.relic_points(item_id) <= 0.0:
			continue
		if relic_lines == 0:
			lines.append("")
			lines.append("YOUR PACK  (relics are yours alone)")
		offertory_items.append({"id": item_id, "op": "lay"})
		lines.append("  %d. %s   — a relic; press to display it" % [offertory_items.size(), str(registry.get_entity(item_id).name)])
		relic_lines += 1
	offertory_label.text = "\n".join(lines)
	var spl := sanctum.splendor(inst_id)
	(modals.offertory.footer as Label).text = "splendor ×%.1f — rites to %s return %s   ·   [1-%d] lay ONE / take back   ·   [E] close" % [
		spl, god_name, ("more" if spl > 1.05 else ("LESS — something offends" if spl < 0.95 else "the usual")), maxi(offertory_items.size(), 1)]

## --- the Drill-Yard: train a villager's Arms class (VILLAGER-AND-GODHEAD-SPEC Part I §1) ---
func _drill_takes_e() -> int:
	var best := -1
	var best_d := interact_range()
	for inst_id: Variant in works.placed:
		if str(works.placed[inst_id].work_id) != "work-drill-yard":
			continue
		var inst: Dictionary = works.placed[inst_id]
		var d := acting_pos().distance_to(Vector2(float(inst.get("x", 0)), float(inst.get("y", 0))))
		if d < best_d:
			best_d = d
			best = int(inst_id)
	return best

func _toggle_drill(open: bool, inst_id: int = -1) -> void:
	drill_open = open
	drill_inst = inst_id if open else -1
	var m: Dictionary = modals.get("drill", {})
	if m.is_empty():
		return
	(m.root as Control).visible = open
	if not open:
		return
	drill_step = "villager"
	drill_villager_id = -1
	_render_drill()

func _render_drill() -> void:
	var m: Dictionary = modals.get("drill", {})
	if m.is_empty() or not drill_open:
		return
	drill_items = []
	var lines: Array[String] = []
	if drill_step == "villager":
		(m.title as Label).text = "THE DRILL-YARD"
		var roster := all_villagers().filter(func(v: DSVillager) -> bool: return v.rescued and v.tribesman_id >= 0 and not v.is_captive)
		if roster.is_empty():
			lines.append("No one free to train. Rescue someone first.")
		else:
			for v: DSVillager in roster:
				drill_items.append(v.tribesman_id)
				var arms: Dictionary = village.tribesmen.get(v.tribesman_id, {}).get("arms", {})
				var cur := str(arms.get("class_id", ""))
				var cur_txt := "untrained"
				if cur != "":
					cur_txt = "%s %d" % [str(registry.get_entity(cur).name), village.arms_level(v.tribesman_id)]
				lines.append("  %d. %s — %s" % [drill_items.size(), v.display_name, cur_txt])
		(m.footer as Label).text = "[1-9] choose a villager   ·   [E] close"
	else:
		(m.title as Label).text = "THE DRILL-YARD — assign a class"
		var rec: Dictionary = village.tribesmen.get(drill_villager_id, {})
		lines.append("Training %s:" % _villager_name(drill_villager_id))
		lines.append("")
		for cls: Dictionary in registry.all_of("arms"):
			var cls_id := str(cls.id)
			drill_items.append(cls_id)
			var req: Dictionary = cls.get("requires", {})
			var why := ""
			if req.has("minFaith") and float(rec.get("faith", 0)) < float(req.minFaith):
				why = "needs faith %d (has %d)" % [int(req.minFaith), int(rec.get("faith", 0))]
			if req.get("needsPatron", false) and str(rec.get("patron_god_id", "")) == "":
				why += (" · " if why != "" else "") + "needs a patron god"
			var lvl := village.arms_level_for(drill_villager_id, cls_id)
			var lvl_txt := "  (banked level %d)" % lvl if lvl > 0 else ""
			if why == "":
				lines.append("  %d. %s%s — %s" % [drill_items.size(), str(cls.name), lvl_txt, str(cls.text)])
			else:
				lines.append("  %d. %s — UNAVAILABLE: %s" % [drill_items.size(), str(cls.name), why])
		(m.footer as Label).text = "[1-3] assign   ·   [ESC] back   ·   [E] close"
	(m.body as Label).text = "\n".join(lines)

## Assign an Arms class. Bans nothing client-side that the sim wouldn't already
## reject (the Acolyte gate is enforced in village_system.train_arms); the modal
## just SHOWS the why, per the UI law (no hidden math).
func intent_drill_train(villager_id: int, class_id: String) -> bool:
	if net_mode == "client":
		rpc_id(1, "srv_intent", "drill_train", [villager_id, class_id])
		return true
	var ok := village.train_arms(villager_id, class_id)
	if ok:
		message = "%s begins training as a %s." % [_villager_name(villager_id), str(registry.get_entity(class_id).name)]
		var v := _villager_by_tid(villager_id)
		if v != null:
			v._refresh_label()
	else:
		message = "They don't meet the calling yet — the Acolyte wants faith and a patron."
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())
	return ok

## --- One-shot audio, guarded for the headless server.
func sfx(name: String, at := Vector2.INF, base_db := 0.0) -> void:
	if net_mode != "server" and sound != null:
		sound.play(name, at, player.position if at != Vector2.INF else Vector2.INF, base_db)

## Move a placed work (drag-drop commit). Server/offline authority.
func _move_work(inst_id: int, pos: Vector2) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	var old_pos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	# the hearth carries the whole ring with it; every other piece must stay inside
	var is_hearth := str(inst.work_id) == "work-hearth"
	if not is_hearth and camp_center != Vector2.INF and pos.distance_to(camp_center) > CAMP_RADIUS:
		if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
			(work_visuals[inst_id] as Node2D).position = old_pos   # snap back
		message = "That's outside the hearth's ring."
		_refresh_hud()
		return
	inst.x = pos.x
	inst.y = pos.y
	# a chapel carries its dedication with it
	for god_id: String in chapels.keys():
		if (chapels[god_id] as Vector2).distance_to(old_pos) < 1.0:
			chapels[god_id] = pos
	if is_hearth:
		_recenter_on_hearth()   # drag the hearth, and the village moves with it
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		(work_visuals[inst_id] as Node2D).position = pos
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Reclaim a placed work: remove it and refund HALF its build cost (rounded down).
## The kindest "sell" the flats offer — there's no merchant, only what you salvage back.
func _demolish_work(inst_id: int) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	var work := registry.get_entity(str(inst.work_id))
	var pos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
	var refunded: Array[String] = []
	for c: Dictionary in work.get("buildCost", []):
		var back := int(c.qty) / 2
		if back > 0:
			inventory.add(acting_pid, str(c.itemId), back)
			refunded.append("%d %s" % [back, str(registry.get_entity(str(c.itemId)).get("name", c.itemId))])
	# forget chapel dedication if this was one
	for god_id: String in chapels.keys():
		if (chapels[god_id] as Vector2).distance_to(pos) < 4.0:
			chapels.erase(god_id)
	# an altar gives back what was laid on it — relics to your pack, offerings to
	# the community stores they came from
	if sanctum.is_altar(inst_id):
		var contents := sanctum.unregister(inst_id)
		for relic_id: String in contents.get("relics", []):
			inventory.add(acting_pid, relic_id, 1)
		var bag: Dictionary = contents.get("bag", {})
		for item_id: String in bag:
			village_stock[item_id] = int(village_stock.get(item_id, 0)) + int(bag[item_id])
	works.placed.erase(inst_id)
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		work_visuals[inst_id].queue_free()
	work_visuals.erase(inst_id)
	# the ring follows the hearth: reclaim the hearth and the village loses its
	# center (raise a new one to re-found), reclaim anything else and it holds
	_recenter_on_hearth()
	_recompute_memorial()
	sfx("build")
	message = "You reclaim the %s.%s" % [str(work.name).to_lower(),
		"  Salvaged: %s." % ", ".join(refunded) if refunded.size() > 0 else ""]
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Rotate a placed work 90° (walls, fences — everything can turn).
func _rotate_work(inst_id: int) -> void:
	if not works.placed.has(inst_id):
		return
	var inst: Dictionary = works.placed[inst_id]
	inst.rot = (int(inst.get("rot", 0)) + 90) % 360
	if work_visuals.has(inst_id) and is_instance_valid(work_visuals[inst_id]):
		(work_visuals[inst_id] as Node2D).rotation_degrees = float(inst.rot)
	sfx("build")
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Shared by building and loading: the physical body of a placed work.
## chapel_hint maps god_id -> [x, y] from a save; empty when building live.
func _spawn_work_visual(inst_id: int, work_id: String, pos: Vector2, chapel_hint: Dictionary) -> void:
	var work := registry.get_entity(work_id)
	var work_sprites := {
		"work-workbench": "workbench", "work-chapel": "chapel", "work-smokehouse": "smokehouse",
		"work-hearth": "hearth", "work-driftwood-wall": "wall", "work-yoke-post": "yoke_post",
		"work-salt-cellar": "salt_cellar", "work-lightning-rod": "lightning_rod",
		"work-storm-cistern": "storm_cistern",
		"work-altar-halor": "altar", "work-altar-maren": "altar", "work-altar-neris": "altar",
		"work-driftwood-cot": "cot_hut", "work-tent": "tent",
		"work-salt-wheel": "salt_wheel",
		"work-tide-bell": "tide_bell", "work-healing-bath": "healing_bath",
		"work-kennel": "kennel", "work-reef-forge": "reef_forge",
		# M3.b: target sprite names for the art pass — no PNGs exist yet, so
		# SpriteKit.sprite falls back to its ColorRect placeholder automatically
		# (same as every other work above did before its art shipped).
		"work-taming-post": "taming_post", "work-stable": "stable",
		"work-board-road": "board_road", "work-porters-post": "porters_post",
	}
	var fallback := Color("6e5138") if not work.get("grim", false) else Color("5b3a6e")
	if work_id == "work-reef-forge":
		fallback = Color("6a5d78")   # muted reef purple (STYLE-BIBLE)
	if work_id == "work-altar-halor":
		fallback = Color("e8e2d4")   # salt-pale
	elif work_id == "work-altar-maren":
		fallback = Color("aebfc9")   # storm-light
	if work_id == "work-chapel":
		fallback = Color("f2efe8")
	var visual := SpriteKit.sprite(work_sprites.get(work_id, "none"),
		Vector2(28, 28) if work_id != "work-chapel" else Vector2(40, 48), fallback)
	visual.position = pos
	if work_id == "work-chapel":
		var god_id := ""
		if chapel_hint.is_empty():
			for g: String in attuned_for(acting_pid):
				if not chapels.has(g):
					god_id = g
					break
		else:
			for g: Variant in chapel_hint:
				var hp: Array = chapel_hint[g]
				if Vector2(float(hp[0]), float(hp[1])).distance_to(pos) < 4.0:
					god_id = str(g)
					break
		if god_id != "":
			chapels[god_id] = pos
			if god_id == "god-maren":
				visual.modulate = Color(0.82, 0.88, 1.0)
			visual.add_child(_world_label("chapel of %s" % str(registry.get_entity(god_id).name), Vector2(0, 30)))
	visual.set_meta("inst_id", inst_id)
	if works.placed.has(inst_id):
		visual.rotation_degrees = float(works.placed[inst_id].get("rot", 0))
	if work.get("blocks", false):
		var body := StaticBody2D.new()
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(30, 14)   # a wall segment's footprint (rotates with the visual)
		shape.shape = rect
		body.add_child(shape)
		visual.add_child(body)
	work_visuals[inst_id] = visual
	add_child(visual)

## Some works ARE what a villager needed (their Key). The chapel gives the
## devout their shrine; the hearth gives the storyteller their fire.
const WORK_KEYS := {"work-chapel": "shrine-access", "work-hearth": "audience-kept"}

func _check_village_keys() -> void:
	for work_id: String in WORK_KEYS:
		if works.count_of(work_id) == 0:
			continue
		for id: int in village.tribesmen:
			var rec: Dictionary = village.tribesmen[id]
			if rec.key == WORK_KEYS[work_id] and not rec.key_met:
				village.meet_key(id)
				sfx("bloom")
				message = "%s has what they needed — watch them work now." % str(rec.name)
				if survivor != null and survivor.tribesman_id == id:
					survivor.modulate = Color(1.12, 1.04, 0.92)  # bloomed: a touch warmer

## The view follows your own body and stops at the world's edge — so the flats
## fill the screen and you never scroll off into the void beyond the map.
func _attach_camera() -> void:
	var cam := Camera2D.new()
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = WORLD.x * TILE
	cam.limit_bottom = WORLD.y * TILE
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	player.add_child(cam)
	cam.make_current()

## --- world (placeholder) ---------------------------------------------------------
## B1, the Salt Shallows: byte-identical forever (REEF-FOREST-SPEC §1's hard
## law). Sized/seeded off NORTH_H, never WORLD.y — the map growing south must
## not move one pillar, pool, wreck, or node here.
func _build_ground() -> void:
	var ground_tex := SpriteKit.texture("ground")
	if ground_tex != null:
		var ground := TextureRect.new()
		ground.texture = ground_tex
		ground.stretch_mode = TextureRect.STRETCH_TILE
		ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ground.size = Vector2(WORLD.x * TILE, NORTH_H * TILE)
		ground.z_index = -10
		add_child(ground)
	else:
		var flat := ColorRect.new()
		flat.size = Vector2(WORLD.x * TILE, NORTH_H * TILE)
		flat.color = Color("e8e2d4")   # blinding flats, high-key
		flat.z_index = -10
		add_child(flat)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	brine_pools.clear()
	for i in 40:  # salt pillars + brine pools: the flats aren't flat
		var pillar := rng.randf() < 0.5
		var deco := SpriteKit.sprite("salt_pillar" if pillar else "brine_pool",
			Vector2(14, 22) if pillar else Vector2(18, 8),
			Color("f7f5ee") if pillar else Color("cfd8d2"))
		deco.position = Vector2(rng.randi_range(16, WORLD.x * TILE - 16), rng.randi_range(16, NORTH_H * TILE - 16))
		deco.z_index = -9
		add_child(deco)
		if not pillar:
			brine_pools.append(deco.position)   # so calling params can send you to "the nearest brine pool"
	# the dead fleet: beached wrecks, the bones of the coast towns
	for pos: Vector2 in [LANTERN_WRECK_POS, WRECK_EAST_POS, WRECK_MID_POS]:
		var wreck := SpriteKit.sprite("wreck", Vector2(60, 40), Color("6e5138"))
		wreck.position = pos
		wreck.z_index = -8
		wreck.modulate = Color(1, 1, 1, 0.96)
		add_child(wreck)
	_spawn_scarp()

func _spawn_resource_nodes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var biome := registry.get_entity("biome-salt-shallows")
	var idx := 0
	var taken_tiles := {}
	for item_id: String in biome.get("resourceItemIds", []):
		for i in 14:
			var tile := Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(2, NORTH_H - 2))
			while taken_tiles.has(tile):
				tile = Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(2, NORTH_H - 2))
			taken_tiles[tile] = true
			var pos := Vector2(tile.x * TILE, tile.y * TILE)
			node_defs.append({"item_id": item_id, "pos": pos, "idx": idx})
			_spawn_one_node(item_id, pos, idx)
			idx += 1

## REEF-FOREST-SPEC §1: the Reef Forest band, appended south of the scarp.
## Its OWN RandomNumberGenerator (SOUTH_BAND_SEED, documented, never 7/11/23)
## — generates ground, canopy pillars, the three drowned-town ruin markers,
## and B2 resource nodes. Runs on server AND client (deterministic, like
## _spawn_resource_nodes above) so it never needs syncing over the wire.
func _spawn_south_band() -> void:
	var south_top := float(NORTH_H * TILE)
	var south_h := float((WORLD.y - NORTH_H) * TILE)
	var reef_tex := SpriteKit.texture("ground_reef")
	if reef_tex != null:
		var ground := TextureRect.new()
		ground.texture = reef_tex
		ground.stretch_mode = TextureRect.STRETCH_TILE
		ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ground.position = Vector2(0, south_top)
		ground.size = Vector2(WORLD.x * TILE, south_h)
		ground.z_index = -10
		add_child(ground)
	else:
		var flat := ColorRect.new()
		flat.position = Vector2(0, south_top)
		flat.size = Vector2(WORLD.x * TILE, south_h)
		flat.color = Color("6a5d78")   # muted reef purple (STYLE-BIBLE cold-palette bias)
		flat.z_index = -10
		add_child(flat)

	var rng := RandomNumberGenerator.new()
	rng.seed = SOUTH_BAND_SEED
	# sparse canopy pillars: blocking, like walls (petrified-coral trunks)
	for i in SOUTH_CANOPY_PILLAR_COUNT:
		var pos := Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(NORTH_H + 2, WORLD.y - 2) * TILE)
		var deco := SpriteKit.sprite("coralwood", Vector2(20, 44), Color("7a6a86"))
		deco.position = pos
		deco.z_index = -8
		var body := StaticBody2D.new()
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(16, 16)
		shape.shape = rect
		body.add_child(shape)
		deco.add_child(body)
		add_child(deco)

	# three drowned-town ruin clusters: deco only this slice (M3.d houses their
	# content) — a modest cluster of tinted, rotated wreck decos per site.
	for ruin_pos: Vector2 in [DROWNED_RUIN_1_POS, DROWNED_RUIN_2_POS, DROWNED_RUIN_3_POS]:
		for i in 3:
			var ruin := SpriteKit.sprite("wreck", Vector2(46, 30), Color("585268"))
			ruin.position = ruin_pos + Vector2((i - 1) * 40.0, rng.randf_range(-14.0, 14.0))
			ruin.rotation_degrees = rng.randf_range(-45.0, 45.0)
			ruin.modulate = Color(0.75, 0.72, 0.82, 0.95)
			ruin.z_index = -8
			add_child(ruin)
		var marker := Node2D.new()
		marker.position = ruin_pos
		marker.add_child(_world_label("a drowned town", Vector2(0, 20)))
		add_child(marker)

	# B2 resource nodes: mattock-gated (gather.tierRequired on the item data),
	# hits per CRAFT-AND-BUILD-SPEC Part 2 (6/5/4/3).
	var taken_tiles := {}
	for item_id: String in SOUTH_NODE_COUNTS:
		for i in int(SOUTH_NODE_COUNTS[item_id]):
			var tile := Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(NORTH_H + 2, WORLD.y - 2))
			while taken_tiles.has(tile):
				tile = Vector2i(rng.randi_range(2, WORLD.x - 2), rng.randi_range(NORTH_H + 2, WORLD.y - 2))
			taken_tiles[tile] = true
			var pos := Vector2(tile.x * TILE, tile.y * TILE)
			var idx := node_defs.size()
			node_defs.append({"item_id": item_id, "pos": pos, "idx": idx})
			_spawn_one_node(item_id, pos, idx)
	# everything deterministic (both bands) has now been minted; only defs
	# APPENDED after this point (boss hoard, corpse drops) are truly dynamic
	# and need to ride cl_world_sync's extra_defs.
	_static_node_def_count = node_defs.size()

## The border scarp: a broken shelf along the old south rim, passable only at
## the Stair of Hulls (REEF-FOREST-SPEC §1). Two thin StaticBody2D segments —
## the shipped blocking-wall pattern (_spawn_work_visual's `blocks`) — with a
## STAIR_GAP_HALF-wide gap at STAIR_OF_HULLS_POS. Teleports (every test's
## harness, and player respawn) don't collide, so this can't strand anything.
func _spawn_scarp() -> void:
	var gap_left := STAIR_OF_HULLS_POS.x - STAIR_GAP_HALF
	var gap_right := STAIR_OF_HULLS_POS.x + STAIR_GAP_HALF
	_spawn_scarp_wall(0.0, gap_left)
	_spawn_scarp_wall(gap_right, WORLD.x * TILE)
	# ship-graveyard deco at the gap: the beached-wreck sprite, rotated/tinted
	var wrng := RandomNumberGenerator.new()
	wrng.seed = 8800   # deco-only, distinct from the boss-hoard rng's seed 77 (unrelated RNG instances, no actual collision, but keep them visually distinct in review)
	for i in 3:
		var wreck := SpriteKit.sprite("wreck", Vector2(52, 34), Color("53505c"))
		wreck.position = STAIR_OF_HULLS_POS + Vector2((i - 1) * 46.0, wrng.randf_range(-10.0, 10.0))
		wreck.rotation_degrees = wrng.randf_range(-30.0, 30.0)
		wreck.modulate = Color(0.7, 0.68, 0.76, 0.95)
		wreck.z_index = -8
		add_child(wreck)
	var marker := Node2D.new()
	marker.position = STAIR_OF_HULLS_POS
	marker.add_child(_world_label("the Stair of Hulls", Vector2(0, 22)))
	add_child(marker)

func _spawn_scarp_wall(x0: float, x1: float) -> void:
	if x1 <= x0:
		return
	var body := StaticBody2D.new()
	body.position = Vector2((x0 + x1) / 2.0, SCARP_Y)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(x1 - x0, 16.0)
	shape.shape = rect
	body.add_child(shape)
	add_child(body)

const NODE_SPRITES := {
	"item-driftwood": "driftwood", "item-wreck-timber": "timber",
	"item-ship-cloth": "cloth", "item-salt": "salt_mound", "item-bronze-salvage": "bronze",
	"item-rope": "rope", "item-storm-glass": "bronze",
	"item-coralwood": "coralwood", "item-reef-iron": "reef_iron",
	"item-pearl": "pearl_bed", "item-anemone-silk": "anemone_silk",
}

func _spawn_one_node(item_id: String, pos: Vector2, idx: int) -> Area2D:
	var node := Area2D.new()
	node.position = pos
	node.set_meta("item_id", item_id)
	node.set_meta("qty", 3)
	node.set_meta("idx", idx)
	# a workable node (gather.hits in item data) is cut/mined down hit by hit
	var hits := int(registry.get_entity(item_id).get("gather", {}).get("hits", 1))
	node.set_meta("hits", hits)
	node.set_meta("left", hits)
	var visual := SpriteKit.sprite(NODE_SPRITES.get(item_id, "none"),
		Vector2(16, 16), ITEM_COLORS.get(item_id, Color("c9a648")))
	if item_id == "item-storm-glass":
		visual.modulate = Color(1.3, 1.25, 0.7)   # fused sand, still warm from the sky
	node.add_child(visual)
	add_child(node)
	resource_nodes.append(node)
	return node

func _spawn_shrines() -> void:
	# Halor waits in the north; Maren on the east edge, where the weather comes from;
	# Neris waits in the south, where the tide would be if there still were one.
	_spawn_one_shrine("god-halor", Vector2(WORLD.x * TILE / 2.0, TILE * 5.0), Color.WHITE)
	_spawn_one_shrine("god-maren", Vector2(WORLD.x * TILE - TILE * 4.0, NORTH_H * TILE / 2.0), Color(0.82, 0.88, 1.0))
	_spawn_one_shrine("god-neris", Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE - TILE * 5.0), Color(0.75, 0.9, 0.95))
	# M3.b: Vessa and Ghal, fallen in the Reef Forest band (south of the scarp) —
	# the generic kneel -> attune flow (intent_kneel/intent_interact) needs no
	# per-god code, same as Neris before them (verified: it just iterates `shrines`).
	_spawn_one_shrine("god-vessa", VESSA_SHRINE_POS, Color(0.68, 0.86, 0.82))
	_spawn_one_shrine("god-ghal", GHAL_SHRINE_POS, Color(0.62, 0.56, 0.5))

func _spawn_one_shrine(god_id: String, pos: Vector2, tint: Color) -> void:
	var s := Node2D.new()
	s.position = pos
	s.set_meta("god_id", god_id)
	var visual := SpriteKit.sprite("shrine", Vector2(44, 44), Color("dce8e4"))
	visual.modulate = tint
	s.add_child(visual)
	s.add_child(_world_label("a fallen shrine", Vector2(0, 24)))
	add_child(s)
	shrines.append(s)

## Small in-world nameplates so landmarks read as themselves.
func _world_label(text: String, offset: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = offset + Vector2(-70, 0)
	l.custom_minimum_size = Vector2(140, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color("8a7a5c"))
	l.add_theme_font_size_override("font_size", 10)
	return l

## The name over a fellow player's head — outlined so it reads on the bright
## flats, and distinct from the muted villager labels. Matches your own tag.
func _player_name_tag(text: String) -> Label:
	var l := DSPlayer._make_name_tag()
	l.text = text
	return l

## Who you are on the flats: your join name (client), else your machine name, else "You".
func _local_display_name() -> String:
	if _username != "":
		return _username
	var u := OS.get_environment("USERNAME")
	return u if u != "" else "You"

func _spawn_survivor() -> void:
	survivor = DSVillager.new()
	survivor.host = self
	survivor.position = Vector2(TILE * 6.0, NORTH_H * TILE - TILE * 5.0)  # far southwest, by the wrecks
	add_child(survivor)
	if net_mode != "client":
		_spawn_stranded_pool()

## Scatter a handful of stranded coast-folk to find and bring home. Deterministic
## (seeded) so the server and every client agree on who is where.
func _spawn_stranded_pool() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	# fractions of the (north) world so they spread with the map instead of
	# clumping — NORTH_H, never WORLD.y: this is B1 seeded content (REEF-FOREST-SPEC §1)
	var w := WORLD.x * TILE
	var h := NORTH_H * TILE
	var spots := [Vector2(w * 0.92, h * 0.62), Vector2(w * 0.13, h * 0.56),
		Vector2(w * 0.83, h * 0.88), Vector2(w * 0.33, h * 0.84)]
	for i in spots.size():
		var v := DSVillager.new()
		v.host = self
		v.tribesman_id = -1
		_villager_nid += 1
		v.set_meta("nid", _villager_nid)
		v.display_name = NAME_POOL[rng.randi() % NAME_POOL.size()]
		v.def_class = CLASS_POOL[rng.randi() % CLASS_POOL.size()]
		var t1: String = TRAIT_POOL[rng.randi() % TRAIT_POOL.size()]
		var t2: String = TRAIT_POOL[rng.randi() % TRAIT_POOL.size()]
		v.def_traits = [t1] if t1 == t2 else [t1, t2]
		v.def_patron = "god-halor"
		v.position = spots[i]
		add_child(v)
		villagers.append(v)

func all_villagers() -> Array:
	var out: Array = []
	if survivor != null:
		out.append(survivor)
	out.append_array(villagers)
	return out

## The best claimable gear of a slot sitting in the stores (legends stay communal-
## never; they're player stories, not rack stock).
func _stock_best_gear(slot: String) -> String:
	var best := ""
	var best_stat := -1
	for item_id: String in village_stock:
		var item := registry.get_entity(item_id)
		if str(item.get("slot", "")) != slot or not item.get("legend", {}).is_empty():
			continue
		var stat := int(item.get("stats", {}).get("damage", item.get("stats", {}).get("defense", 0)))
		if stat > best_stat:
			best_stat = stat
			best = item_id
	return best

func _stock_covers(cost: Array) -> bool:
	for c: Dictionary in cost:
		if int(village_stock.get(str(c.itemId), 0)) < int(c.qty):
			return false
	return true

func _stock_pay(cost: Array) -> void:
	for c: Dictionary in cost:
		var item_id := str(c.itemId)
		village_stock[item_id] = int(village_stock.get(item_id, 0)) - int(c.qty)
		if int(village_stock[item_id]) <= 0:
			village_stock.erase(item_id)

func _stock_food_total() -> int:
	var n := 0
	for item_id: String in village_stock:
		if str(registry.get_entity(item_id).get("category", "")) == "food":
			n += int(village_stock[item_id])
	return n

func _stock_take_one_food() -> bool:
	for item_id: String in village_stock:
		if str(registry.get_entity(item_id).get("category", "")) == "food" and int(village_stock[item_id]) > 0:
			village_stock[item_id] = int(village_stock[item_id]) - 1
			if village_stock[item_id] <= 0:
				village_stock.erase(item_id)
			return true
	return false

## The village lives once a day: everyone works, eats, and their mood shifts.
## An Arms-classed villager who ends the day with no task (resting) trains
## instead, when a Drill-Yard stands — the safe, slow lane (VILLAGER-AND-
## GODHEAD-SPEC Part I §1, XP source drillDay). A standalone step (not folded
## into the work loop above) so it always runs exactly once per dawn,
## regardless of who else worked.
func _dawn_drill_training() -> Array[String]:
	var notes: Array[String] = []
	if works.count_of("work-drill-yard") <= 0:
		return notes
	for dv: DSVillager in all_villagers():
		if not dv.rescued or dv.tribesman_id < 0 or dv.is_captive or dv.task != "" or dv.on_road:
			continue
		if village.arms_level(dv.tribesman_id) <= 0:
			continue
		village.grant_xp(dv.tribesman_id, "drillDay")
		notes.append("%s drilled at the yard" % dv.display_name)
	return notes

## The Kennel's dawn feeding (VILLAGER-AND-GODHEAD-SPEC Part III): beasts fed
## from stores, from their craved food; unfed sulks and refuses the heel
## toggle. No kennel -> never fed_from_stores (the owner must feed by hand,
## [E]-with-food — handled in intent_feed_wild for wild beasts; a TAMED
## beast's hand-feeding isn't a separate verb at EA, a deliberate cut). Its
## own step, same shape as _dawn_drill_training, so it's testable in isolation
## from the rest of the village's labor/food economy.
func _beast_dawn_feeding() -> Array[String]:
	var notes: Array[String] = []
	# a Stable is the Kennel's B2 growth (CRAFT-AND-BUILD-SPEC Part 3) — either
	# one enables dawn feeding from stores.
	var stable_stands := works.count_of("work-stable") > 0
	var kennel_stands := works.count_of("work-kennel") > 0 or stable_stands
	for b: DSBeast in beasts:
		if not beast.beasts.has(b.beast_id):
			continue
		var craved := str(registry.get_entity(b.creature_id).get("tame", {}).get("cravedFoodItemId", ""))
		var fed := false
		if kennel_stands and craved != "" and int(village_stock.get(craved, 0)) > 0:
			village_stock[craved] = int(village_stock[craved]) - 1
			if int(village_stock[craved]) <= 0:
				village_stock.erase(craved)
			fed = true
		beast.dawn(b.beast_id, kennel_stands, fed)
		var rec: Dictionary = beast.beasts[b.beast_id]
		# MOOD-FLOOR DECISION (work-stable's own $comment in works.json, spec left
		# the exact shape open): a Stable prevents SULKING from hunger alone but
		# does NOT feed on its own — held at "content", never "keen" (keen still
		# costs a real meal). Presentation-side, same as everywhere else here
		# reads/overrides rec.mood after beast_system.dawn() runs; the sim call
		# itself is unchanged.
		if not fed and stable_stands and str(rec.mood) == "sulking":
			rec.mood = "content"
		b.mood = str(rec.mood)
		b.kenneled = bool(rec.kenneled)
		if not fed:
			notes.append(("%s holds steady at the Stable, unfed" % b.display_name) if stable_stands
				else ("%s went unfed and sulks" % b.display_name))
		if beast_role(b.creature_id) == "porter" and b._carried_since_dawn:
			beast.grant_xp(b.beast_id, "porterDay")
		b._carried_since_dawn = false
		b._tide_shell_used_today = false
		b._refresh_label()
	return notes

## Neris's Tide-Bell (CRAFT-AND-BUILD-SPEC Part 6): a rung day nudges the
## village's dawn output — "the village keeps time." Read by the dawn labor
## loop above; tide_bell_rang_today resets in _on_sim_day after this runs.
func _tide_bell_output_bonus() -> float:
	return 0.5 if tide_bell_rang_today else 0.0

func _village_dawn() -> void:
	_recompute_memorial()
	var rite_led := rites_done_today.values().any(func(v: bool) -> bool: return v)
	rites_done_today.clear()
	# 0. THE TAKEN: assign warden coverage; captives age a day
	var warden_cap := 0
	for v: DSVillager in all_villagers():
		if v.rescued and not v.is_captive and v.def_class == "class-warden":
			warden_cap += 3   # tune: takenPerWarden
	var covered := 0
	for v: DSVillager in all_villagers():
		if v.is_captive and v.tribesman_id >= 0:
			v.days_held += 1
			var rec2: Dictionary = village.tribesmen.get(v.tribesman_id, {})
			if not rec2.is_empty():
				rec2.warden_covered = covered < warden_cap
				covered += 1
	# 1. WORK: the village reassesses its needs and everyone works their task
	_assign_village_tasks()
	var produced := {}   # item_id -> total qty
	var scared := 0
	var dawn_notes: Array[String] = []
	for v: DSVillager in all_villagers():
		if not v.rescued or v.tribesman_id < 0 or v.is_captive or v.task == "":
			continue
		if v.needs_help:
			scared += 1
			continue   # spent the day cowering at home, no work done
		var task: String = v.task
		var station: String = TASK_STATION[task]
		if station != "" and works.count_of(station) == 0:
			continue
		if station != "":   # their labor keeps the station fed to its god
			for inst_id: Variant in works.placed:
				if str(works.placed[inst_id].work_id) == station:
					works.set_in_use(int(inst_id), true)
					break
		var suit: float = float(CLASS_SUIT.get(v.def_class, {}).get(task, 0.5))
		var qty := int(round(TASK_BASE * suit * village.output_per_hour(v.tribesman_id) + _tide_bell_output_bonus()))
		if qty <= 0:
			continue
		# gather tasks work a REAL node: the nearest within the forage leash, worn
		# down by the day's labor. Nothing in reach = nothing gathered.
		if TASK_FORAGE_ITEM.has(task):
			var node := _nearest_node_of(TASK_FORAGE_ITEM[task], village_heart(), _task_leash(task))
			if node == null:
				var note := "no %s within the village's reach" % str(registry.get_entity(TASK_FORAGE_ITEM[task]).name).to_lower()
				if note not in dawn_notes:
					dawn_notes.append(note)
				continue
			qty = mini(qty, int(node.get_meta("left", 1)))
			_deplete_node(node, qty)
		var item_id: String = TASK_ITEM[task]
		village_stock[item_id] = int(village_stock.get(item_id, 0)) + qty
		produced[item_id] = int(produced.get(item_id, 0)) + qty
	dawn_notes.append_array(_dawn_drill_training())
	# 1b. THE KITCHEN: raw meat in the stores gets smoked before breakfast —
	# villagers craft the basics they need without being told
	if works.count_of("work-smokehouse") > 0 and int(village_stock.get("item-crab-meat", 0)) > 0:
		var cooks := 4
		for v: DSVillager in all_villagers():
			if v.rescued and not v.is_captive and v.task == "food":
				cooks += 2   # someone on the cooking task keeps the fires hotter
				break
		var raw := mini(cooks, int(village_stock.get("item-crab-meat", 0)))
		village_stock["item-crab-meat"] = int(village_stock["item-crab-meat"]) - raw
		if int(village_stock["item-crab-meat"]) <= 0:
			village_stock.erase("item-crab-meat")
		village_stock["item-smoked-crab"] = int(village_stock.get("item-smoked-crab", 0)) + raw
		for inst_id: Variant in works.placed:
			if str(works.placed[inst_id].work_id) == "work-smokehouse":
				works.set_in_use(int(inst_id), true)   # the kitchen's labor feeds Halor too
				break
		dawn_notes.append("the kitchen smoked %d crab" % raw)
	# 1c. THE ARMORY: wardens arm themselves from the stores — claim the best
	# weapon and armor lying there, or craft a simple club when the racks are bare
	for v: DSVillager in all_villagers():
		if not v.rescued or v.is_captive:
			continue
		if v.def_class != "class-warden" and village.arms_level(v.tribesman_id) <= 0:
			continue   # generalized to ALL Arms-classed villagers, not just wardens
		if v.warden_weapon == "":
			var best := _stock_best_gear("weapon")
			if best == "" and _stock_covers(registry.get_entity("recipe-driftwood-club").get("inputs", [])):
				_stock_pay(registry.get_entity("recipe-driftwood-club").get("inputs", []))
				best = "item-driftwood-club"
				dawn_notes.append("%s lashed together a club" % v.display_name)
			elif best != "":
				village_stock[best] = int(village_stock.get(best, 0)) - 1
				if int(village_stock[best]) <= 0:
					village_stock.erase(best)
				dawn_notes.append("%s took up the %s" % [v.display_name, str(registry.get_entity(best).name).to_lower()])
			v.warden_weapon = best
			if v.tribesman_id >= 0 and village.tribesmen.has(v.tribesman_id):
				village.tribesmen[v.tribesman_id].equipment.weapon = best
		if v.warden_armor == "":
			var plate := _stock_best_gear("armor")
			if plate != "":
				village_stock[plate] = int(village_stock.get(plate, 0)) - 1
				if int(village_stock[plate]) <= 0:
					village_stock.erase(plate)
				v.warden_armor = plate
				dawn_notes.append("%s donned the %s" % [v.display_name, str(registry.get_entity(plate).name).to_lower()])
			if v.tribesman_id >= 0 and village.tribesmen.has(v.tribesman_id):
				village.tribesmen[v.tribesman_id].equipment.armor = plate
		v._refresh_label()
		if v.fought_defense_today:
			village.grant_xp(v.tribesman_id, "villageDefense")
			v.fought_defense_today = false
	# 1d. THE KENNEL (Part III): its own step (like _dawn_drill_training), so a
	# test can exercise it in isolation from the rest of the village economy.
	dawn_notes.append_array(_beast_dawn_feeding())
	# 1e. BAIT (Part III §2): uneaten drops spoil at dawn — its own step, same
	# reasoning as 1d above.
	dawn_notes.append_array(_bait_spoil_dawn())
	# 2. EAT + MOOD: each villager eats from the stores; hunger and neglect sour them
	var deserters: Array[DSVillager] = []
	var discovery_notes: Array[String] = []
	var chapel_stands := works.count_of("work-chapel") > 0
	for v: DSVillager in all_villagers():
		if not v.rescued or v.tribesman_id < 0:
			continue
		var conditions: Array = ["rested"]
		if rite_led:
			conditions.append("riteAttended")
		if not _stock_take_one_food():
			conditions.append("poorFood")   # hungry
		if str(v.def_patron) != "" and not chapels.has(v.def_patron):
			conditions.append("noShrineAccess")
		village.drift_day(v.tribesman_id, conditions)
		var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
		v.set_mood(str(rec.get("expression", "steady")))
		if str(rec.get("expression", "")) == "desertion":
			deserters.append(v)
		# THEIR WAYS: attention accrues whether or not today went well — a
		# scared or hungry villager is still watched, just not worked.
		var dctx: Array = []
		# a road day counts as a worked day for noticing: you watch them fight,
		# carry, and hold up (or not) at arm's length all day long
		if v.task != "" or v.on_road:
			dctx.append("worked")
		if chapel_stands:
			dctx.append("faith")
		if v.on_road:
			dctx.append("road")
		for tid: String in village.discovery_day(v.tribesman_id, dctx):
			var tr: Dictionary = registry.get_entity(tid)
			discovery_notes.append("You've come to know %s: %s. %s" % [v.display_name, str(tr.get("name", "?")), str(tr.get("discovery", ""))])
	# 3. CONSEQUENCE: the truly neglected walk off into the flats
	for v: DSVillager in deserters:
		message = "%s has left the village. The flats keep what a poor camp cannot." % v.display_name
		# a deserting warden leaves the village's arms on the rack
		for gear in [v.warden_weapon, v.warden_armor]:
			if str(gear) != "":
				village_stock[str(gear)] = int(village_stock.get(str(gear), 0)) + 1
		village.tribesmen.erase(v.tribesman_id)
		villagers.erase(v)
		if v == survivor:
			survivor.rescued = false
		v.queue_free()
	if net_mode != "client":
		var bits: Array[String] = []
		for item_id: String in produced:
			bits.append("%d %s" % [int(produced[item_id]), str(registry.get_entity(item_id).name)])
		var notes := ("  " + "; ".join(dawn_notes) + "." if dawn_notes.size() > 0 else "")
		if bits.size() > 0:
			message = "Dawn. The village worked: %s.%s%s" % [", ".join(bits),
				"  (%d hid from danger)" % scared if scared > 0 else "", notes]
		elif scared > 0:
			message = "Dawn. Danger kept your people home — nothing got done. Clear the flats." + notes
		elif dawn_notes.size() > 0:
			message = "Dawn." + notes
		# THEIR WAYS: a batched dawn report of anything newly noticed today —
		# the house voice, delivered the way work lines batch above.
		if discovery_notes.size() > 0:
			if message == "":
				message = "Dawn."
			message += "\n" + "\n".join(discovery_notes)
	if village_panel_open:
		_toggle_village(true)

## Kept for compatibility (unbind/rescue call it); real work is task-assigned.
func assign_job(v: DSVillager) -> void:
	_assign_village_tasks()

func _reassign_all_jobs() -> void:
	_assign_village_tasks()

## How badly the village wants each resource, 0 (full) .. ~1.5 (desperate).
func _need_priority() -> Dictionary:
	var out := {}
	for task: String in NEED_TARGETS:
		var have: int = _stock_food_total() if task == "food" else int(village_stock.get(TASK_ITEM[task], 0))
		var target: int = NEED_TARGETS[task]
		out[task] = clampf(float(target - have) / float(target), 0.0, 1.5)
	return out

## The village manages itself: each free villager takes the task where their
## suitability × the current need is highest. Short on wood, your best forager
## goes for wood; stores full, that task falls to the bottom.
func _assign_village_tasks() -> void:
	var pri := _need_priority()
	for v: DSVillager in all_villagers():
		if not v.rescued or v.is_captive or v.tribesman_id < 0:
			continue
		var suit: Dictionary = CLASS_SUIT.get(v.def_class, {})
		var best_task := ""
		var best_score := 0.05   # below this, idle (nothing worth doing)
		for task: String in NEED_TARGETS:
			var station: String = TASK_STATION[task]
			if station != "" and works.count_of(station) == 0:
				continue   # can't cook without a smokehouse, etc.
			var eff_pri := float(pri[task])
			if TASK_FORAGE_ITEM.has(task):
				if _nearest_node_of(TASK_FORAGE_ITEM[task], village_heart(), _task_leash(task)) == null:
					continue   # nothing in this task's reach — don't send anyone to nowhere
				# idle hands feed no gods: near nodes get worked even on full stores
				eff_pri = maxf(eff_pri, SURPLUS_PRIORITY)
			var score: float = eff_pri * float(suit.get(task, 0.5))
			if score > best_score:
				best_score = score
				best_task = task
		v.task = best_task

## Where a task is done: a station building, else a forage spot (nearest matching
## world node — which is where the danger is).
func task_work_zone(task: String) -> Vector2:
	# gather tasks work a real node: the one the dawn labor is draining (nearest
	# in the leash) — the villager stands at the wood they're cutting
	if TASK_FORAGE_ITEM.has(task):
		var node := _nearest_node_of(TASK_FORAGE_ITEM[task], village_heart(), _task_leash(task))
		if node != null:
			return node.position
	var station: String = TASK_STATION.get(task, "")
	if station != "":
		var post := work_pos(station)
		if post != Vector2.INF:
			return post
	return village_heart() + Vector2(90, -60)   # camp edge

## Distance to the nearest hostile (hound/raider) — used by villagers to flee.
func enemy_near_dist(from: Vector2) -> float:
	var best := INF
	for e in enemies:
		if is_instance_valid(e) and not e.peaceful and not e.surrendered and not e.is_boss:
			best = minf(best, from.distance_to(e.position))
	return best

func _nearest_hostile(from: Vector2, within: float) -> DSEnemy:
	var best := within
	var found: DSEnemy = null
	for e in enemies:
		if is_instance_valid(e) and not e.peaceful and not e.surrendered and not e.is_boss and not e.is_pacified():
			var d := from.distance_to(e.position)
			if d < best:
				best = d
				found = e
	return found

const WARDEN_DEFEND_RADIUS := 560.0
const RAIDER_CAP := 3   # storm days replenish raiders to this — the Taken system's supply line
const WARDEN_GUARD_RADIUS := 130.0
const WARDEN_DAMAGE := 13.0

## Where a warden is needed: the hostile nearest a threatened worker, else the
## hostile nearest the camp. INF = all quiet (the warden goes back to chores).
func warden_duty(_warden: DSVillager) -> Vector2:
	# a beast menacing any working villager is the priority — but NOT road
	# companions: a party out walking is the player's responsibility (Jeff,
	# 2026-07-17: wardens help villagers, not players), and without this
	# skip every aggro on the road pulled the whole watch cross-map.
	for v: DSVillager in all_villagers():
		if v.rescued and not v.is_captive and not v.on_road and v.def_class != "class-warden":
			var e := _nearest_hostile(v.position, DSVillager.DANGER_RADIUS + 40.0)
			if e != null:
				return e.position
	# else defend the camp itself
	var near := _nearest_hostile(village_heart(), WARDEN_DEFEND_RADIUS)
	return near.position if near != null else Vector2.INF

## A warden strikes the beast in front of them.
## What a warden's swing is worth: bare hands, or the weapon they claimed
## from the stores at dawn.
func warden_damage(warden: DSVillager) -> float:
	if warden.warden_weapon != "":
		var dmg := float(registry.get_entity(warden.warden_weapon).get("stats", {}).get("damage", 0))
		if dmg > 0.0:
			return dmg
	return WARDEN_DAMAGE

func warden_strike(warden: DSVillager) -> void:
	var e := _nearest_hostile(warden.position, DSVillager.WARDEN_STRIKE_RANGE)
	if e == null:
		return
	var dmg := warden_damage(warden)
	_flash_swing(e.position)
	sfx("hit", e.position)
	e.on_hit()
	warden.fought_defense_today = true   # villageDefense XP at dawn, if they're Arms-classed
	if e.subduable and not e.surrendered:
		var mh := float(registry.get_entity(e.creature_id).get("stats", {}).get("hp", 60))
		if stats.hp(e) - dmg <= mh * 0.25:
			stats.actors[e].hp = mh * 0.25
			e.surrender()   # wardens subdue raiders — a captive for the yoke
			return
	if stats.damage(e, dmg):
		_on_enemy_killed(e)

## Is a warden standing guard over this spot? A covered worker doesn't flee.
func warden_covers(pos: Vector2) -> bool:
	for v: DSVillager in all_villagers():
		if v.rescued and not v.is_captive and v.def_class == "class-warden" \
				and pos.distance_to(v.position) < WARDEN_GUARD_RADIUS:
			return true
	return false

## --- the road: companions (VILLAGER-AND-GODHEAD-SPEC Part I §4) --------------
## Where a companion's recruiter stands — server truth in co-op, your own body offline.
func companion_leader_pos(pid: int) -> Vector2:
	if net_mode == "server":
		return avatars.get(pid, Vector2.INF)
	return player.position if pid == my_pid or net_mode != "client" else Vector2.INF

## The current Arms class's behavior params (engageRange/breakHpPct/holdGround),
## or {} if unclassed. Villager.gd reads this every companion tick.
func arms_behavior(tid: int) -> Dictionary:
	var arms: Dictionary = village.tribesmen.get(tid, {}).get("arms", {})
	var cls_id := str(arms.get("class_id", ""))
	return registry.get_entity(cls_id).get("behavior", {}) if cls_id != "" else {}

func companion_melee_strike(v: DSVillager, e: DSEnemy) -> void:
	var dmg := warden_damage(v) * village.arms_primary_mult(v.tribesman_id)
	_flash_swing(e.position)
	sfx("hit", e.position)
	e.on_hit()
	v.fought_on_road = true
	if e.subduable and not e.surrendered:
		var mh := float(registry.get_entity(e.creature_id).get("stats", {}).get("hp", 60))
		if stats.hp(e) - dmg <= mh * 0.25:
			stats.actors[e].hp = mh * 0.25
			e.surrender()
			return
	if _mercy_kneel_check(e, dmg, v.companion_pid):
		return
	if stats.damage(e, dmg):
		_companion_credit_kill(v, e)

## Archer: same math, a line-flash instead of a swing — no projectile system yet.
func companion_ranged_strike(v: DSVillager, e: DSEnemy) -> void:
	var dmg := warden_damage(v) * village.arms_primary_mult(v.tribesman_id)
	_flash_ranged_line(v.position, e.position)
	sfx("hit", e.position)
	e.on_hit()
	v.fought_on_road = true
	if e.subduable and not e.surrendered:
		var mh := float(registry.get_entity(e.creature_id).get("stats", {}).get("hp", 60))
		if stats.hp(e) - dmg <= mh * 0.25:
			stats.actors[e].hp = mh * 0.25
			e.surrender()
			return
	if _mercy_kneel_check(e, dmg, v.companion_pid):
		return
	if stats.damage(e, dmg):
		_companion_credit_kill(v, e)

func _flash_ranged_line(from: Vector2, to: Vector2) -> void:
	var line := Line2D.new()
	line.add_point(from)
	line.add_point(to)
	line.width = 2.0
	line.default_color = Color("d9d2bf")
	add_child(line)
	get_tree().create_timer(0.12).timeout.connect(line.queue_free)

## A companion's kill briefly wears the recruiter's identity (loot, ledger) —
## _on_enemy_killed already hands out the Arms XP to everyone nearby, including them.
func _companion_credit_kill(v: DSVillager, e: DSEnemy) -> void:
	var prev := acting_pid
	if v.companion_pid > 0:
		acting_pid = v.companion_pid
	_on_enemy_killed(e)
	acting_pid = prev

## The Acolyte channels their patron's rank-1 invocation at their Lesser
## Invocation talent's channelStrength (arms-classes.json), scaled by their own
## level AND now their patron's live Godhead (Part II §6, "the interlock"):
## effective = base x channelStrength x arms_primary_mult x godhead. Feed
## Maren and every Maren-sworn Acolyte in the village hits harder that same
## day; let her gutter (or worse, get consumed) and effective_mult is 0 —
## skipped outright below, so a dead god's Acolytes fire nothing: "just
## people in robes, kneeling."
func companion_channel(v: DSVillager) -> void:
	var tid := v.tribesman_id
	for talent: Dictionary in village.ignited_talents(tid):
		for eff: Dictionary in talent.get("effects", []):
			if str(eff.get("type", "")) != "channel-invocation":
				continue
			var params: Dictionary = eff.get("params", {})
			if bool(params.get("oncePerFight", false)):
				continue   # tier-9 Intercession: a per-fight trigger, not this passive tick
			var rank := int(params.get("patronInvocationRank", 1))
			var patron_id := str(village.tribesmen.get(tid, {}).get("patron_god_id", ""))
			var gh_mult := godhead.effective_mult(patron_id)
			if gh_mult <= 0.0:
				continue   # a guttered or consumed patron grants NO magic, even through their Acolyte
			var patron := registry.get_entity(patron_id)
			var strength := float(eff.get("magnitude", 0.4)) * village.arms_primary_mult(tid) * gh_mult
			for inv: Dictionary in patron.get("invocations", []):
				if int(inv.get("rankRequired", -1)) != rank:
					continue
				for world_eff: Dictionary in inv.get("effects", []):
					var scaled: Dictionary = (world_eff as Dictionary).duplicate(true)
					if scaled.has("magnitude"):
						scaled.magnitude = float(scaled.magnitude) * strength
					if scaled.has("duration"):
						scaled.duration = float(scaled.duration) * strength
					var prev := acting_pid
					if v.companion_pid > 0:
						acting_pid = v.companion_pid
					_apply_effect(scaled)
					acting_pid = prev
				return

## Damage intake for a companion — the enemy-target-selection mirror of
## damage_player. Their own equipped armor turns the worst of it; at 0 HP they
## go down (not die) for downedSeconds, revivable with [E].
func damage_villager(v: DSVillager, amount: float) -> void:
	if not stats.actors.has(v) or village.is_downed(v.tribesman_id):
		return
	amount = maxf(amount - _villager_armor_defense(v), 1.0)
	sfx("grunt", v.position)
	if stats.damage(v, amount):
		var downed_secs := float(village.vtune.get("downedSeconds", 30))
		village.mark_downed(v.tribesman_id, Time.get_unix_time_from_system() + downed_secs)
		v.downed = true
		v.apply_downed_visual()
		message = "%s goes down! [E] them within %ds to revive." % [v.display_name, int(downed_secs)]
		_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

func _villager_armor_defense(v: DSVillager) -> float:
	var armor := str(village.tribesmen.get(v.tribesman_id, {}).get("equipment", {}).get("armor", ""))
	return float(registry.get_entity(armor).get("stats", {}).get("defense", 0.0)) if armor != "" else 0.0

## Downed clock ran out: permadeath. Their gear drops where they fell (a corpse-
## run with feelings — reuses the boss-hoard ground-drop trick), grief begins
## (halved if a memorial stands), and the village hears about it.
func companion_die(v: DSVillager) -> void:
	var dropped := village.road_death(v.tribesman_id, false)   # EA: no biome-band gate yet to judge "reckless" by
	for slot: String in dropped:
		_spawn_equipment_drop(str(dropped[slot]), v.position)
	message = "%s does not wake. The flats keep what a camp cannot carry home." % v.display_name
	stats.unregister(v)
	villagers.erase(v)
	v.queue_free()
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## A corpse-run item on the ground: the same ground-node trick the boss hoard
## uses (_spawn_one_node + node_defs, so it persists/syncs for free), corrected
## to qty 1 — a fallen companion's sword, not a resource stack.
func _spawn_equipment_drop(item_id: String, pos: Vector2) -> void:
	if item_id == "":
		return
	var idx := node_defs.size()
	node_defs.append({"item_id": item_id, "pos": pos, "idx": idx})
	var node := _spawn_one_node(item_id, pos, idx)
	node.set_meta("qty", 1)

func on_villager_needs_help(v: DSVillager) -> void:
	var wardened := false
	for w: DSVillager in all_villagers():
		if w.rescued and not w.is_captive and w.def_class == "class-warden":
			wardened = true
			break
	if wardened:
		message = "%s is in danger — a warden is moving to them." % v.display_name
	else:
		message = "%s fled danger and is running home — clear the flats, or take on a warden." % v.display_name
	_refresh_hud()

## --- BEASTS AT HEEL: AI support + damage/XP plumbing (VILLAGER-AND-GODHEAD-SPEC Part III) ---
func beast_role(creature_id: String) -> String:
	return str(registry.get_entity(creature_id).get("tame", {}).get("behavior", {}).get("role", ""))

func beast_behavior(creature_id: String) -> Dictionary:
	return registry.get_entity(creature_id).get("tame", {}).get("behavior", {})

## +primaryPerLevelPct% (villagers.json — the shared curve's own per-level
## knob) to a beast's primaries per level past 1. Same shape as
## village_system.arms_primary_mult; beast_system itself stays untouched
## (this reads its public `vtune` + `beast_level`, no new sim API needed).
func beast_level_mult(bid: int) -> float:
	var level := beast.beast_level(bid)
	if level <= 1:
		return 1.0
	var pct: float = float(beast.vtune.get("primaryPerLevelPct", 2))
	return 1.0 + pct / 100.0 * float(level - 1)

func beast_instinct_add(bid: int, effect_type: String, base: float = 0.0) -> float:
	var total := base
	for ins: Dictionary in beast.instincts_ignited(bid):
		for eff: Dictionary in ins.get("effects", []):
			if str(eff.get("type", "")) == effect_type:
				total += float(eff.get("magnitude", 0.0))
	return total

func beast_instinct_mult(bid: int, effect_type: String, base: float = 1.0) -> float:
	var total := base
	for ins: Dictionary in beast.instincts_ignited(bid):
		for eff: Dictionary in ins.get("effects", []):
			if str(eff.get("type", "")) == effect_type:
				total *= float(eff.get("magnitude", 1.0))
	return total

func beast_has_instinct(bid: int, effect_type: String) -> bool:
	for ins: Dictionary in beast.instincts_ignited(bid):
		for eff: Dictionary in ins.get("effects", []):
			if str(eff.get("type", "")) == effect_type:
				return true
	return false

func beast_instinct_duration(bid: int, effect_type: String) -> float:
	for ins: Dictionary in beast.instincts_ignited(bid):
		for eff: Dictionary in ins.get("effects", []):
			if str(eff.get("type", "")) == effect_type:
				return float(eff.get("duration", 0.0))
	return 0.0

## Deep Pockets (+2, crab) folded onto the species' base carrySlots.
func beast_carry_capacity(bid: int) -> int:
	var rec: Dictionary = beast.beasts.get(bid, {})
	var base := int(registry.get_entity(str(rec.get("creature_id", ""))).get("tame", {}).get("behavior", {}).get("carrySlots", 0))
	return base + int(beast_instinct_add(bid, "carry-slots-add"))

## Old Barnacle: any Barnacle-lit crab (at heel or waiting) within its radius
## calms every hostile hound nearby, not just its owner's fight — "walking
## calm" is ambient, not a personal buff. 1.0 (no effect) if none stand near.
func old_barnacle_mult(pos: Vector2) -> float:
	for b: DSBeast in beasts:
		if beast_role(b.creature_id) != "porter":
			continue
		if not beast_has_instinct(b.beast_id, "hound-aggro-mult"):
			continue
		if pos.distance_to(b.position) <= 190.0:
			return beast_instinct_mult(b.beast_id, "hound-aggro-mult")
	return 1.0

## Beat a tameable beast below 25% HP: it KNEELS instead of dying, the same
## mercy door a raider gets (surrender pattern), gated on the ATTACKER's WILD
## meeting the creature's tame tier. wild_pid is whose Tally gates it — the
## player for a direct swing, the recruiting/owning player for a companion's
## or beast's own strike. NOT wired into warden_strike (wardens defend the
## whole village, not tied to one player's Tally) — a deliberate scope cut.
func _mercy_kneel_check(target: DSEnemy, dmg: float, wild_pid: int) -> bool:
	if target.surrendered or target.tameable_tier <= 0:
		return false
	var mh := float(registry.get_entity(target.creature_id).get("stats", {}).get("hp", 60))
	if stats.hp(target) - dmg > mh * 0.25:
		return false
	if not beast.can_tame(abilities.score(wild_pid, "virtue-wild"), target.creature_id):
		return false
	stats.actors[target].hp = mh * 0.25
	target.surrender()
	return true

## A hound's own swing: base creature damage x Fangs (if lit) x its own level
## mult (the same "one growth system, three wearers" shape villagers use).
## Deathgrip pins on a hit that doesn't finish the target.
func beast_strike(b: DSBeast, e: DSEnemy) -> void:
	var base_dmg := float(registry.get_entity(b.creature_id).get("stats", {}).get("damage", 5))
	var dmg := base_dmg * beast_instinct_mult(b.beast_id, "damage-mult") * beast_level_mult(b.beast_id)
	_flash_swing(e.position)
	sfx("hit", e.position)
	e.on_hit()
	if _mercy_kneel_check(e, dmg, b.owner_pid):
		return
	if stats.damage(e, dmg):
		_beast_credit_kill(b, e)
	else:
		var pin := beast_instinct_duration(b.beast_id, "pin-on-hit")
		if pin > 0.0:
			e.stun(pin)

## A beast's kill briefly wears its OWNER's identity (loot, ledger) — same
## trick as _companion_credit_kill; _on_enemy_killed already hands out
## killAssist to every beast (and villager) standing close enough to help.
func _beast_credit_kill(b: DSBeast, e: DSEnemy) -> void:
	var prev := acting_pid
	if b.owner_pid > 0:
		acting_pid = b.owner_pid
	_on_enemy_killed(e)
	acting_pid = prev

## Blood-Scent lite: a hostile within growl range (that isn't already obvious
## up close) gets a bearing line — for the OWNER'S peer alone, throttled.
func beast_growl_tick(b: DSBeast) -> void:
	var mult := beast_instinct_mult(b.beast_id, "growl-range-mult")
	var near := _nearest_hostile(b.position, DSBeast.GROWL_BASE_RADIUS * mult)
	if near == null or b.position.distance_to(near.position) < DSBeast.GROWL_VISIBLE_CLOSE:
		return
	b._growl_cd = DSBeast.GROWL_COOLDOWN
	_message_to(b.owner_pid, "%s growls — something %s." % [b.display_name, _bearing_from(b.position, near.position)])

## Send a line to a SPECIFIC player's own screen — the targeted-peer twin of
## the broadcast `message` field (same pattern as _net_push_state).
func _message_to(pid: int, text: String) -> void:
	if net_mode == "server":
		for peer_id: Variant in peers:
			if int(peers[peer_id]) == pid:
				rpc_id(int(peer_id), "cl_message", text)
				return
		return
	message = text
	_refresh_hud()

## Damage intake for a beast — the enemy-target mirror of damage_villager.
## Crabs are IMMORTAL at heel (decision #8: the game's one guaranteed-safe
## love) — a full, unconditional no-op, not just "hard to kill." Hounds go
## down (not die) for downedSeconds, revivable with [E].
func damage_beast(b: DSBeast, amount: float) -> void:
	if beast_role(b.creature_id) == "porter":
		return
	if not stats.actors.has(b) or b.downed:
		return
	sfx("grunt", b.position)
	if stats.damage(b, amount):
		var downed_secs := float(village.vtune.get("downedSeconds", 30))
		b.downed = true
		b.downed_until = Time.get_unix_time_from_system() + downed_secs
		b._refresh_label()
		message = "%s goes down! [E] them within %ds to revive." % [b.display_name, int(downed_secs)]
		_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## The downed clock ran out: permadeath. No gear, no village grief (the
## village never knew it) — a keepsake drops where they fell, an item Ghal's
## altar craves (beast_system.beast_death resolves it from creatures.json).
func beast_die(b: DSBeast) -> void:
	var keepsake := beast.beast_death(b.beast_id)
	if keepsake != "":
		_spawn_equipment_drop(keepsake, b.position)
	message = "%s does not wake. The flats keep what a heel cannot carry home." % b.display_name
	stats.unregister(b)
	beasts.erase(b)
	b.queue_free()
	_refresh_hud()
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

## Build (or rebuild, on load) a DSBeast body for an already-tamed roster id.
## respect_room: at tame-time, bump a second beast to kenneled/waiting if the
## owner's heel slot is already taken; at load-time, trust the saved flags as-is.
func _spawn_beast(bid: int, pos: Vector2, respect_room: bool) -> DSBeast:
	var rec: Dictionary = beast.beasts.get(bid, {})
	var b := DSBeast.new()
	b.host = self
	b.beast_id = bid
	b.creature_id = str(rec.get("creature_id", ""))
	b.display_name = str(rec.get("name", "Beast"))
	b.owner_pid = int(rec.get("owner_pid", 1))
	b.position = pos
	b.at_heel = bool(rec.get("at_heel", false))
	b.kenneled = bool(rec.get("kenneled", false))
	b.mood = str(rec.get("mood", "keen"))
	if respect_room and b.at_heel and beasts.any(func(x: DSBeast) -> bool: return x.owner_pid == b.owner_pid and x.at_heel):
		b.at_heel = false
		b.kenneled = works.count_of("work-kennel") > 0
		rec.at_heel = false
		rec.kenneled = b.kenneled
	add_child(b)
	beasts.append(b)
	stats.register(b, beast.beast_max_hp(bid))
	b._refresh_label()
	return b

## test hook (net_smoke.gd) — see srv_intent's "test_seed_beast" comment.
func _test_seed_beast(pid: int) -> void:
	var id := beast._next_id
	beast._next_id += 1
	beast.beasts[id] = {"name": "Wiretest", "creature_id": "creature-scuttle-crab", "xp": 0.0,
		"owner_pid": pid, "at_heel": true, "kenneled": false, "fed_today": true, "mood": "keen"}
	_spawn_beast(id, avatars.get(pid, player.position), true)

## test hook (net_smoke.gd, M3.c): jump the clock into night and force an
## immediate re-sync — see srv_intent's "test_force_night" case.
func _test_force_night() -> void:
	clock.minute_of_day = 22 * 60
	_night_creatures_active = false
	_sync_night_creatures()

func _enemy_by_nid(nid: int) -> DSEnemy:
	for e in enemies:
		if is_instance_valid(e) and _enemy_nid(e) == nid:
			return e
	return null

func _beast_by_id(bid: int) -> DSBeast:
	for b: DSBeast in beasts:
		if b.beast_id == bid:
			return b
	return null

func _on_sim_day(_day: int) -> void:
	# Godhead (Part II §3): had-worship-today snapshot, taken BEFORE _village_dawn()
	# clears rites_done_today below — this is the day that just ended.
	var rites_yesterday: Dictionary = rites_done_today.duplicate()
	_village_dawn()
	tide_bell_rang_today = false   # the bonus applied for today; tomorrow needs its own ring
	devotion.villager_trickle_day(acting_pid, "god-halor", village.devout_count("god-halor"))
	# Godhead: the devout-villager trickle and the neglect check are WORLD-level,
	# so — unlike the per-player devotion call above (Halor only, pre-existing) —
	# they run for every god, but neglect only for gods someone is actually
	# attuned to (an unworshipped god nobody has met yet isn't "neglected").
	var attuned_anywhere: Dictionary = {}
	for pid: Variant in attuned:
		if pid is int:
			for god_id: String in attuned_for(int(pid)):
				attuned_anywhere[god_id] = true
	for god: Dictionary in registry.all_of("god"):
		if "missing" in god.get("flags", []):
			continue
		godhead.villager_trickle_day(god.id, village.devout_count(god.id))
		if attuned_anywhere.has(god.id):
			godhead.neglect_day(god.id, bool(rites_yesterday.get(god.id, false)))
	# the dawn tithe: each altar's god takes a little of what was laid out, and
	# that consumption is worship — it feeds every player attuned to that god
	# (Vigor) and the god's own Godhead (craved items only — Part II §3) once,
	# world-level, regardless of who's attuned.
	var tithe := sanctum.dawn_tithe()
	for god_id: String in tithe.vigor:
		for pid: Variant in attuned:
			if pid is int and god_id in attuned_for(int(pid)):
				devotion.tithe_day(int(pid), god_id, float(tithe.vigor[god_id]))
		godhead.tithe_day(god_id, int(tithe.craved.get(god_id, 0)))
	for inst_id: Variant in works.placed:
		works.placed[inst_id].in_use = false   # dawn: works rest until tended
	village.end_of_day()
	# a calling may find each player at dawn (they carry at most a few)
	for pid: Variant in stats.actors:
		if pid is int and _active_callings(int(pid)).size() < 3:
			var rng2 := RandomNumberGenerator.new()
			rng2.seed = 777 + clock.day * 13 + int(pid)
			if rng2.randf() < 0.6:
				_draw_calling(int(pid))
	cheat_death_used.clear()
	for pid: Variant in stats.actors:
		if pid is int:
			abilities.earn(int(pid), 2)   # every survived day tempers everyone
	_storm_dawn()
	if not skip_autoload:
		save_game()  # each dawn, the flats remember

## --- the great storm: every 4th day the sea's weather comes home -----------------
func is_storm_day() -> bool:
	return clock.day % 4 == 3

func _storm_dawn() -> void:
	# the Lighthouse-Keeper's Lantern, verse 3: granted to every survivor on the
	# dawn AFTER a great storm (clock.day is already the NEW day here — the
	# storm was clock.day - 1). Per-player, once ever, like the harpoon-verses.
	if clock.day > 0 and (clock.day - 1) % 4 == 3:
		var verse_msg := ""
		for pid: Variant in stats.actors:
			if pid is int and not lantern_verse3_taken.get(pid, false):
				lantern_verse3_taken[pid] = true
				inventory.add(int(pid), "item-lantern-verse", 1)
				verse_msg = "You made it through the great storm. Something in you remembers a keeper's verse now, word for word, like you'd always known it."
		if verse_msg != "":
			message = (message + "\n" + verse_msg) if message != "" else verse_msg
	# yesterday's storm-glass sinks back into the flats
	for node in resource_nodes.duplicate():
		if is_instance_valid(node) and int(node.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			resource_nodes.erase(node)
			node.queue_free()
	# every dawn uncovers a little; storm dawns uncover a lot
	var respawned := 0
	var respawn_cap := 12 if is_storm_day() else 5
	for def: Dictionary in node_defs:
		if respawned >= respawn_cap:
			break
		if int(def.idx) in harvested_indices:
			harvested_indices.erase(int(def.idx))
			_spawn_one_node(str(def.item_id), def.pos, int(def.idx))
			respawned += 1
	# and the flats restock their fauna (the food chain survives your appetite)
	var crabs := 0
	var hounds := 0
	for e in enemies:
		if is_instance_valid(e):
			if e.creature_id == "creature-scuttle-crab":
				crabs += 1
			elif e.creature_id == "creature-salt-hound":
				hounds += 1
	var fauna_rng := RandomNumberGenerator.new()
	fauna_rng.seed = 500 + clock.day
	# B1 fauna restock: bounded to NORTH_H, never WORLD.y (this is Salt Shallows
	# wildlife — Reef Forest fauna are eel-wolf/urchin-back, spawned only by
	# _spawn_south_band/_spawn_enemies' own south pass).
	var center := Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)
	while crabs < 8:
		var crab := DSEnemy.new()
		crab.position = Vector2(fauna_rng.randi_range(2, WORLD.x - 2) * TILE, fauna_rng.randi_range(2, NORTH_H - 2) * TILE)
		crab.setup(self, "creature-scuttle-crab")
		add_child(crab)
		enemies.append(crab)
		crabs += 1
	# the king is gone: scavengers fill a throne faster than grief does
	# (Shellback specifically — the Salt Shallows' own apex, not any boss anywhere)
	var hound_cap := 8 if bosses_dead.get("creature-old-shellback", false) else 6
	while hounds < hound_cap:
		var hound := DSEnemy.new()
		var pos := center
		while pos.distance_to(center) < 350.0:
			pos = Vector2(fauna_rng.randi_range(2, WORLD.x - 2) * TILE, fauna_rng.randi_range(2, NORTH_H - 2) * TILE)
		hound.position = pos
		hound.setup(self, "creature-salt-hound")
		add_child(hound)
		enemies.append(hound)
		hounds += 1
	if not is_storm_day():
		return
	# and the sky leaves gifts: storm-glass, today only
	var rng := RandomNumberGenerator.new()
	rng.seed = 100 + clock.day
	for i in 3:
		var pos := Vector2(rng.randi_range(3, WORLD.x - 3) * TILE, rng.randi_range(3, NORTH_H - 3) * TILE)
		_spawn_one_node("item-storm-glass", pos, STORM_GLASS_IDX_BASE + i)
	# ...and the storm washes in the desperate: raiders replenish to cap on
	# storm days ONLY (Jeff 2026-07-18: the original 3 world-gen raiders were
	# the entire lifetime supply — once subdued or converted, the Taken system
	# went dark for good). Deterministic per-day rng; spawns hug the world's
	# edge so a storm never drops a raider on the village.
	var raiders := 0
	for e in enemies:
		if is_instance_valid(e) and e.creature_id == "creature-raider":
			raiders += 1
	var storm_raiders := 0
	var rrng := RandomNumberGenerator.new()
	rrng.seed = 9000 + clock.day
	while raiders < RAIDER_CAP:
		var raider := DSEnemy.new()
		var edge := rrng.randi_range(0, 3)
		var rp := Vector2(
			[3, WORLD.x - 3, rrng.randi_range(3, WORLD.x - 3), rrng.randi_range(3, WORLD.x - 3)][edge] * TILE,
			[rrng.randi_range(3, NORTH_H - 3), rrng.randi_range(3, NORTH_H - 3), 3, NORTH_H - 3][edge] * TILE)
		raider.position = rp
		raider.setup(self, "creature-raider")
		add_child(raider)
		enemies.append(raider)
		raiders += 1
		storm_raiders += 1
	message = "THE GREAT STORM. The seabed shifts — old salvage uncovered, and storm-glass smokes on the flats.\nGather it before the sky takes it back. Maren is EVERYWHERE today: her magic costs half."
	if storm_raiders > 0:
		message += "\nAnd the storm drove people in ahead of it — desperate figures at the world's edge, armed and hungry.\nBeat one to its knees and [E] binds them for the yoke: the village can use hands, however they arrive."

func _spawn_enemies() -> void:
	if net_mode == "client":
		return  # the server's beasts arrive as mirrors
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	# B1 (Salt Shallows) enemies: bounded to NORTH_H, never WORLD.y — this seed
	# is the smoke suite's proof that the north half never moves.
	var center := Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)
	for i in 6:
		var hound := DSEnemy.new()
		var pos := center
		while pos.distance_to(center) < 350.0:  # never spawn on the player's doorstep
			pos = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, NORTH_H - 2) * TILE)
		hound.position = pos
		hound.setup(self, "creature-salt-hound")
		add_child(hound)
		enemies.append(hound)
	for i in 8:  # scuttle-crabs: mostly harmless, excellent soup
		var crab := DSEnemy.new()
		crab.position = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(2, NORTH_H - 2) * TILE)
		crab.setup(self, "creature-scuttle-crab")
		add_child(crab)
		enemies.append(crab)
	for i in 3:  # flats raiders — beat them down and they surrender; subdue for the yoke
		var raider := DSEnemy.new()
		var rp := center
		while rp.distance_to(center) < 300.0:
			rp = Vector2(rng.randi_range(3, WORLD.x - 3) * TILE, rng.randi_range(3, NORTH_H - 3) * TILE)
		raider.position = rp
		raider.setup(self, "creature-raider")
		add_child(raider)
		enemies.append(raider)
	# Old Shellback guards the northwest wreck-ring. The first name you learn to fear.
	var boss := DSEnemy.new()
	boss.position = BOSS_RING_POS
	boss.setup(self, "creature-old-shellback")
	boss.add_child(_world_label("Old Shellback", Vector2(0, 22)))
	add_child(boss)
	enemies.append(boss)
	# --- REEF-FOREST-SPEC §1/§4: the south-band enemy pass. Its OWN seeded rng
	# (SOUTH_ENEMY_SEED) — never touches the north generator (seed 23) or its
	# positions. Eel-wolves (pack-hunter) + urchin-backs (ambient-armored),
	# roaming only south of the scarp.
	var srng := RandomNumberGenerator.new()
	srng.seed = SOUTH_ENEMY_SEED
	for i in SOUTH_EEL_WOLF_COUNT:
		var wolf := DSEnemy.new()
		wolf.position = Vector2(srng.randi_range(2, WORLD.x - 2) * TILE, srng.randi_range(NORTH_H + 2, WORLD.y - 2) * TILE)
		wolf.setup(self, "creature-eel-wolf")
		add_child(wolf)
		enemies.append(wolf)
	for i in SOUTH_URCHIN_BACK_COUNT:
		var urchin := DSEnemy.new()
		urchin.position = Vector2(srng.randi_range(2, WORLD.x - 2) * TILE, srng.randi_range(NORTH_H + 2, WORLD.y - 2) * TILE)
		urchin.setup(self, "creature-urchin-back")
		add_child(urchin)
		enemies.append(urchin)
	# The Anglermother: a FIXED reef arena, standing from world-gen regardless
	# of the hour (REEF-FOREST-SPEC §4/§6, Q17) — dormant-and-unattackable by
	# day, not despawned (enemy.gd is_attackable/_physics_process), so her ring
	# is always there to name (the keystone anchor, the arena-darkness override).
	var anglermother := DSEnemy.new()
	anglermother.position = ANGLERMOTHER_RING_POS
	anglermother.setup(self, "creature-anglermother")
	anglermother.add_child(_world_label("The Anglermother", Vector2(0, 26)))
	add_child(anglermother)
	enemies.append(anglermother)

## --- the dark: nightOnly creatures (REEF-FOREST-SPEC §2/§4) ------------------------
## Which non-boss creatures spawn at dusk, and how many of each. Data-driven
## off creature.nightOnly (any future B3 nightOnly creature is included for
## free, at a sane default count); boss nightOnly creatures (the Anglermother)
## are handled separately — dormant, never despawned (see enemy.gd, _spawn_enemies).
func _night_creature_spawn_list() -> Dictionary:
	var out := {}
	for c: Dictionary in registry.all_of("creature"):
		if bool(c.get("nightOnly", false)) and str(c.get("archetype", "")) != "boss":
			out[str(c.id)] = int(NIGHT_CREATURE_COUNTS.get(str(c.id), NIGHT_CREATURE_DEFAULT_COUNT))
	return out

## Host-authoritative: called once per minute tick (_on_sim_minute). A no-op
## unless the day/night state actually FLIPPED since the last check — so it
## fires exactly once at dusk (spawn) and once at dawn (despawn), never every
## minute in between.
func _sync_night_creatures() -> void:
	if net_mode == "client":
		return
	var want_night := clock.is_night()
	if want_night == _night_creatures_active:
		return
	_night_creatures_active = want_night
	if want_night:
		_spawn_night_creatures()
	else:
		_despawn_night_creatures()

func _spawn_night_creatures() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = NIGHT_CREATURE_SEED + clock.day   # a fresh layout each dusk — these are ephemeral, not the deterministic day-node layout
	var spawn_list := _night_creature_spawn_list()
	for creature_id: String in spawn_list:
		for i in int(spawn_list[creature_id]):
			var e := DSEnemy.new()
			e.position = Vector2(rng.randi_range(2, WORLD.x - 2) * TILE, rng.randi_range(NORTH_H + 2, WORLD.y - 2) * TILE)
			e.setup(self, creature_id)
			add_child(e)
			enemies.append(e)
			night_creatures.append(e)
			if e.is_lure:
				_spawn_angler_lure(e)

func _despawn_night_creatures() -> void:
	for e in night_creatures.duplicate():
		if is_instance_valid(e):
			stats.unregister(e)
			enemies.erase(e)
			e.queue_free()
	night_creatures.clear()
	for l in angler_lures.duplicate():
		if is_instance_valid(l):
			l.queue_free()
	angler_lures.clear()

## --- angler-lights: the stalker's lure (REEF-FOREST-SPEC §4/B) ---------------------
## A false glow near the stalker that reads like a light source at a
## distance — client visual + a HUD tell (_direction_hints), pathing bait
## rather than a creature: no AI, no collision, no HP. The Lantern reveals it
## within its radius (_lure_is_revealed) — "the dark biomes respect it."
func _spawn_angler_lure(stalker: DSEnemy) -> void:
	var lure := Node2D.new()
	lure.position = stalker.position + LURE_OFFSET
	lure.set_meta("stalker", stalker)
	lure.set_meta("revealed", false)
	var glow := SpriteKit.sprite("lure_glow", Vector2(12, 12), Color(1.0, 0.86, 0.55))
	glow.modulate = Color(1.3, 1.18, 0.75)
	lure.add_child(glow)
	lure.set_meta("glow", glow)
	var label := _world_label("a light in the dark", Vector2(0, -18))
	lure.add_child(label)
	lure.set_meta("label", label)
	add_child(lure)
	angler_lures.append(lure)

## Follows its stalker + refreshes the reveal state — called each minute tick
## (non-server), and directly by tests for deterministic checks without
## waiting on real time.
func _update_angler_lures() -> void:
	for lure in angler_lures:
		if not is_instance_valid(lure):
			continue
		var stalker: DSEnemy = lure.get_meta("stalker", null)
		if stalker != null and is_instance_valid(stalker):
			lure.position = stalker.position + LURE_OFFSET
		var revealed := _lure_is_revealed(lure)
		lure.set_meta("revealed", revealed)
		var label: Label = lure.get_meta("label", null)
		if label != null:
			label.text = "FALSE LIGHT — a lure, not a hearth" if revealed else "a light in the dark"
		var glow: Node2D = lure.get_meta("glow", null)
		if glow != null:
			glow.modulate = Color(0.55, 0.85, 1.0) if revealed else Color(1.3, 1.18, 0.75)

## Within the Lighthouse-Keeper's Lantern's own night-light-radius (the same
## magnitude _update_lantern_glow sizes the visual light with), at night, a
## lure is marked false — the trinket's promised payoff, made legible both as
## a distinct tint (the glow color swap above) and in text (the label, and
## _direction_hints below) so it's testable headlessly.
func _lure_is_revealed(lure: Node2D) -> bool:
	if player == null or not clock.is_night():
		return false
	if equipped_item(my_pid, "trinket") != "item-lighthouse-keepers-lantern":
		return false
	var mag := 90.0
	for eff: Dictionary in registry.get_entity("item-lighthouse-keepers-lantern").get("effects", []):
		if str(eff.get("type", "")) == "night-light-radius":
			mag = float(eff.get("magnitude", 90.0))
	return player.position.distance_to(lure.position) <= mag

func _nearest_angler_lure(from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for lure in angler_lures:
		if is_instance_valid(lure):
			var d := from.distance_to(lure.position)
			if d < best_d:
				best_d = d
				best = lure
	return best

## --- day/night + HUD ---------------------------------------------------------------
const TIDE_BELL_RING_MINUTES := [6 * 60, 18 * 60]   # 06:00 and 18:00

## Neris's Tide-Bell: rings itself (no tending needed), counts as in-use on
## days it rang (favor trickle), and marks the day for _village_dawn's output
## bump. minute_of_day is an int (SimClock), so no float/int membership gotcha.
func _tick_tide_bell(minute: int) -> void:
	if minute not in TIDE_BELL_RING_MINUTES:
		return
	var rang := false
	for inst_id: Variant in works.placed:
		if str(works.placed[inst_id].work_id) == "work-tide-bell":
			works.set_in_use(int(inst_id), true)
			rang = true
	if rang:
		tide_bell_rang_today = true
		sfx("rite")   # an existing god-bell asset stands in until a dedicated one lands

func _on_sim_minute(_m: int) -> void:
	_minutes_since_hour += 1
	if _minutes_since_hour >= 60:
		_minutes_since_hour = 0
		works.favor_hour()
	_tick_tide_bell(clock.minute_of_day)
	_sync_night_creatures()
	var tint := _tint_for_minute(clock.minute_of_day, player.position.y if player != null else 0.0, player.position.x if player != null else INF)
	if is_storm_day():
		tint = tint * Color(0.72, 0.76, 0.86)   # storm-gray over everything
		if clock.minute_of_day % 47 == 0:
			storm_flash = 0.65                   # lightning somewhere over the flats
			sfx("thunder")
	daynight.color = tint
	if net_mode != "server" and sound != null:
		sound.ambience("amb_storm" if is_storm_day() else ("amb_night" if clock.is_night() else "amb_day"))
	if net_mode == "server" and clock.minute_of_day % 5 == 0:
		rpc("cl_world_sync", _world_sync())
	if net_mode != "server":
		_update_lantern_glow()
		_update_angler_lures()
	_refresh_hud()

var _lantern_light: PointLight2D = null
static var _lantern_glow_tex: GradientTexture2D = null

## The Lighthouse-Keeper's Lantern: a personal light radius at night, client
## visual only — reuses the daynight-tint idea (nothing here is sim state; a
## server never runs it, and a client that isn't wearing the trinket at night
## just never spawns the node). item.effects "night-light-radius" sizes it.
func _update_lantern_glow() -> void:
	if player == null:
		return
	var carrying := equipped_item(my_pid, "trinket") == "item-lighthouse-keepers-lantern"
	var active := carrying and clock.is_night()
	if active and _lantern_light == null:
		_lantern_light = PointLight2D.new()
		if _lantern_glow_tex == null:
			var g := Gradient.new()
			g.set_color(0, Color(1, 0.92, 0.75, 1))
			g.set_color(1, Color(1, 0.92, 0.75, 0))
			var tex := GradientTexture2D.new()
			tex.gradient = g
			tex.fill = GradientTexture2D.FILL_RADIAL
			tex.fill_from = Vector2(0.5, 0.5)
			tex.fill_to = Vector2(1.0, 0.5)
			tex.width = 128
			tex.height = 128
			_lantern_glow_tex = tex
		_lantern_light.texture = _lantern_glow_tex
		var mag := 90.0
		for eff: Dictionary in registry.get_entity("item-lighthouse-keepers-lantern").get("effects", []):
			if str(eff.get("type", "")) == "night-light-radius":
				mag = float(eff.get("magnitude", 90.0))
		_lantern_light.texture_scale = mag / 64.0
		_lantern_light.energy = 1.1
		player.add_child(_lantern_light)
	elif not active and _lantern_light != null:
		_lantern_light.queue_free()
		_lantern_light = null

## Gradual light: night -> warm dawn -> blinding day -> gold dusk -> night.
## A pure function of (minute, y, x) — no sim state, client-visual only. `x`
## is optional (INF skips the arena check below) so every pre-M3.c call site
## and test keeps working unchanged.
## REEF-FOREST-SPEC §2: south of the scarp the canopy adds a THIRD band —
## reef "daytime" reads like a Salt Shallows dusk, reef night goes near-black.
func _tint_for_minute(m: int, y: float = 0.0, x: float = INF) -> Color:
	const NIGHT := Color(0.42, 0.46, 0.62)
	const DAWN := Color(0.95, 0.82, 0.72)
	const DAY := Color(1, 1, 1)
	const DUSK := Color(1.0, 0.85, 0.62)
	var h := m / 60.0
	var north: Color
	if h < 4.0:
		north = NIGHT
	elif h < 5.0:
		north = NIGHT.lerp(DAWN, h - 4.0)
	elif h < 7.0:
		north = DAWN.lerp(DAY, (h - 5.0) / 2.0)
	elif h < 18.0:
		north = DAY
	elif h < 20.0:
		north = DAY.lerp(DUSK, (h - 18.0) / 2.0)
	elif h < 21.5:
		north = DUSK.lerp(NIGHT, (h - 20.0) / 1.5)
	else:
		north = NIGHT
	if y <= float(SCARP_Y):
		return north
	# permanent twilight under the canopy: cap brightness at "B1 dusk" (never
	# brighter, whatever the hour), then a cold, dim canopy-shadow multiply —
	# STYLE-BIBLE's cold-palette bias for the band, and near-black at night.
	const CANOPY_MULT := Color(0.5, 0.48, 0.55)
	var capped := Color(minf(north.r, DUSK.r), minf(north.g, DUSK.g), minf(north.b, DUSK.b), north.a)
	var reef := capped * CANOPY_MULT
	# REEF-FOREST-SPEC §6: the Anglermother's arena — her lure is the ONLY
	# light, so at night (and only at night; by day she's dormant and the
	# reef's ordinary twilight is fine to walk through) a hard-dark override
	# inside her ring, on top of the normal reef dusk-cap above.
	if x != INF and SimClock.is_night_at(m) and Vector2(x, y).distance_to(ANGLERMOTHER_RING_POS) <= ANGLERMOTHER_ARENA_RADIUS:
		const ARENA_DARK_MULT := Color(0.18, 0.16, 0.22)
		return reef * ARENA_DARK_MULT
	return reef

## A framed, dimmed modal window on the UI layer — one shared frame so every
## menu reads as the same object: the flats recede behind it, a bronze-rimmed
## sheet of keepsake paper carries a title, a rule, the body, and a footer of
## keys. Returns the pieces; starts hidden. Register it under `name` in `modals`.
func _make_modal(layer: CanvasLayer, name: String, sizev: Vector2, title_text: String) -> Dictionary:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP   # the world doesn't get clicks while a modal is up
	root.visible = false
	layer.add_child(root)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.06, 0.05, 0.04, 0.55)       # the flats go to dusk behind the sheet
	root.add_child(dim)
	var panel := Panel.new()
	panel.size = sizev
	panel.position = ((SCREEN - sizev) / 2.0).round()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.949, 0.937, 0.910, 0.99)  # keepsake-paper cream
	sb.border_color = Color("8a6a3c")               # a bronze rim, salvage-worn
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 14
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)
	var title := Label.new()
	title.text = title_text
	title.position = Vector2(24, 16)
	title.add_theme_color_override("font_color", Color("6a4a24"))
	title.add_theme_font_size_override("font_size", 20)
	panel.add_child(title)
	var rule := ColorRect.new()
	rule.position = Vector2(24, 48)
	rule.size = Vector2(sizev.x - 48, 2)
	rule.color = Color("c9a648")                    # a votive-gold underline
	panel.add_child(rule)
	var body := Label.new()
	body.position = Vector2(24, 62)
	body.custom_minimum_size = Vector2(sizev.x - 48, 0)
	body.add_theme_color_override("font_color", Color("3b3428"))
	body.add_theme_font_size_override("font_size", 13)
	panel.add_child(body)
	var footer := Label.new()
	footer.position = Vector2(24, sizev.y - 32)
	footer.custom_minimum_size = Vector2(sizev.x - 48, 0)
	footer.add_theme_color_override("font_color", Color("8a7a5c"))
	footer.add_theme_font_size_override("font_size", 11)
	panel.add_child(footer)
	var m := {"root": root, "panel": panel, "title": title, "body": body, "footer": footer}
	modals[name] = m
	return m

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_color", Color("3b3428"))
	hud.add_theme_font_size_override("font_size", 14)
	layer.add_child(hud)
	var hp_back := ColorRect.new()
	hp_back.position = Vector2(12, 140)
	hp_back.size = Vector2(160, 10)
	hp_back.color = Color("4a3021")
	layer.add_child(hp_back)
	hp_bar = ColorRect.new()
	hp_bar.position = Vector2(13, 141)
	hp_bar.size = Vector2(158, 8)
	hp_bar.color = Color("b0483c")
	layer.add_child(hp_bar)
	var st_back := ColorRect.new()
	st_back.position = Vector2(12, 154)
	st_back.size = Vector2(160, 10)
	st_back.color = Color("4a3021")
	layer.add_child(st_back)
	stamina_bar = ColorRect.new()
	stamina_bar.position = Vector2(13, 155)
	stamina_bar.size = Vector2(158, 8)
	stamina_bar.color = Color("c9a648")
	layer.add_child(stamina_bar)
	var vigor_back := ColorRect.new()
	vigor_back.position = Vector2(12, 168)
	vigor_back.size = Vector2(160, 10)
	vigor_back.color = Color("4a3021")
	layer.add_child(vigor_back)
	vigor_bar = ColorRect.new()
	vigor_bar.position = Vector2(13, 169)
	vigor_bar.size = Vector2(0, 8)
	vigor_bar.color = Color("5da8a0")   # Halor's votive flame, placeholder-shaped
	layer.add_child(vigor_bar)
	# Godhead (Part II §2, the UI law: "the numbers are always on screen") —
	# a compact line next to each god's own vigor bar, e.g. "HALOR — godhead
	# 10% (cap 40%)". Only the two gods with HUD bars get one today (the same
	# pre-existing limitation as vigor_bar/maren_bar themselves).
	halor_godhead_label = Label.new()
	halor_godhead_label.position = Vector2(178, 167)
	halor_godhead_label.add_theme_color_override("font_color", Color("3b3428"))
	halor_godhead_label.add_theme_font_size_override("font_size", 11)
	layer.add_child(halor_godhead_label)
	var maren_back := ColorRect.new()
	maren_back.position = Vector2(12, 182)
	maren_back.size = Vector2(160, 10)
	maren_back.color = Color("4a3021")
	layer.add_child(maren_back)
	maren_bar = ColorRect.new()
	maren_bar.position = Vector2(13, 183)
	maren_bar.size = Vector2(0, 8)
	maren_bar.color = Color("aebfc9")   # Maren's storm-light
	layer.add_child(maren_bar)
	maren_godhead_label = Label.new()
	maren_godhead_label.position = Vector2(178, 181)
	maren_godhead_label.add_theme_color_override("font_color", Color("3b3428"))
	maren_godhead_label.add_theme_font_size_override("font_size", 11)
	layer.add_child(maren_godhead_label)
	boss_name = Label.new()
	boss_name.position = Vector2(440, 640)
	boss_name.custom_minimum_size = Vector2(400, 0)
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_name.add_theme_color_override("font_color", Color("3b3428"))
	boss_name.add_theme_font_size_override("font_size", 16)
	boss_name.visible = false
	layer.add_child(boss_name)
	var boss_back := ColorRect.new()
	boss_back.position = Vector2(440, 664)
	boss_back.size = Vector2(400, 12)
	boss_back.color = Color("4a3021")
	boss_back.visible = false
	layer.add_child(boss_back)
	boss_bar = ColorRect.new()
	boss_bar.position = Vector2(442, 666)
	boss_bar.size = Vector2(396, 8)
	boss_bar.color = Color("b0483c")
	boss_bar.visible = false
	layer.add_child(boss_bar)
	boss_bar.set_meta("back", boss_back)
	# Every menu is the same framed, dimmed modal — built once, filled on open.
	var m_sheet := _make_modal(layer, "sheet", Vector2(840, 672), "THE TALLY")   # the fullest screen — all six virtues + talents
	sheet_label = m_sheet.body
	sheet_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sheet_label.add_theme_font_size_override("font_size", 12)

	var m_menu := _make_modal(layer, "menu", Vector2(580, 640), "CRAFT")
	menu_label = m_menu.body
	menu_title = m_menu.title

	var m_doll := _make_modal(layer, "doll", Vector2(660, 520), "THE PACK & THE DOLL")
	doll_label = m_doll.body
	doll_label.custom_minimum_size = Vector2(400, 0)   # leave the right third for the doll
	doll_sprite = SpriteKit.sprite("survivor", Vector2(22, 30), Color("c8865a"))
	doll_sprite.position = Vector2(540, 300)
	doll_sprite.scale = Vector2(4.5, 4.5)
	(m_doll.panel as Panel).add_child(doll_sprite)

	var m_village := _make_modal(layer, "village", Vector2(700, 560), "THE VILLAGE")
	village_panel = m_village.body
	village_panel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # defensive: a stray long line wraps instead of overflowing the panel

	var m_journal := _make_modal(layer, "journal", Vector2(720, 600), "THE JOURNAL")
	journal = m_journal.body
	journal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var m_offertory := _make_modal(layer, "offertory", Vector2(660, 560), "THE OFFERTORY")
	offertory_label = m_offertory.body
	offertory_title = m_offertory.title

	_make_modal(layer, "drill", Vector2(640, 520), "THE DRILL-YARD")
	_make_modal(layer, "rename", Vector2(480, 380), "NAME THE BEAST")   # M3.b, kennel rename modal ([M])
	_make_modal(layer, "keystone", Vector2(560, 460), "THE KEYSTONE")   # M3.c, boss-ring kneel-prompt ([E])

func _refresh_bars() -> void:
	if hp_bar == null:
		return
	hp_bar.size.x = 158.0 * stats.hp(acting_pid) / maxf(stats.max_hp(acting_pid), 1.0)
	stamina_bar.size.x = 158.0 * stats.stamina(acting_pid) / maxf(stats.max_stamina(acting_pid), 1.0)
	if "god-halor" in attuned_for(my_pid):
		var s: Dictionary = devotion.state.get(acting_pid, {}).get("god-halor", {})
		vigor_bar.size.x = 158.0 * float(s.get("vigor", 0)) / devotion.max_vigor("god-halor")
		if halor_godhead_label != null:
			halor_godhead_label.text = "%s — godhead %d%% (cap %d%%)" % [str(registry.get_entity("god-halor").name).to_upper(), int(godhead.godhead("god-halor")), int(godhead.cap())]
	else:
		vigor_bar.size.x = 0.0
		if halor_godhead_label != null:
			halor_godhead_label.text = ""
	if maren_bar != null:
		if "god-maren" in attuned_for(my_pid):
			var m: Dictionary = devotion.state.get(acting_pid, {}).get("god-maren", {})
			maren_bar.size.x = 158.0 * float(m.get("vigor", 0)) / devotion.max_vigor("god-maren")
			if maren_godhead_label != null:
				maren_godhead_label.text = "%s — godhead %d%% (cap %d%%)" % [str(registry.get_entity("god-maren").name).to_upper(), int(godhead.godhead("god-maren")), int(godhead.cap())]
		else:
			maren_bar.size.x = 0.0
			if maren_godhead_label != null:
				maren_godhead_label.text = ""

func _refresh_hud() -> void:
	if hud == null:
		return
	var inv := ""
	for item_id: String in inventory._inv(acting_pid):
		inv += "%s ×%d   " % [str(registry.get_entity(item_id).get("name", item_id)), inventory.count(acting_pid, item_id)]
	var fed: int = (stats.actors.get(acting_pid, {}).get("foods", []) as Array).size()
	var weather := ""
	if is_storm_day():
		weather = "  — THE GREAT STORM"
	elif "god-maren" in attuned_for(my_pid) and (clock.day + 1) % 4 == 3:
		weather = "  — Maren whispers: storm tomorrow"
	hud.text = "Day %d, %02d:%02d%s%s%s%s\n%s\n[WASD] move  [E] interact  [C] craft  [B] build  [F] eat  [I] pack  [V] village  [J] journal  [T] tally  [SPACE] attack  [drag] move  [R-click] turn  [Shift+R-click] reclaim%s\n%s" % [
		clock.day + 1, clock.minute_of_day / 60, clock.minute_of_day % 60, weather,
		"  — night. NIGHT BELONGS TO THE HOUNDS." if clock.is_night() else "",
		"  |  fed ×%d" % fed if fed > 0 else "", _direction_hints(),
		inv if inv != "" else "(empty hands)",
		("  [Q] Pillar of Salt" if "god-halor" in attuned_for(my_pid) else "") + ("  [R] Call the Squall" if "god-maren" in attuned_for(my_pid) else "") \
			+ ("  [Z] Slack Tide  [N] Returning Wave" if "god-neris" in attuned_for(my_pid) else "") \
			+ ("  [H] Rip-Current  [K] Undertow" if "god-vessa" in attuned_for(my_pid) else "") \
			+ ("  [U] Shepherd's Voice  [L] Blood-Scent" if "god-ghal" in attuned_for(my_pid) else ""), message]

## Where the unfinished business is: unvisited shrines, the stranded woman.
func _direction_hints() -> String:
	var bits: Array[String] = []
	for s in shrines:
		if s.get_meta("god_id") not in attuned_for(my_pid):
			bits.append("a pale shrine %s" % _bearing(s.position))
	if survivor != null and not survivor.rescued:
		bits.append("someone stranded %s" % _bearing(survivor.position))
	if not scarp_crossed:   # HUD bearing when unvisited, same grammar as shrines (REEF-FOREST-SPEC §1)
		bits.append("a broken stair %s" % _bearing(STAIR_OF_HULLS_POS))
	var raider := _nearest_raider()
	if raider != null:
		bits.append("a raider prowls %s" % _bearing(raider.position))
	# Ghal's Blood-Scent (M3.b): while it's lit, the nearest hostile of any
	# kind gets a bearing line — same grammar as the shrine/raider lines above.
	if blood_scent_frames > 0:
		var scented := _nearest_hostile(player.position, INF)
		if scented != null:
			bits.append("blood-scent: %s %s" % [str(registry.get_entity(scented.creature_id).name), _bearing(scented.position)])
	var verses := inventory.count(acting_pid, "item-harpoon-verse")
	if verses > 0 and verses < 3:
		bits.append("the harpoon-song: %d/3 verses" % verses)
	# angler-lights (REEF-FOREST-SPEC §4/B): the HUD tell for a lure — it
	# reads as an ordinary light until the Lantern reveals it (the label
	# text on the lure itself carries the reveal too, for a world-space tell).
	var lure := _nearest_angler_lure(player.position)
	if lure != null:
		var revealed := bool(lure.get_meta("revealed", false))
		bits.append(("a lure exposed for what it is %s" % _bearing(lure.position)) if revealed else ("a light glimmers %s" % _bearing(lure.position)))
	var calling_bearing := _calling_bearing_hint()
	if calling_bearing != "":
		bits.append(calling_bearing)
	return "  |  " + ";  ".join(bits) if bits.size() > 0 else ""

## Only the FIRST active calling, and only when its current step is an
## unmet goto/escort — a quiet pull toward the next real place, same grammar
## as the shrine hints above.
func _calling_bearing_hint() -> String:
	var active := _active_callings(my_pid)
	if active.is_empty():
		return ""
	var entry: Dictionary = active[0]
	var calling := registry.get_entity(str(entry.id))
	var step := _calling_step(calling, str(entry.step))
	var t := str(step.get("type", ""))
	if t != "goto" and t != "escort":
		return ""
	var params: Dictionary = step.get("params", {})
	if params.is_empty():
		return ""
	var target := _calling_anchor_pos(str(params.get("near", "")))
	if target == Vector2.INF or _step_met(my_pid, entry, step).met:
		return ""
	return "your calling pulls %s" % _bearing(target)

## Nearest un-subdued raider — the convertible kind — so the HUD can point you
## to one to beat down and yoke. Ignores raiders already on their knees.
func _nearest_raider() -> DSEnemy:
	var best: DSEnemy = null
	var best_d := INF
	for e in enemies:
		if is_instance_valid(e) and e.creature_id == "creature-raider" and not e.surrendered:
			var d := player.position.distance_to(e.position)
			if d < best_d:
				best_d = d
				best = e
	return best

func _bearing(to: Vector2) -> String:
	return _bearing_from(player.position, to)

## The same compass math, off an arbitrary origin — a beast's growl points
## from ITS position, not the local player's (main.gd's own message channel
## is per-recipient-peer already; see _message_to).
func _bearing_from(from: Vector2, to: Vector2) -> String:
	var d := to - from
	const DIRS := ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
	var idx := wrapi(roundi(d.angle() / (PI / 4.0)), 0, 8)
	return "%s, %d paces" % [DIRS[idx], int(d.length() / 32.0)]

## --- helpers ------------------------------------------------------------------------
static func _setup_input() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"interact": [KEY_E], "craft": [KEY_C], "build": [KEY_B], "eat": [KEY_F],
		"attack": [KEY_SPACE], "cast": [KEY_Q], "cast_2": [KEY_R], "consume": [KEY_X],
		"save": [KEY_F5], "sheet": [KEY_T], "inventory": [KEY_I], "village": [KEY_V], "give_food": [KEY_G], "journal": [KEY_J],
		# Neris's two invocations (CRAFT-AND-BUILD-SPEC M2.75): Z and N are the
		# nearest unclaimed keys to the existing Q/R cast pattern — checked
		# against every bound action above (T/C/B/V/J/I/F/G/Q/R/X/SPACE/F5 taken).
		"cast_3": [KEY_Z], "cast_4": [KEY_N],
		# Vessa's + Ghal's invocations (M3.b, REEF-FOREST-SPEC §5): H/K/U/L are
		# the next unclaimed letters — checked against every bound action above
		# PLUS Z/N (Neris). M is the rename-modal key (a menu key at the kennel,
		# per the spec's own "or a menu key" alternative — [E] on a kenneled
		# beast already means "call to heel", so renaming gets its own key
		# rather than overloading it).
		"cast_5": [KEY_H], "cast_6": [KEY_K], "cast_7": [KEY_U], "cast_8": [KEY_L],
		"rename_beast": [KEY_M],
		# Part III §2, the Shepherd's Way offered: [O] for "offer" — checked
		# against every bound action above (WASD/E/SPACE/Q/R/Z/N/H/K/U/L/M/C/B/
		# V/J/I/T/F/G/X/F5), the next free, mnemonic key.
		"offer_bait": [KEY_O],
	}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for keycode: Key in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)

## Screenshot/test harness helper: raise the founding hearth (the village must
## exist before anything else can be built) so a harness can fill it in.
func _harness_found_village() -> void:
	inventory.add(acting_pid, "item-salt", 8)
	inventory.add(acting_pid, "item-wreck-timber", 6)
	intent_build("work-hearth")

func _screenshot_and_quit() -> void:
	await get_tree().create_timer(1.2).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://screenshot.png")
	print("screenshot saved: ", ProjectSettings.globalize_path("user://screenshot.png"))
	get_tree().quit(0)


## ===========================================================================
## NET — host-authoritative co-op (ARCHITECTURE.md §6).
## Server: runs the whole sim headless; clients send INTENTS and positions,
## receive their per-player state + light world syncs. The world layout is
## deterministic (seeded), so sync is deltas, not geometry.
## ===========================================================================
var _net_connect_addr := ""
var _username := ""

func attuned_for(pid: int) -> Array:
	if not attuned.has(pid):
		attuned[pid] = []
	return attuned[pid]

## Where the acting player stands (server: last reported avatar position).
func acting_pos() -> Vector2:
	if net_mode == "server":
		return avatars.get(acting_pid, Vector2.INF)
	return player.position

## Nearest player OR road companion to a point — what enemies hunt. Returns
## {pos, pid, companion}; companion is a DSVillager when a recruit out-draws
## the player's own threat (VILLAGER-AND-GODHEAD-SPEC Part I §4).
func nearest_threat(from: Vector2) -> Dictionary:
	var best: Dictionary
	var best_d: float
	if net_mode != "server":
		best = {"pos": player.position, "pid": my_pid, "companion": null}
		best_d = from.distance_to(player.position)
	else:
		best_d = INF
		best = {"pos": Vector2.INF, "pid": -1, "companion": null}
		for pid: Variant in avatars:
			var d: float = from.distance_to(avatars[pid])
			if d < best_d:
				best_d = d
				best = {"pos": avatars[pid], "pid": int(pid), "companion": null}
	for v: DSVillager in all_villagers():
		if v.on_road and v.rescued and not v.downed:
			var d2 := from.distance_to(v.position)
			if d2 < best_d:
				best_d = d2
				best = {"pos": v.position, "pid": -1, "companion": v}
	return best

func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var port := NET_PORT
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	peer.create_server(port, 16)
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_disconnected.connect(_on_peer_left)
	player.visible = false   # the server is nobody
	print("DRIED SEA server v%s on udp/%d - world day %d" % [GAME_VERSION, port, clock.day + 1])

func _start_client() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			_username = a.trim_prefix("--name=")
	if _username == "":
		_username = OS.get_environment("USERNAME")
	if _username == "":
		_username = "drifter"
	var parts := _net_connect_addr.split(":")
	var peer := ENetMultiplayerPeer.new()
	peer.create_client(parts[0], int(parts[1]) if parts.size() > 1 else NET_PORT)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func() -> void:
		rpc_id(1, "srv_hello", _username, GAME_VERSION))
	multiplayer.connection_failed.connect(func() -> void:
		message = "Could not reach the server at %s. The flats are quiet." % _net_connect_addr
		_refresh_hud())
	multiplayer.server_disconnected.connect(func() -> void:
		message = "The server has gone under. Your deeds are saved there."
		_refresh_hud())
	message = "Crossing the flats to %s ..." % _net_connect_addr
	skip_autoload = true

## --- server-side RPCs -------------------------------------------------------
@rpc("any_peer", "reliable")
func srv_hello(username: String, version: String) -> void:
	if net_mode != "server":
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if version != GAME_VERSION:
		rpc_id(peer_id, "cl_message", "Your build is v%s; the server runs v%s. Grab the new build." % [version, GAME_VERSION])
		return
	var pid: int
	if net_players.has(username):
		pid = int(net_players[username])
	else:
		next_pid += 1
		pid = next_pid
		net_players[username] = pid
		stats.register(pid, 60.0, 60.0)
		abilities.earn(pid, 6 + clock.day * 2)   # late joiners get the days they missed
	if not stats.actors.has(pid):
		stats.register(pid, 60.0, 60.0)
	peers[peer_id] = pid
	avatars[pid] = Vector2(WORLD.x * TILE / 2.0, NORTH_H * TILE / 2.0)
	acting_pid = pid
	_recompute_vitals(pid)
	print("joined: %s (pid %d)" % [username, pid])
	rpc_id(peer_id, "cl_welcome", pid, _player_state(pid), _world_sync())
	rpc("cl_players", _players_snapshot())
	save_game()

@rpc("any_peer", "reliable")
func srv_intent(kind: String, args: Array) -> void:
	if net_mode != "server":
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not peers.has(peer_id):
		return
	acting_pid = peers[peer_id]
	message = ""
	match kind:
		"interact": intent_interact()
		"attack": intent_attack()
		"cast": intent_cast(str(args[0]))
		"eat": intent_eat()
		"craft_first": intent_craft_first()
		"craft": intent_craft(str(args[0]))
		"build": intent_build(str(args[0]))
		"consume": intent_consume_remnant()
		"allocate": abilities.allocate(acting_pid, str(args[0]))
		"deallocate": abilities.deallocate(acting_pid, str(args[0]))
		"equip": equip_toggle(acting_pid, str(args[0]))
		"give_food": intent_give_food()
		"stores_take": intent_stores_take(str(args[0]))
		"journal": journal_interact(acting_pid, int(args[0]))
		"sanctum": intent_sanctum(int(args[0]), str(args[1]), str(args[2]) if args.size() > 2 else "auto")
		"move_work": _move_work(int(args[0]), Vector2(float(args[1]), float(args[2])))
		"rotate_work": _rotate_work(int(args[0]))
		"demolish_work": _demolish_work(int(args[0]))
		"drill_train": intent_drill_train(int(args[0]), str(args[1]))
		"recruit": _net_villager_intent(int(args[0]), "recruit")
		"dismiss": _net_villager_intent(int(args[0]), "dismiss")
		"revive": _net_villager_intent(int(args[0]), "revive")
		"feed_beast": intent_feed_wild(_enemy_by_nid(int(args[0])))
		"offer_bait": intent_offer_bait()
		"beast_interact": intent_beast_interact(_beast_by_id(int(args[0])))
		"beast_revive": intent_revive_beast(_beast_by_id(int(args[0])))
		"rename_beast": intent_rename_beast(int(args[0]), int(args[1]))
		"dedicate_keystone": intent_dedicate_keystone(str(args[0]), int(args[1]))
		# test hook (net_smoke.gd, M3.c): force night RIGHT NOW and re-sync the
		# reef's night-only creatures immediately — a wire test can't sit
		# through real sim-hours to reach dusk, and the thing actually novel
		# over the network is the mirror (any DSEnemy the server spawns already
		# rides the existing enemy_list/cl_world_sync path — "just works").
		"test_force_night": _test_force_night()
		# test hook (net_smoke.gd, M3.c): killing a boss for real (even
		# test-accelerated melee) is more wire-test plumbing than the thing
		# actually under test — this seeds the per-boss dead flag directly so
		# a wire test can reach the keystone-dedication path (a REAL intent
		# from here on) without re-proving melee combat over the network.
		"test_kill_boss": bosses_dead[str(args[0])] = true
		# test hook (net_smoke.gd, M3.c): attunement bookkeeping (attuned_for)
		# is separate from devotion rank (test_attune only touches the
		# latter) — this grants the former directly so a wire test can make a
		# god ELIGIBLE for a keystone pick without walking to a shrine.
		"test_grant_attunement": attuned_for(acting_pid).append(str(args[0]))
		# test hook (net_smoke.gd): a deterministic way to trigger a REAL,
		# server-authoritative player death over the wire — real hound combat
		# has no deterministic timing to assert against; this calls the exact
		# same damage_player() path an enemy hit does, self-targeted only.
		"test_die": damage_player(999999.0, acting_pid)
		# test hook (net_smoke.gd): seed a calling at a given step for the
		# sender, so the wire test can exercise the REAL journal gate without
		# waiting for a lucky dawn draw — the runtime path from here on
		# (journal intent -> _step_met -> advance/nudge) is entirely real.
		"test_calling": _active_callings(acting_pid).append(
			{"id": str(args[0]), "step": str(args[1]), "since_day": clock.day})
		# test hook (net_smoke.gd): a client has no real way to harvest/craft its
		# way to a specific craved food across the wire deterministically — this
		# grants it straight into the sender's pack, the same "seed state, then
		# exercise the real runtime path" shape as test_calling above.
		"test_grant_item": inventory.add(acting_pid, str(args[0]), int(args[1]))
		# test hook (net_smoke.gd): taming a beast for real takes several sim-days
		# of feeding, which no test should sit through in real wall-clock time —
		# this seeds an ALREADY-TAMED beast straight onto the roster so the wire
		# test can verify the thing that's actually novel over the network (the
		# world_sync -> cl_world_sync mirror), the same "seed state, then exercise
		# the real path" shape as test_calling.
		"test_seed_beast": _test_seed_beast(acting_pid)
		# test hook (net_smoke.gd, M3.b): attunement for real is a walk to a
		# fallen shrine — this calls the SAME devotion.attune() a real kneel
		# does, so a wire test can reach rank 2 (Undertow) without modeling a
		# cross-map walk to Vessa's/Ghal's shrine over the wire.
		"test_attune": devotion.attune(acting_pid, str(args[0]))
		# test hook (net_smoke.gd): grants Temper directly, the same "seed
		# state minimally, then exercise the real path" shape as
		# test_grant_item — a wire test proving bait's WILD-6 hound gate over
		# the network shouldn't also have to prove several sim-days of
		# ordinary Temper accrual to afford the allocation.
		"test_grant_temper": abilities.earn(acting_pid, int(args[0]))
	rpc_id(peer_id, "cl_player_state", _player_state(acting_pid))
	rpc("cl_world_sync", _world_sync())

@rpc("any_peer", "unreliable_ordered")
func srv_pos(x: float, y: float) -> void:
	if net_mode != "server":
		return
	var pid: int = peers.get(multiplayer.get_remote_sender_id(), -1)
	if pid > 0:
		var new_pos := Vector2(x, y)
		# dash-through needs a remote caster's facing (_acting_facing) — derive
		# it from the position stream's own deltas, same "the stream already
		# reports it — hook it here" reasoning as the scarp check below.
		var moved: Vector2 = new_pos - avatars.get(pid, new_pos)
		if moved.length() > 0.5:
			_pid_facing[pid] = moved.normalized()
		avatars[pid] = new_pos
		_check_scarp_crossing(pid, y)   # the position stream already reports — hook it here, not input

## REEF-FOREST-SPEC §1: the FIRST time any player crosses south of the scarp,
## world-level and idempotent (fires once ever, persists in the save). Raises
## the Godhead cap 40% -> 70% (one biome keystone's worth) and says the
## numbers (the UI law). Called from the server tick that already tracks
## positions (srv_pos for networked clients; _physics_process for the host's
## own local player) — never from client input directly.
func _check_scarp_crossing(pid: int, y: float) -> void:
	if scarp_crossed or y <= float(SCARP_Y):
		return
	scarp_crossed = true
	var old_cap := godhead.cap()
	godhead.set_biomes_cleared(2)
	var new_cap := godhead.cap()
	_message_to(pid, "The world holds more of the gods here — cap %d%% -> %d%%." % [int(round(old_cap)), int(round(new_cap))])
	if net_mode == "server":
		rpc("cl_world_sync", _world_sync())

func _on_peer_left(peer_id: int) -> void:
	var pid: int = peers.get(peer_id, -1)
	peers.erase(peer_id)
	avatars.erase(pid)
	rpc("cl_players", _players_snapshot())
	save_game()

## --- payload builders (server) ----------------------------------------------
func _player_state(pid: int) -> Dictionary:
	return {
		"pid": pid,
		"inventory": inventory.inventories.get(pid, {}),
		"stats": stats.actors.get(pid, {}),
		"abilities": abilities.state.get(pid, {}),
		"devotion": devotion.state.get(pid, {}),
		"attuned": attuned_for(pid),
		"equipped": equipped.get(pid, {}),
		"callings": _active_callings(pid),
		"petrify": int(petrify.get(pid, 0)),
		"blood_scent": int(blood_scent.get(pid, 0)),
		"respawn_bind": int(respawn_bind.get(pid, -1)),
		"message": message,
	}

func _world_sync() -> Dictionary:
	var enemy_list := []
	for e in enemies:
		if is_instance_valid(e):
			enemy_list.append({"nid": _enemy_nid(e), "creature": e.creature_id,
				"x": e.position.x, "y": e.position.y, "hp": stats.hp(e), "surr": e.surrendered})
	var specials := []
	var extra_defs := []
	for n in resource_nodes:
		if is_instance_valid(n) and int(n.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			specials.append({"item": n.get_meta("item_id"), "x": n.position.x, "y": n.position.y, "idx": n.get_meta("idx")})
	# _static_node_def_count (set once boot world-gen finishes, both bands):
	# everything below it regenerates identically client-side for free; only
	# truly dynamic post-boot defs (boss hoard, corpse drops) need the wire.
	for i in range(_static_node_def_count, node_defs.size()):
		var d: Dictionary = node_defs[i]
		extra_defs.append({"item_id": d.item_id, "x": (d.pos as Vector2).x, "y": (d.pos as Vector2).y, "idx": d.idx})
	return {
		"day": clock.day, "minute": clock.minute_of_day,
		"harvested": harvested_indices, "extra_defs": extra_defs,
		"works": works.placed, "chapels": _chapels_to_dict(),
		"camp": [camp_center.x, camp_center.y] if camp_center != Vector2.INF else null,
		"bosses_dead": bosses_dead, "keystones_claimed": keystones_claimed, "enemies": enemy_list, "specials": specials,
		"villager": {"rescued": survivor.rescued, "tid": survivor.tribesman_id,
			"bloomed": bool(village.tribesmen.get(survivor.tribesman_id, {}).get("bloomed", false)),
			"mood": survivor.mood, "task": survivor.task, "help": survivor.needs_help,
			"housed": survivor.housed, "x": survivor.position.x, "y": survivor.position.y,
			"arms_cls": str(village.tribesmen.get(survivor.tribesman_id, {}).get("arms", {}).get("class_id", "")),
			"arms_xp": float(village.tribesmen.get(survivor.tribesman_id, {}).get("arms", {}).get("xp", 0.0)),
			"on_road": survivor.on_road, "comp_pid": survivor.companion_pid,
			"downed_until": float(village.tribesmen.get(survivor.tribesman_id, {}).get("downed_until", 0.0))},
		"pool": villagers.map(func(v: DSVillager) -> Dictionary:
			var rec: Dictionary = village.tribesmen.get(v.tribesman_id, {})
			return {"nid": int(v.get_meta("nid", 0)), "name": v.display_name, "cls": v.def_class,
				"x": v.position.x, "y": v.position.y, "rescued": v.rescued, "mood": v.mood, "job": v.job_work_id,
				"captive": v.is_captive, "held": v.days_held, "task": v.task, "help": v.needs_help,
				"housed": v.housed, "tid": v.tribesman_id, "bloomed": bool(rec.get("bloomed", false)),
				"covered": bool(rec.get("warden_covered", true)),
				"warm": v.warden_weapon, "warr": v.warden_armor,
				# the Arms track, mirrored raw so client-side accessors (village.arms_level etc.)
				# work identically off the same {class_id, xp} shape — no client-only logic needed
				"arms_cls": str(rec.get("arms", {}).get("class_id", "")),
				"arms_xp": float(rec.get("arms", {}).get("xp", 0.0)),
				"on_road": v.on_road, "comp_pid": v.companion_pid,
				"downed_until": float(rec.get("downed_until", 0.0)),
				# the character sheet's biography lines (discovered traits ONLY —
				# the hidden axes never leave the host, by design law)
				"origin": str(rec.get("origin", "rescued")), "patron": str(rec.get("patron_god_id", "")),
				"disc": rec.get("discovered", [])}),
		"stock": village_stock,
		"beasts": beasts.map(func(b: DSBeast) -> Dictionary:
			return {"id": b.beast_id, "creature": b.creature_id, "name": b.display_name,
				"x": b.position.x, "y": b.position.y, "owner": b.owner_pid,
				"at_heel": b.at_heel, "kenneled": b.kenneled,
				"mood": str(beast.beasts.get(b.beast_id, {}).get("mood", "keen")),
				"downed": b.downed, "level": beast.beast_level(b.beast_id),
				"instincts": beast.instincts_ignited(b.beast_id).size()}),
		"baits": baits.map(func(n: Node2D) -> Dictionary:
			return {"id": int(n.get_meta("bait_id")), "item": str(n.get_meta("item_id")),
				"x": n.position.x, "y": n.position.y, "pid": int(n.get_meta("dropper_pid")),
				"day": int(n.get_meta("day_dropped"))}),
		"node_left": _node_left_dict(),
		"sanctum": sanctum.to_save(),
		# Godhead (Part II §7): world-level, so a light mirror — value + consumed
		# per god, and the cap's biome count. Deliberately NOT godhead.to_save()
		# (that also carries per-player lifetime_deaths/death_window, which are
		# authoritative on the host only; a client mirror has no business
		# resetting its own copy of that from a periodic world tick).
		"godhead": {"state": godhead.state, "biomes_cleared": godhead.biomes_cleared()},
	}

func _players_snapshot() -> Array:
	var out := []
	for username: String in net_players:
		var pid := int(net_players[username])
		if avatars.has(pid):
			var p: Vector2 = avatars[pid]
			out.append({"pid": pid, "name": username, "x": p.x, "y": p.y})
	return out

func _enemy_nid(e: DSEnemy) -> int:
	if not enemy_net_ids.has(e):
		_next_enemy_net_id += 1
		enemy_net_ids[e] = _next_enemy_net_id
	return enemy_net_ids[e]

## --- client-side RPCs ---------------------------------------------------------
@rpc("authority", "reliable")
func cl_welcome(pid: int, pstate: Dictionary, wsync: Dictionary) -> void:
	my_pid = pid
	acting_pid = pid
	cl_player_state(pstate)
	cl_world_sync(wsync)
	message = "You cross onto the shared flats as %s. Day %d." % [_username, clock.day + 1]
	_refresh_hud()
	if "--probe" in OS.get_cmdline_user_args():
		print("PROBE OK: joined as pid %d, day %d, %d enemies mirrored" % [pid, clock.day + 1, enemies.size()])
		get_tree().quit(0)

@rpc("authority", "reliable")
func cl_player_state(p: Dictionary) -> void:
	inventory.inventories[my_pid] = p.get("inventory", {})
	stats.actors[my_pid] = p.get("stats", {})
	abilities.state[my_pid] = p.get("abilities", {})
	devotion.state[my_pid] = p.get("devotion", {})
	attuned[my_pid] = p.get("attuned", [])
	equipped[my_pid] = p.get("equipped", {})
	callings[my_pid] = p.get("callings", [])
	petrify_frames = int(p.get("petrify", 0))
	blood_scent_frames = int(p.get("blood_scent", 0))
	respawn_bind[my_pid] = int(p.get("respawn_bind", -1))   # for the "[E] Rest here" prompt
	if journal_open:
		_toggle_journal(true)
	if doll_open:
		_toggle_doll(true)
	if player != null:
		player.modulate = Color("cfd0ce") if petrify_frames > 0 else Color.WHITE
	if str(p.get("message", "")) != "":
		message = str(p.message)
	_refresh_hud()
	_refresh_bars()
	if sheet_open:
		_toggle_sheet(true)

@rpc("authority", "reliable")
func cl_world_sync(w: Dictionary) -> void:
	clock.day = int(w.get("day", 0))
	clock.minute_of_day = int(w.get("minute", 360))
	daynight.color = _tint_for_minute(clock.minute_of_day, player.position.y if player != null else 0.0, player.position.x if player != null else INF)
	var wcamp: Variant = w.get("camp", null)
	camp_center = Vector2(float(wcamp[0]), float(wcamp[1])) if wcamp != null else Vector2.INF
	_update_camp_ring()
	# extra node defs the server minted after world-gen (boss hoard etc.)
	for d: Dictionary in w.get("extra_defs", []):
		if int(d.idx) >= node_defs.size():
			var pos := Vector2(float(d.x), float(d.y))
			node_defs.append({"item_id": str(d.item_id), "pos": pos, "idx": int(d.idx)})
			_spawn_one_node(str(d.item_id), pos, int(d.idx))
	# harvested nodes vanish (deterministic layout means that's the whole diff)
	harvested_indices = (w.get("harvested", []) as Array).map(func(v: Variant) -> int: return int(v))
	for node in resource_nodes.duplicate():
		var idx := int(node.get_meta("idx", -1))
		if idx < STORM_GLASS_IDX_BASE and idx in harvested_indices:
			resource_nodes.erase(node)
			node.queue_free()
	# partially-worked nodes carry their wear (mirror shrinks to match)
	_apply_node_left(w.get("node_left", {}))
	# storm-glass and other ephemerals
	var have_specials := {}
	for node in resource_nodes:
		if is_instance_valid(node) and int(node.get_meta("idx", -1)) >= STORM_GLASS_IDX_BASE:
			have_specials[int(node.get_meta("idx"))] = node
	var want_specials := {}
	for sp: Dictionary in w.get("specials", []):
		want_specials[int(sp.idx)] = true
		if not have_specials.has(int(sp.idx)):
			_spawn_one_node(str(sp.item), Vector2(float(sp.x), float(sp.y)), int(sp.idx))
	for idx: int in have_specials:
		if not want_specials.has(idx):
			resource_nodes.erase(have_specials[idx])
			(have_specials[idx] as Node).queue_free()
	# works: spawn visuals for anything new; follow positions (someone may be dragging)
	var placed: Dictionary = SaveSystem._int_keys(w.get("works", {}))
	works.placed = placed
	chapels.clear()
	var chapel_dict: Dictionary = w.get("chapels", {})
	for inst_id: Variant in placed:
		var inst: Dictionary = placed[inst_id]
		var wpos := Vector2(float(inst.get("x", 0)), float(inst.get("y", 0)))
		if not work_visuals.has(int(inst_id)):
			_spawn_work_visual(int(inst_id), str(inst.work_id), wpos, chapel_dict)
		elif int(inst_id) != drag_work_id:
			(work_visuals[int(inst_id)] as Node2D).position = wpos
			(work_visuals[int(inst_id)] as Node2D).rotation_degrees = float(inst.get("rot", 0))
	# a work removed on the server (demolished) must vanish here too
	for vid: int in work_visuals.keys():
		if not placed.has(vid):
			if is_instance_valid(work_visuals[vid]):
				work_visuals[vid].queue_free()
			work_visuals.erase(vid)
	for god_id: Variant in chapel_dict:
		var cp: Array = chapel_dict[god_id]
		chapels[str(god_id)] = Vector2(float(cp[0]), float(cp[1]))
	# enemies: reconcile by net id
	bosses_dead = (w.get("bosses_dead", {}) as Dictionary)
	keystones_claimed = (w.get("keystones_claimed", {}) as Dictionary)
	for e in enemies.duplicate():
		if not is_instance_valid(e):
			enemies.erase(e)
	var have := {}
	for e in enemies:
		have[int(e.get_meta("nid", -1))] = e
	var want := {}
	for ed: Dictionary in w.get("enemies", []):
		var nid := int(ed.nid)
		want[nid] = true
		if have.has(nid):
			(have[nid] as DSEnemy).position = Vector2(float(ed.x), float(ed.y))
			if bool(ed.get("surr", false)) and not (have[nid] as DSEnemy).surrendered:
				(have[nid] as DSEnemy).surrender()
		else:
			var m := DSEnemy.new()
			m.mirror = true
			m.creature_id = str(ed.creature)
			m.position = Vector2(float(ed.x), float(ed.y))
			m.set_meta("nid", nid)
			m.host = self
			add_child(m)
			enemies.append(m)
	for nid: int in have:
		if not want.has(nid):
			var gone: DSEnemy = have[nid]
			enemies.erase(gone)
			gone.queue_free()
	# Anna
	if survivor != null and w.has("villager"):
		survivor.position = Vector2(float(w.villager.x), float(w.villager.y))
		survivor.tribesman_id = int(w.villager.get("tid", survivor.tribesman_id))
		survivor.task = str(w.villager.get("task", survivor.task))
		survivor.needs_help = bool(w.villager.get("help", false))
		survivor.housed = bool(w.villager.get("housed", false))
		survivor.visible = not survivor.housed
		if bool(w.villager.rescued) and not survivor.rescued:
			survivor.rescued = true
			survivor.set_label_name()
		survivor.on_road = bool(w.villager.get("on_road", false))
		survivor.companion_pid = int(w.villager.get("comp_pid", -1))
		if survivor.rescued:
			survivor.set_mood(str(w.villager.get("mood", "steady")))
			# a display-only record so the modal's tribesman lookups resolve on the client —
			# arms/equipment/downed_until ride raw so village.arms_level() etc. work unchanged
			if survivor.tribesman_id >= 0:
				village.tribesmen[survivor.tribesman_id] = {"bloomed": bool(w.villager.get("bloomed", false)), "warden_covered": true,
					"arms": {"class_id": str(w.villager.get("arms_cls", "")), "xp": float(w.villager.get("arms_xp", 0.0)), "levels_by_class": {}},
					"equipment": {"weapon": survivor.warden_weapon, "armor": survivor.warden_armor, "trinket": ""},
					"downed_until": float(w.villager.get("downed_until", 0.0))}
				survivor.downed = village.is_downed(survivor.tribesman_id)
				survivor.apply_downed_visual()
	# the rest of the roster (client mirrors, keyed by nid)
	village_stock = w.get("stock", {})
	var seen := {}
	for pd: Dictionary in w.get("pool", []):
		var nid := int(pd.nid)
		seen[nid] = true
		var body: DSVillager = null
		for v: DSVillager in villagers:
			if int(v.get_meta("nid", -1)) == nid:
				body = v
				break
		if body == null:
			body = DSVillager.new()
			body.host = self
			body.set_meta("nid", nid)
			body.display_name = str(pd.name)
			body.def_class = str(pd.cls)
			add_child(body)
			villagers.append(body)
		body.position = body.position.lerp(Vector2(float(pd.x), float(pd.y)), 0.5)
		body.job_work_id = str(pd.get("job", ""))
		body.is_captive = bool(pd.get("captive", false))
		body.days_held = int(pd.get("held", 0))
		body.task = str(pd.get("task", ""))
		body.needs_help = bool(pd.get("help", false))
		body.housed = bool(pd.get("housed", false))
		body.visible = not body.housed   # inside a hut, the mirror vanishes too
		body.tribesman_id = int(pd.get("tid", -1))   # WAS DROPPED: without it the modal's roster filter rejected every mirror
		body.warden_weapon = str(pd.get("warm", ""))
		body.warden_armor = str(pd.get("warr", ""))
		body.on_road = bool(pd.get("on_road", false))
		body.companion_pid = int(pd.get("comp_pid", -1))
		# a display-only tribesman record so the modal renders status on the client (the sim
		# runs server-side) — arms/equipment/downed_until ride raw off the same shape the
		# real sim uses, so village.arms_level()/villager_max_hp()/etc. work unchanged here
		if body.tribesman_id >= 0:
			village.tribesmen[body.tribesman_id] = {"bloomed": bool(pd.get("bloomed", false)),
				"warden_covered": bool(pd.get("covered", true)),
				"origin": str(pd.get("origin", "taken" if body.is_captive else "rescued")),
				"patron_god_id": str(pd.get("patron", "")), "discovered": pd.get("disc", []),
				"arms": {"class_id": str(pd.get("arms_cls", "")), "xp": float(pd.get("arms_xp", 0.0)), "levels_by_class": {}},
				"equipment": {"weapon": body.warden_weapon, "armor": body.warden_armor, "trinket": ""},
				"downed_until": float(pd.get("downed_until", 0.0))}
			body.downed = village.is_downed(body.tribesman_id)
			body.apply_downed_visual()
		if bool(pd.rescued) and not body.rescued:
			body.rescued = true
		if body.rescued:
			body.set_mood(str(pd.get("mood", "steady")))
		body._refresh_label()
	for v: DSVillager in villagers.duplicate():
		if not seen.has(int(v.get_meta("nid", -1))):
			villagers.erase(v)
			v.queue_free()
	# beasts at heel (Part III): mirrored by their stable roster id — no
	# separate net-id counter needed, beast_system's own id is already stable
	# across host and every client.
	var seen_beasts := {}
	for bd: Dictionary in w.get("beasts", []):
		var bid := int(bd.id)
		seen_beasts[bid] = true
		var bnode := _beast_by_id(bid)
		if bnode == null:
			bnode = DSBeast.new()
			bnode.host = self
			bnode.beast_id = bid
			bnode.creature_id = str(bd.creature)
			bnode.display_name = str(bd.name)
			bnode.owner_pid = int(bd.owner)
			add_child(bnode)
			beasts.append(bnode)
		bnode.position = bnode.position.lerp(Vector2(float(bd.x), float(bd.y)), 0.5)
		bnode.display_name = str(bd.get("name", bnode.display_name))   # M3.b: the rename modal changes this after spawn — must ride every sync, not just the first
		bnode.at_heel = bool(bd.at_heel)
		bnode.kenneled = bool(bd.kenneled)
		bnode.mood = str(bd.get("mood", "keen"))
		bnode.downed = bool(bd.get("downed", false))
		bnode.level = int(bd.get("level", 0))
		bnode.instincts_lit = int(bd.get("instincts", 0))
		bnode._refresh_label()
	for b: DSBeast in beasts.duplicate():
		if not seen_beasts.has(b.beast_id):
			beasts.erase(b)
			b.queue_free()
	# bait (Part III §2, the Shepherd's Way): mirrored by its own stable id —
	# same "no separate net-id counter" reasoning as beasts above.
	var seen_baits := {}
	for btd: Dictionary in w.get("baits", []):
		var bait_id := int(btd.id)
		seen_baits[bait_id] = true
		var have_it := false
		for n in baits:
			if is_instance_valid(n) and int(n.get_meta("bait_id", -1)) == bait_id:
				have_it = true
				break
		if not have_it:
			_spawn_bait_node(str(btd.item), Vector2(float(btd.x), float(btd.y)), int(btd.pid), int(btd.day), bait_id)
	for n in baits.duplicate():
		if not seen_baits.has(int(n.get_meta("bait_id", -1))):
			baits.erase(n)
			n.queue_free()
	if village_panel_open:
		_toggle_village(true)
	# the altars: client mirrors the sanctum state; refresh the open Offertory
	sanctum.from_save(w.get("sanctum", {}))
	if offertory_open:
		if sanctum.is_altar(offertory_inst):
			_toggle_offertory(true, offertory_inst)
		else:
			_toggle_offertory(false)   # the altar was reclaimed under us
	# Godhead (Part II §7): mirror the world-level state directly (a light
	# copy, not apply() — that method is for save/load and would also stomp
	# this client's own lifetime_deaths/death_window with the missing-key
	# defaults, since the world sync doesn't carry per-player death ledgers).
	var gh_sync: Dictionary = w.get("godhead", {})
	if gh_sync.has("state"):
		godhead.state = (gh_sync.state as Dictionary).duplicate(true)
	if gh_sync.has("biomes_cleared"):
		godhead.biomes_cleared_count = int(gh_sync.biomes_cleared)
	_refresh_hud()
	_refresh_bars()

@rpc("authority", "unreliable_ordered")
func cl_positions(players: Array, enemy_nids: Array, ex: Array, ey: Array, vx: float, vy: float) -> void:
	if survivor != null:
		survivor.position = survivor.position.lerp(Vector2(vx, vy), 0.5)
	for pd: Dictionary in players:
		var pid := int(pd.pid)
		if pid == my_pid:
			continue
		if not remote_nodes.has(pid):
			var av := Node2D.new()
			av.add_child(SpriteKit.sprite("survivor", Vector2(22, 30), Color("c8865a")))
			av.add_child(_player_name_tag(str(pd.get("name", "drifter"))))
			add_child(av)
			remote_nodes[pid] = av
		var node := remote_nodes[pid] as Node2D
		node.position = node.position.lerp(Vector2(float(pd.x), float(pd.y)), 0.5)
	for i in enemy_nids.size():
		for e in enemies:
			if is_instance_valid(e) and int(e.get_meta("nid", -1)) == int(enemy_nids[i]):
				e.position = e.position.lerp(Vector2(float(ex[i]), float(ey[i])), 0.5)

@rpc("authority", "reliable")
func cl_players(players: Array) -> void:
	var live := {}
	for pd: Dictionary in players:
		live[int(pd.pid)] = true
	for pid: int in remote_nodes.keys():
		if not live.has(pid) or pid == my_pid:
			(remote_nodes[pid] as Node).queue_free()
			remote_nodes.erase(pid)

@rpc("authority", "reliable")
func cl_message(text: String) -> void:
	message = text
	_refresh_hud()

## --- streams ------------------------------------------------------------------
func _net_tick(delta: float) -> void:
	_pos_timer += delta
	if _pos_timer < 0.1:
		return
	_pos_timer = 0.0
	if net_mode == "client" and multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		rpc_id(1, "srv_pos", player.position.x, player.position.y)
	elif net_mode == "server":
		var nids: Array = []
		var ex: Array = []
		var ey: Array = []
		for e in enemies:
			if is_instance_valid(e):
				nids.append(_enemy_nid(e))
				ex.append(e.position.x)
				ey.append(e.position.y)
		rpc("cl_positions", _players_snapshot(), nids, ex, ey, survivor.position.x, survivor.position.y)
