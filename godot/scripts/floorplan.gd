## PIGEON EYE Quest — very rough floor plan. A 0.25 m occupancy grid on the floor (world X/Z) fed by Meta scene data
## (wall / door-frame / floor anchors and the global scene mesh) plus where the wearer has walked.
## Walls = vertical surfaces at walking height (0.4–1.8 m above floor). Doorways = door-frame anchors, or narrow
## (0.5–1.25 m) wall gaps. Rooms = connected free-floor regions with walls *and* doorways as barriers.
## It is a sketch for orientation, not an architectural drawing.
class_name FloorPlan
extends RefCounted

const CELL := 0.25
const WALL := 1; const DOOR := 2; const FLOOR := 3; const GAP := 4  # GAP = doorway inferred from a wall gap
const LOW := 0.4; const HIGH := 1.8   # walking-height slice above the floor
var cells := {}            # Vector2i -> kind
var floor_y := 0.0
var rooms: Array = []      # [{name, p: Vector2 (world x,z), area}]
var dirty := true
var walls_n := 0; var doors_n := 0; var anchors_n := 0; var mesh_tris := 0

static func key(p: Vector2) -> Vector2i: return Vector2i(floori(p.x / CELL), floori(p.y / CELL))
static func centre(k: Vector2i) -> Vector2: return (Vector2(k) + Vector2(0.5, 0.5)) * CELL

func clear() -> void:
	cells.clear(); rooms.clear(); dirty = true; walls_n = 0; doors_n = 0; anchors_n = 0; mesh_tris = 0

func _line(a: Vector2, b: Vector2, kind: int, overwrite: bool) -> void:
	var n := maxi(1, ceili(a.distance_to(b) / (CELL * 0.5)))
	for i in n + 1:
		var k := key(a.lerp(b, float(i) / n))
		if overwrite or not cells.has(k) or cells[k] == FLOOR or cells[k] == GAP: cells[k] = kind
	dirty = true

## Wall segment on the floor plane (world x,z).
func add_wall(a: Vector2, b: Vector2) -> void:
	walls_n += 1; _line(a, b, WALL, false)

## Door: punches a gap through any wall and acts as a room separator.
func add_door(a: Vector2, b: Vector2) -> void:
	doors_n += 1; _line(a, b, DOOR, true)

func add_floor(poly: PackedVector2Array) -> void:
	if poly.size() < 3: return
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly: r = r.expand(p)
	for x in range(floori(r.position.x / CELL), ceili(r.end.x / CELL)):
		for y in range(floori(r.position.y / CELL), ceili(r.end.y / CELL)):
			var k := Vector2i(x, y)
			if not cells.has(k) and Geometry2D.is_point_in_polygon(centre(k), poly): cells[k] = FLOOR
	dirty = true

func mark_walked(p: Vector3) -> void:
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			var k := key(Vector2(p.x, p.z)) + Vector2i(dx, dy)
			if not cells.has(k): cells[k] = FLOOR; dirty = true

## Scene mesh triangles (already in world space). Vertical-ish triangles in the walking-height slice become wall.
func add_mesh(verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	var lo := floor_y + LOW; var hi := floor_y + HIGH
	for t in range(0, idx.size() - 2, 3):
		var a := verts[idx[t]]; var b := verts[idx[t + 1]]; var c := verts[idx[t + 2]]
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() < 1e-8: continue
		mesh_tris += 1
		var ny := absf(nrm.normalized().y)
		var ymin := minf(a.y, minf(b.y, c.y)); var ymax := maxf(a.y, maxf(b.y, c.y))
		if ny < 0.35 and ymax > lo and ymin < hi:
			_line(Vector2(a.x, a.z), Vector2(b.x, b.z), WALL, false)
			_line(Vector2(b.x, b.z), Vector2(c.x, c.z), WALL, false)
		elif ny > 0.9 and absf((a.y + b.y + c.y) / 3.0 - floor_y) < 0.15:
			add_floor(PackedVector2Array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)]))
	dirty = true

func _is_wall(k: Vector2i) -> bool: return cells.get(k, 0) == WALL

## Narrow wall gaps (2–5 cells) with open space on both sides → doorway.
func detect_doorways() -> void:
	var adds := []
	for k in cells:
		if cells[k] != FLOOR: continue
		for ax in [Vector2i(1, 0), Vector2i(0, 1)]:
			var perp := Vector2i(ax.y, ax.x)
			var l := -1; var r := -1
			for i in range(1, 5):
				if l < 0 and _is_wall(k - ax * i): l = i
				if r < 0 and _is_wall(k + ax * i): r = i
			if l < 0 or r < 0 or l + r - 1 < 2 or l + r - 1 > 5: continue
			if _is_wall(k + perp) or _is_wall(k - perp) or _is_wall(k + perp * 2) or _is_wall(k - perp * 2): continue
			# open floor beyond the gap on both sides
			if cells.get(k + perp * 3, 0) == FLOOR and cells.get(k - perp * 3, 0) == FLOOR: adds.append(k)
	for k in adds: cells[k] = GAP

## Flood-fill rooms. Call when dirty (cheap for a house-sized grid).
func rebuild() -> void:
	if not dirty: return
	dirty = false
	for k in cells.keys():
		if cells[k] == GAP: cells[k] = FLOOR  # re-detect gap doorways from scratch
	detect_doorways()
	rooms.clear()
	var seen := {}
	for k in cells:
		if cells[k] != FLOOR or seen.has(k): continue
		var stack := [k]; seen[k] = true; var n := 0; var sum := Vector2.ZERO
		while not stack.is_empty():
			var q: Vector2i = stack.pop_back(); n += 1; sum += centre(q)
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var m: Vector2i = q + d
				if cells.get(m, 0) == FLOOR and not seen.has(m): seen[m] = true; stack.append(m)
		var area := n * CELL * CELL
		if area >= 1.0: rooms.append({"p": sum / n, "area": area, "n": n})
	rooms.sort_custom(func(a, b): return a.area > b.area)
	for i in rooms.size(): rooms[i].name = "R%d" % (i + 1)

## Cells of one kind within radius of p (world x,z), for drawing.
func cells_near(p: Vector2, radius: float, kind: int) -> Array:
	var out := []
	var c := key(p); var rr := ceili(radius / CELL)
	if (2 * rr + 1) * (2 * rr + 1) > cells.size():
		for k in cells:
			if (cells[k] == kind or (kind == DOOR and cells[k] == GAP)) and centre(k).distance_to(p) <= radius: out.append(centre(k))
	else:
		for x in range(-rr, rr + 1):
			for y in range(-rr, rr + 1):
				var k := c + Vector2i(x, y)
				var v: int = cells.get(k, 0)
				if v == kind or (kind == DOOR and v == GAP): out.append(centre(k))
	return out
