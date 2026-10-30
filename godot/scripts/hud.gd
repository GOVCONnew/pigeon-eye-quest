## PIGEON EYE Quest — HUD painter. Lives in a SubViewport that is shown on a head-locked quad in XR (or directly
## on screen in desktop/demo mode). Everything is drawn with _draw() from the `st` dictionary built by main.gd.
extends Control

const GREEN := Color("#9ACD32")
const DIM := Color(0.604, 0.804, 0.196, 0.55)
const AMBER := Color("#FFB000")
const RED := Color("#FF4040")
const CYAN := Color("#00E5FF")
const BLACK := Color(0, 0, 0, 0.55)

var st: Dictionary = {}
var font: Font

func _ready() -> void:
	font = ThemeDB.fallback_font

func txt(p: Vector2, s: String, size: int = 22, c: Color = GREEN, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	draw_string_outline(font, p, s, align, w, size, 4, Color(0, 0, 0, 0.8))
	draw_string(font, p, s, align, w, size, c)

func _draw() -> void:
	if st.is_empty(): return
	var W := size.x; var H := size.y
	var big: bool = st.get("big", false)
	var fs := 26 if big else 22
	_compass(W, fs)
	_status(W, H, fs)
	for c in st.get("contacts", []): _contact(c, fs)
	for s in st.get("skeletons", []): _skeleton(s)
	if st.get("minimap", true): _minimap(Vector2(150, H - 170), 130.0)
	_contact_list(W, H, fs)
	if st.get("menu_open", false): _menu(W, H)
	if st.get("toast", "") != "":
		var tw := font.get_string_size(st.toast, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x + 40
		draw_rect(Rect2(W / 2 - tw / 2, H * 0.62, tw, 44), Color(0, 0, 0, 0.75)); draw_rect(Rect2(W / 2 - tw / 2, H * 0.62, tw, 44), GREEN, false, 2)
		txt(Vector2(W / 2 - tw / 2 + 20, H * 0.62 + 30), st.toast, 24)
	# centre reticle
	var c := Vector2(W / 2, H / 2)
	draw_line(c - Vector2(14, 0), c - Vector2(5, 0), DIM, 2); draw_line(c + Vector2(5, 0), c + Vector2(14, 0), DIM, 2)
	draw_line(c - Vector2(0, 14), c - Vector2(0, 5), DIM, 2); draw_line(c + Vector2(0, 5), c + Vector2(0, 14), DIM, 2)

func _compass(W: float, fs: int) -> void:
	var hdg: float = st.get("heading", 0.0)
	var cx := W / 2; var y := 64.0; var span := 90.0; var pxd := W * 0.6 / span
	txt(Vector2(cx - 120, 34), "%03d° %s" % [int(round(PELogic.wrap360(hdg))) % 360, PELogic.cardinal(hdg)], fs + 8, GREEN, HORIZONTAL_ALIGNMENT_CENTER, 240)
	draw_line(Vector2(cx - span / 2 * pxd, y + 22), Vector2(cx + span / 2 * pxd, y + 22), DIM, 1)
	var start := int(floor((hdg - span / 2) / 5.0)) * 5
	for d in range(start, int(hdg + span / 2) + 5, 5):
		var x := cx + PELogic.ang_diff(hdg, float(d)) * pxd
		if absf(x - cx) > span / 2 * pxd: continue
		var dd := int(PELogic.wrap360(d))
		var major := dd % 15 == 0
		draw_line(Vector2(x, y + 22), Vector2(x, y + (6 if major else 14)), GREEN if major else DIM, 2 if major else 1)
		if dd % 45 == 0: txt(Vector2(x - 30, y + 2), PELogic.cardinal(dd), 20, GREEN, HORIZONTAL_ALIGNMENT_CENTER, 60)
		elif major: txt(Vector2(x - 30, y + 2), str(dd), 16, DIM, HORIZONTAL_ALIGNMENT_CENTER, 60)
	# waypoint / squad markers on tape
	for m in st.get("tape_marks", []):
		var off := PELogic.ang_diff(hdg, m.brg)
		var x := cx + clampf(off, -span / 2, span / 2) * pxd
		draw_colored_polygon(PackedVector2Array([Vector2(x, y + 26), Vector2(x - 7, y + 38), Vector2(x + 7, y + 38)]), m.col)
	draw_colored_polygon(PackedVector2Array([Vector2(cx, y + 24), Vector2(cx - 8, y + 40), Vector2(cx + 8, y + 40)]), RED)

func _status(W: float, H: float, fs: int) -> void:
	var y := 128.0
	var mode: String = st.get("north_mode", "RELATIVE")
	var chip := "6DOF" + ("" if mode == "SET" else " · HDG RELATIVE")
	txt(Vector2(24, y), chip, 18, AMBER if mode != "SET" else GREEN)
	txt(Vector2(W - 424, y), st.get("vision", ""), 18, GREEN, HORIZONTAL_ALIGNMENT_RIGHT, 400)
	txt(Vector2(W - 424, y + 24), st.get("squad", ""), 18, CYAN, HORIZONTAL_ALIGNMENT_RIGHT, 400)
	txt(Vector2(24, y + 28), st.get("counts", ""), fs)
	txt(Vector2(24, y + 52), st.get("clock", ""), 16, DIM)

func _contact(c: Dictionary, fs: int) -> void:
	var r: Rect2 = c.rect
	var col: Color = AMBER if c.get("hands_up", false) else GREEN
	var L := clampf(min(r.size.x, r.size.y) * 0.25, 10, 40)
	for corner in [[r.position, Vector2(1, 1)], [Vector2(r.end.x, r.position.y), Vector2(-1, 1)], [Vector2(r.position.x, r.end.y), Vector2(1, -1)], [r.end, Vector2(-1, -1)]]:
		var p: Vector2 = corner[0]; var s: Vector2 = corner[1]
		draw_line(p, p + Vector2(L * s.x, 0), col, 3); draw_line(p, p + Vector2(0, L * s.y), col, 3)
	var y := r.position.y - 8
	var lines: Array = c.lines
	for i in range(lines.size() - 1, -1, -1):
		txt(Vector2(r.position.x, y), lines[i], fs if i == 0 else fs - 4, col if i == 0 or "HANDS UP" in lines[i] or "HAND UP" in lines[i] else GREEN)
		y -= fs + 2

func _skeleton(s: Dictionary) -> void:
	var pts: Array = s.pts; var vis: Array = s.vis
	var col: Color = AMBER if s.get("hands_up", false) else GREEN
	for e in PELogic.EDGES:
		if vis[e[0]] and vis[e[1]]: draw_line(pts[e[0]], pts[e[1]], col, 3, true)
	for i in pts.size():
		if (i > 0 and i < 11) or not vis[i]: continue
		draw_circle(pts[i], 6.0 if i == 15 or i == 16 else 4.0, col)
	if vis[0]:
		var sw: float = (pts[11] - pts[12]).length() if vis[11] and vis[12] else 40.0
		draw_arc(pts[0], max(8.0, sw * 0.28), 0, TAU, 24, col, 3)

func _minimap(c: Vector2, R: float) -> void:
	draw_circle(c, R, BLACK)
	draw_arc(c, R, 0, TAU, 64, GREEN, 2); draw_arc(c, R * 0.5, 0, TAU, 48, DIM, 1)
	var scale: float = R / float(st.get("map_range", 20.0))
	var hdg: float = st.get("heading", 0.0)
	var me: Vector2 = st.get("me", Vector2.ZERO)
	var rot := -deg_to_rad(hdg)
	var to_px := func(p: Vector2) -> Vector2:
		var d: Vector2 = (p - me) * scale  # p in (east, north) metres
		var v: Vector2 = Vector2(d.x, -d.y).rotated(rot)
		return c + v.limit_length(R - 6)
	# north marker
	var n: Vector2 = c + Vector2(0, -R + 14).rotated(rot)
	txt(n - Vector2(8, -8), "N", 18, RED)
	var path: Array = st.get("path", [])
	for i in range(1, path.size()): draw_line(to_px.call(path[i - 1]), to_px.call(path[i]), DIM, 2)
	for r in st.get("rooms", []):
		var p: Vector2 = to_px.call(r.p); draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), GREEN, false, 2); txt(p + Vector2(8, 4), r.name, 13)
	for w in st.get("waypoints", []):
		var p: Vector2 = to_px.call(w.p); draw_colored_polygon(PackedVector2Array([p + Vector2(0, -8), p + Vector2(7, 0), p + Vector2(0, 8), p + Vector2(-7, 0)]), AMBER); txt(p + Vector2(9, 4), w.name, 13, AMBER)
	for k in st.get("map_contacts", []):
		var p: Vector2 = to_px.call(k.p); draw_circle(p, 5, AMBER if k.hands_up else (CYAN if k.c != "person" else RED))
	for m in st.get("squad_members", []):
		var p: Vector2 = to_px.call(m.p); draw_circle(p, 6, CYAN); txt(p + Vector2(8, 4), m.cs, 13, CYAN)
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -10), c + Vector2(7, 8), c + Vector2(-7, 8)]), GREEN)
	txt(c + Vector2(-R, R + 22), "%dm" % int(st.get("map_range", 20.0)), 14, DIM)

func _contact_list(W: float, H: float, fs: int) -> void:
	var y := H - 40.0
	var rows: Array = st.get("contact_rows", [])
	for i in range(min(rows.size(), 5) - 1, -1, -1):
		txt(Vector2(W - 520, y), rows[i], fs - 2, AMBER if "UP" in rows[i] else GREEN, HORIZONTAL_ALIGNMENT_RIGHT, 500); y -= fs + 4
	txt(Vector2(W - 520, H - 12), st.get("hint", ""), 14, DIM, HORIZONTAL_ALIGNMENT_RIGHT, 500)

func _menu(W: float, H: float) -> void:
	var items: Array = st.get("menu_items", []); var sel: int = st.get("menu_sel", 0)
	var mw := 560.0; var mh := 70.0 + items.size() * 40.0
	var o := Vector2(W / 2 - mw / 2, H / 2 - mh / 2)
	draw_rect(Rect2(o, Vector2(mw, mh)), Color(0, 0, 0, 0.85)); draw_rect(Rect2(o, Vector2(mw, mh)), GREEN, false, 2)
	txt(o + Vector2(20, 40), "SETTINGS · PIGEON EYE QUEST v" + str(st.get("version", "")), 22)
	for i in items.size():
		var y := o.y + 82 + i * 40
		if i == sel: draw_rect(Rect2(o.x + 8, y - 28, mw - 16, 38), Color(0.604, 0.804, 0.196, 0.25))
		txt(Vector2(o.x + 24, y), items[i], 22, GREEN if i == sel else DIM)
