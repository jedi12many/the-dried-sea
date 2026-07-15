class_name SoundKit
extends Node
## Runtime audio, SpriteKit-style: loads our canonical WAVs (44.1k mono 16-bit,
## from tools/gen_sfx.py) straight off disk — no import pass, works in the
## tester zip and on fresh clones. One-shot pool + crossfading ambience.
## Headless/server: everything no-ops.

static var _cache: Dictionary = {}

var _pool: Array[AudioStreamPlayer] = []
var _pool_i := 0
var _amb_a: AudioStreamPlayer
var _amb_b: AudioStreamPlayer
var _amb_current := ""
var _fade := 0.0

func _ready() -> void:
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_amb_a = AudioStreamPlayer.new()
	_amb_b = AudioStreamPlayer.new()
	add_child(_amb_a)
	add_child(_amb_b)
	_amb_a.volume_db = -60.0
	_amb_b.volume_db = -60.0

static func stream(sound: String, looped := false) -> AudioStreamWAV:
	var key := sound + ("~loop" if looped else "")
	if _cache.has(key):
		return _cache[key]
	var path := ProjectSettings.globalize_path("res://assets/sfx/").path_join(sound + ".wav")
	var wav: AudioStreamWAV = null
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		# canonical RIFF from gen_sfx: scan for the 'data' chunk
		var pos := 12
		while pos + 8 <= bytes.size():
			var cid := bytes.slice(pos, pos + 4).get_string_from_ascii()
			var csize := bytes.decode_u32(pos + 4)
			if cid == "data":
				wav = AudioStreamWAV.new()
				wav.format = AudioStreamWAV.FORMAT_16_BITS
				wav.mix_rate = 44100
				wav.stereo = false
				wav.data = bytes.slice(pos + 8, pos + 8 + csize)
				if looped:
					wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
					wav.loop_end = csize / 2
				break
			pos += 8 + csize + (csize & 1)
	_cache[key] = wav
	return wav

## Fire-and-forget one-shot. `at` + `listener` give cheap distance falloff.
func play(sound: String, at := Vector2.INF, listener := Vector2.INF, base_db := 0.0) -> void:
	var s := SoundKit.stream(sound)
	if s == null:
		return
	var db := base_db
	if at != Vector2.INF and listener != Vector2.INF:
		var d := at.distance_to(listener)
		if d > 600.0:
			return
		db += -18.0 * (d / 600.0)
	var p := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = s
	p.volume_db = db
	p.play()

## Crossfade to an ambience bed ("amb_day" / "amb_night" / "amb_storm").
func ambience(sound: String) -> void:
	if sound == _amb_current:
		return
	_amb_current = sound
	var s := SoundKit.stream(sound, true)
	if s == null:
		return
	var incoming := _amb_b if _amb_a.playing else _amb_a
	incoming.stream = s
	incoming.volume_db = -60.0
	incoming.play()
	_fade = 1.0

func _process(delta: float) -> void:
	if _fade <= 0.0:
		return
	_fade = maxf(_fade - delta * 0.5, 0.0)
	var incoming := _amb_b if _amb_b.stream != null and _amb_b.playing and _amb_current != "" and _amb_b.stream == SoundKit._cache.get(_amb_current + "~loop") else _amb_a
	var outgoing := _amb_a if incoming == _amb_b else _amb_b
	incoming.volume_db = lerpf(-60.0, -8.0, 1.0 - _fade)
	outgoing.volume_db = lerpf(outgoing.volume_db, -60.0, (1.0 - _fade) * 0.3)
	if _fade == 0.0:
		outgoing.stop()
