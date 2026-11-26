extends RefCounted

## [GSBotNav]'s collider parse a slice per frame, for [method GSBotNav.bake_in_background]: the engine's
## [method NavigationServer3D.parse_source_geometry_data] reads the whole scene tree on the main thread in one call
## (seconds on a big map), and refuses a worker thread. This walks the same nodes in the engine's order and hands it
## the shapes a chunk at a time, moved onto one disabled body of its own under the tree's root (so its transform is
## the identity) with each shape owner's transform taken relative to the bake root. The engine then writes the very
## triangles it would have written in one call; the selftest checks they are the same to the bit.
## A node the engine parses some other way (CSG, a GridMap, an obstacle that carves) falls back to the one call.
## Nothing outside the nav names this script.

## Shape owners handed to the engine per parse call: fewer costs more calls, more overshoots the slice.
const CHUNK := 64

var _root: Node3D = null
var _mask: int = 0
var _until_usec: int = 0
var _source := NavigationMeshSourceGeometryData3D.new()
var _piece := NavigationMeshSourceGeometryData3D.new()
## The engine's settings with its own body as the root: what [member _host] is parsed with.
var _chunk_mesh := NavigationMesh.new()
var _host := StaticBody3D.new()
var _inverse := Transform3D.IDENTITY
## Nodes still to visit, the next one last.
var _stack: Array[Node] = []
var _body: StaticBody3D = null
var _owners := PackedInt32Array()
var _next_owner: int = 0
var _fallback: bool = false
## The group the engine reads in a group bake, and the nodes that were in it when the parse began.
var _group := StringName()
var _tops: Array[Node] = []
var _done: bool = false


## Starts on [param root] with [param mesh]'s parse settings: [method step] then walks it.
func _init(root: Node3D, mesh: NavigationMesh) -> void:
	_root = root
	_mask = mesh.geometry_collision_mask
	_chunk_mesh.geometry_parsed_geometry_type = mesh.geometry_parsed_geometry_type
	_chunk_mesh.geometry_collision_mask = _mask
	_chunk_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	_host.process_mode = Node.PROCESS_MODE_DISABLED
	_host.collision_layer = 0xFFFFFFFF
	_host.collision_mask = 0
	_inverse = root.global_transform.affine_inverse()
	_tops = [root]
	if mesh.geometry_source_geometry_mode != NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN:
		_group = mesh.geometry_source_group_name
		_tops = root.get_tree().get_nodes_in_group(_group)
	if mesh.geometry_source_geometry_mode == NavigationMesh.SOURCE_GEOMETRY_GROUPS_EXPLICIT:
		_fallback = true
	for i in range(_tops.size() - 1, -1, -1):
		_stack.append(_tops[i])


## Whether all is parsed: [method source] is then the engine's own result.
func is_done() -> bool:
	return _done


## The parsed geometry, whole once [method is_done].
func source() -> NavigationMeshSourceGeometryData3D:
	return _source


## Parses on from where the last call stopped until [param until_usec] ([method Time.get_ticks_usec]; 0 to the end),
## with [param mesh] the bake's own settings for a fallback. True when done.
func step(mesh: NavigationMesh, until_usec: int) -> bool:
	if _done:
		return true
	_until_usec = until_usec
	if not _fallback:
		_root.get_tree().root.add_child(_host)
		_walk()
		_host.get_parent().remove_child(_host)
	if _fallback:
		# One call over everything: what was merged so far is dropped, so nothing is parsed twice. The caller
		# may have emptied its group since the parse began, so the nodes go back in it for the call.
		_source.clear()
		var regrouped := _tops.filter(func(top: Node) -> bool: return is_instance_valid(top) and not _group.is_empty() and not top.is_in_group(_group))
		for top: Node in regrouped:
			top.add_to_group(_group)
		NavigationServer3D.parse_source_geometry_data(mesh, _source, _root)
		for top: Node in regrouped:
			top.remove_from_group(_group)
		_stack.clear()
		_done = true
	return _done


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_host):
		_host.free()


## At least one node or chunk a call, so a slice shorter than either still gets through.
func _walk() -> void:
	var first := true
	while first or not _past():
		first = false
		if _body != null and is_instance_valid(_body) and _next_owner < _owners.size():
			_chunk()
			continue
		_body = null
		if _stack.is_empty():
			_done = true
			return
		var node: Node = _stack.pop_back()
		if not is_instance_valid(node):
			continue
		# The engine's order: a node, then its children (internal ones too) in turn.
		for i in range(node.get_child_count(true) - 1, -1, -1):
			_stack.append(node.get_child(i, true))
		if node.is_class("CSGShape3D") or node.is_class("GridMap") or node is NavigationObstacle3D:
			_fallback = true
			return
		if node is StaticBody3D and (node as StaticBody3D).collision_layer & _mask != 0:
			_body = node
			_owners = _body.get_shape_owners()
			_next_owner = 0


## Up to [constant CHUNK] of the body's shape owners onto the host, parsed and merged, then taken off again.
func _chunk() -> void:
	var at := _body.global_transform
	var taken := 0
	while _next_owner < _owners.size() and taken < CHUNK:
		var owner_id := _owners[_next_owner]
		_next_owner += 1
		if _body.is_shape_owner_disabled(owner_id):
			continue
		var held := _host.create_shape_owner(_host)
		_host.shape_owner_set_transform(held, _inverse * (at * _body.shape_owner_get_transform(owner_id)))
		for s in _body.shape_owner_get_shape_count(owner_id):
			_host.shape_owner_add_shape(held, _body.shape_owner_get_shape(owner_id, s))
		taken += 1
	if taken == 0:
		return
	_piece.clear()
	NavigationServer3D.parse_source_geometry_data(_chunk_mesh, _piece, _host)
	_source.merge(_piece)
	for held in _host.get_shape_owners():
		_host.remove_shape_owner(held)


func _past() -> bool:
	return _until_usec > 0 and Time.get_ticks_usec() >= _until_usec
