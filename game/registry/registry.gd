class_name Registry
extends RefCounted
## Loads data/content/*.json into read-only dictionaries at boot.
## The validator (tools/validate.mjs) is the source of truth for content
## integrity; this loader fails loudly on the basics (parse errors, dup ids)
## and trusts validated content otherwise.
##
## Dev note: data/ lives at the REPO root (portability law) — one level above
## the Godot project. Export builds copy data/ into the pack (export step, M4).

var by_id: Dictionary = {}      # id -> entity Dictionary
var by_type: Dictionary = {}    # "god"/"work"/"item"/... -> Array[Dictionary]
var tuning: Dictionary = {}     # "economy"/"disposition"/"verdict" -> Dictionary
var load_errors: PackedStringArray = []

static func default_content_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("../data/content")

func load_all(content_root: String = "") -> bool:
	var root := content_root if content_root != "" else default_content_root()
	by_id.clear(); by_type.clear(); tuning.clear(); load_errors.clear()
	_walk(root)
	return load_errors.is_empty()

func _walk(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		load_errors.append("cannot open %s" % dir_path)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var path := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with("."):
				_walk(path)
		elif name.ends_with(".json"):
			_load_file(path)
		name = dir.get_next()
	dir.list_dir_end()

func _load_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if data == null:
		load_errors.append("bad JSON: %s" % path)
		return
	if path.contains("tuning"):
		tuning[path.get_file().get_basename()] = data
		return
	var list: Array = data if data is Array else [data]
	for entity: Dictionary in list:
		var id: String = entity.get("id", "")
		if id == "":
			load_errors.append("missing id in %s" % path)
			continue
		if by_id.has(id):
			load_errors.append("duplicate id %s (%s)" % [id, path])
			continue
		by_id[id] = entity
		var type := id.get_slice("-", 0)
		if not by_type.has(type):
			by_type[type] = []
		by_type[type].append(entity)

func get_entity(id: String) -> Dictionary:
	return by_id.get(id, {})

func all_of(type: String) -> Array:
	return by_type.get(type, [])
