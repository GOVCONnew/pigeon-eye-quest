## PIGEON EYE Quest — main controller. Builds the XR rig and HUD, receives vision results (PigeonVision Android
## plugin or the built-in demo feed), tracks contacts/poses, keeps path/waypoints/rooms, runs the LAN squad link.
## No network access except LAN UDP for the squad link. Nothing is uploaded.
extends Node3D

const VERSION := "0.1.1"
## v0.1.1: boxes only — skeleton / hands features are compiled out of this build (user request).
const POSE_FEATURE := false
const HUD_W := 1280; const HUD_H := 960
const HUD_DIST := 1.0; const HUD_QW := 1.4; const HUD_QH := 1.05   # metres → ±35° × ±27.7°
const CALLSIGNS := ["PIGEON", "FALCON", "HAWK", "RAVEN", "OWL", "KITE"]

var xr_on := false
var vision = null          # PigeonVision singleton (Android) or null
var demo := false
var origin: XROrigin3D; var cam: Node3D; var right: XRController3D; var left: XRController3D
var hud_vp: SubViewport; var hud: Control
var cfg := ConfigFile.new()
var S := {"detect": true, "pose": false, "low_power": false, "minimap": true, "squad": true, "big": false, "callsign": "PIGEON", "north_offset": 0.0, "north_set": false, "demo": false}
var det_tracker := PELogic.DetTracker.new()
var pose_tracker := PELogic.PoseTracker.new()
var last_frame := {}       # last vision frame: w, h, intr, t
var frame_head: Transform3D  # head pose when the last frame arrived
var vision_status := "vision: off"
var passthrough_status := "PASSTHROUGH: desktop"
var _vision_retry_t := 0.0
var vision_ms := 0.0; var vision_fps := 0.0; var _vf_count := 0; var _vf_t := 0.0
var path: Array = []; var waypoints: Array = []; var rooms: Array = []; var contacts_world: Array = []
var events: Array = []
var hands_logged := {}
var menu_open := false; var menu_sel := 0
var toast_text := ""; var toast_until := 0.0
var squad := PacketPeerUDP.new(); var squad_ok := false; var squad_id := ""; var squad_members := {}
var squad_origin := Transform3D.IDENTITY; var squad_t := 0.0
const SQUAD_PORT := 47474
var demo_t := 0.0

func _ready() -> void:
	_load_settings()
	squad_id = "%08x" % (randi())
	demo = S.demo or "--demo" in OS.get_cmdline_user_args() or "--demo" in OS.get_cmdline_args()
	_build_rig()
	_build_hud()
	_start_vision()
	_start_squad()
	_toast("PIGEON EYE QUEST v%s" % VERSION)

# ---------------------------------------------------------------- setup
func _build_rig() -> void:
	var xr := XRServer.find_interface("OpenXR")
	origin = XROrigin3D.new(); add_child(origin)
	if xr and xr.is_initialized():
		xr_on = true
		get_viewport().use_xr = true
		get_viewport().transparent_bg = true
		_enable_passthrough(xr)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		cam = XRCamera3D.new()
	else:
		cam = Camera3D.new(); (cam as Camera3D).fov = 70
	cam.position = Vector3(0, 1.6, 0)
	origin.add_child(cam)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0, 0, 0, 0)
	env.environment = e; add_child(env)
	for side in ["right", "left"]:
		var c := XRController3D.new(); c.tracker = "%s_hand" % side; origin.add_child(c)
		c.button_pressed.connect(_on_button.bind(side))
		if side == "right": right = c
		else: left = c

## Meta colour passthrough. Requires project setting xr/openxr/extensions/meta/passthrough=true (Godot OpenXR
## Vendors exposes ALPHA_BLEND only then) + export option meta_xr_features/passthrough + transparent viewport.
func _enable_passthrough(xr: XRInterface) -> void:
	var modes: Array = xr.get_supported_environment_blend_modes()
	var ok := false
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
		ok = xr.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND)
	if not ok and Engine.has_singleton("OpenXRFbPassthroughExtensionWrapper"):
		var fb = Engine.get_singleton("OpenXRFbPassthroughExtensionWrapper")
		if fb.has_method("start_passthrough"): ok = fb.start_passthrough()
	passthrough_status = "PASSTHROUGH: ON" if ok else "PASSTHROUGH: UNAVAILABLE modes=%s" % str(modes)
	print("PigeonEye ", passthrough_status, " blend modes ", modes)

func _build_hud() -> void:
	hud_vp = SubViewport.new(); hud_vp.size = Vector2i(HUD_W, HUD_H); hud_vp.transparent_bg = true
	hud_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS; hud_vp.disable_3d = true
	add_child(hud_vp)
	hud = Control.new(); hud.set_script(load("res://scripts/hud.gd")); hud.size = Vector2(HUD_W, HUD_H)
	hud_vp.add_child(hud)
	if xr_on:
		var q := MeshInstance3D.new(); var m := QuadMesh.new(); m.size = Vector2(HUD_QW, HUD_QH); q.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true; mat.render_priority = 10
		mat.albedo_texture = hud_vp.get_texture()
		q.material_override = mat; q.position = Vector3(0, 0, -HUD_DIST)
		cam.add_child(q)
	else:
		# Desktop / demo: show the HUD texture full-window over a dark backdrop.
		var layer := CanvasLayer.new(); add_child(layer)
		var bg := ColorRect.new(); bg.color = Color("#0b0f08"); bg.set_anchors_preset(Control.PRESET_FULL_RECT); layer.add_child(bg)
		var tr := TextureRect.new(); tr.texture = hud_vp.get_texture(); tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; layer.add_child(tr)

func _start_vision() -> void:
	if Engine.has_singleton("PigeonVision"):
		vision = Engine.get_singleton("PigeonVision")
		vision.connect("vision_result", _on_vision_json, CONNECT_DEFERRED)  # plugin emits from its camera thread
		vision.connect("vision_status", func(s): vision_status = "vision: " + s, CONNECT_DEFERRED)
		_apply_vision_settings()
		if S.detect:
			if not vision.hasPermission(): vision_status = "vision: waiting for camera permission"
			vision.start()
	elif demo:
		vision_status = "vision: DEMO FEED (synthetic)"
	else:
		vision_status = "vision: unavailable on this platform"

func _apply_vision_settings() -> void:
	if vision == null: return
	vision.setPoseEnabled(POSE_FEATURE and S.pose)
	vision.setMinIntervalMs(150 if S.low_power else 0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and vision != null and S.detect and vision.hasPermission(): vision.start()

# ---------------------------------------------------------------- settings
func _load_settings() -> void:
	if cfg.load("user://settings.cfg") == OK:
		for k in S.keys(): S[k] = cfg.get_value("s", k, S[k])
	if not POSE_FEATURE: S.pose = false

func _save_settings() -> void:
	for k in S.keys(): cfg.set_value("s", k, S[k])
	cfg.save("user://settings.cfg")

func _menu_items() -> Array:
	var on := func(b): return "ON" if b else "OFF"
	return [
		"Person/pet detection boxes: " + on.call(S.detect),
		"Low power (≤7 Hz vision): " + on.call(S.low_power),
		"Minimap: " + on.call(S.minimap),
		"Big text: " + on.call(S.big),
		"Squad link (LAN): " + on.call(S.squad),
		"Callsign: " + S.callsign,
		"SET NORTH (face north, press)",
		"SQUAD SYNC (stand on shared spot, face same way)",
		"Clear waypoints + rooms + path",
		"Demo feed: " + on.call(demo),
		"Close",
	]

func _menu_activate(i: int) -> void:
	match i:
		0:
			S.detect = not S.detect
			if vision: (vision.start() if S.detect else vision.stop())
		1: S.low_power = not S.low_power; _apply_vision_settings()
		2: S.minimap = not S.minimap
		3: S.big = not S.big
		4: S.squad = not S.squad
		5: S.callsign = CALLSIGNS[(CALLSIGNS.find(S.callsign) + 1) % CALLSIGNS.size()]
		6: S.north_offset = -_yaw_cw(); S.north_set = true; _toast("NORTH SET")
		7: squad_origin = Transform3D(Basis(Vector3.UP, -deg_to_rad(_yaw_cw())), _head().origin); _toast("SQUAD ORIGIN SET HERE"); _log("sync", "squad origin set")
		8: waypoints.clear(); rooms.clear(); path.clear(); _toast("CLEARED")
		9:
			demo = not demo; S.demo = demo
			vision_status = "vision: DEMO FEED (synthetic)" if demo else ("vision: " + vision.getStatus() if vision else "vision: off")
		10: menu_open = false
	_save_settings()

# ---------------------------------------------------------------- input
func _on_button(name: String, side: String) -> void:
	_handle_action(_action_for(name, side))

func _action_for(name: String, side: String) -> String:
	if name in ["by_button", "menu_button"]: return "menu"
	if menu_open:
		if name == "trigger_click": return "select"
		if name == "ax_button": return "down"
		return ""
	if name == "trigger_click" and side == "right": return "waypoint"
	if name == "ax_button" and side == "right": return "clear"
	if name == "ax_button" and side == "left": return "big"
	return ""

func _handle_action(a: String) -> void:
	match a:
		"menu": menu_open = not menu_open; menu_sel = 0
		"select": _menu_activate(menu_sel)
		"down": menu_sel = (menu_sel + 1) % _menu_items().size()
		"up": menu_sel = (menu_sel - 1 + _menu_items().size()) % _menu_items().size()
		"waypoint": _add_waypoint()
		"clear": _mark_clear()
		"big": S.big = not S.big; _save_settings()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo:
		var map := {KEY_M: "menu", KEY_ESCAPE: "menu", KEY_W: "waypoint", KEY_C: "clear", KEY_B: "big", KEY_DOWN: "down", KEY_UP: "up", KEY_ENTER: "select", KEY_SPACE: "select"}
		if map.has(ev.keycode): _handle_action(map[ev.keycode])
		if ev.keycode == KEY_LEFT: cam.rotate_y(deg_to_rad(10))
		if ev.keycode == KEY_RIGHT: cam.rotate_y(deg_to_rad(-10))

var _stick_latch := false
func _poll_stick() -> void:
	if not menu_open: return
	var v := 0.0
	for c in [right, left]:
		var s: Vector2 = c.get_vector2("primary")
		if absf(s.y) > absf(v): v = s.y
	if absf(v) > 0.7 and not _stick_latch: _stick_latch = true; _handle_action("up" if v > 0 else "down")
	elif absf(v) < 0.3: _stick_latch = false

# ---------------------------------------------------------------- geometry
func _head() -> Transform3D: return cam.global_transform
## Yaw of the head's forward vector, clockwise from the session-start forward (-Z), degrees.
func _yaw_cw(t: Transform3D = Transform3D()) -> float:
	var tt := _head() if t == Transform3D() else t
	var f := -tt.basis.z
	return rad_to_deg(atan2(f.x, -f.z))
func heading() -> float: return PELogic.wrap360(_yaw_cw() + S.north_offset)
## World position → minimap (east, north) metres in the north-aligned frame.
func to_map(p: Vector3) -> Vector2: return Vector2(p.x, -p.z).rotated(-deg_to_rad(S.north_offset))
func bearing_to(p: Vector3) -> float:
	var d: Vector2 = to_map(p) - to_map(_head().origin)
	return PELogic.wrap360(rad_to_deg(atan2(d.x, d.y)))

## Camera pixel → HUD pixel (gnomonic projection onto the head-locked quad). The camera is assumed aligned with
## the head; on Quest 3 the passthrough cameras sit a few cm off-axis so boxes can be slightly offset up close.
func cam_to_hud(px: Vector2) -> Vector2:
	var intr: Array = last_frame.get("intr", [480.0, 480.0, 320.0, 240.0])
	var tx: float = (px.x - intr[2]) / intr[0]; var ty: float = (px.y - intr[3]) / intr[1]
	return Vector2(HUD_W / 2.0 + tx / (HUD_QW / HUD_DIST) * HUD_W, HUD_H / 2.0 + ty / (HUD_QH / HUD_DIST) * HUD_H)

func _cam_px_rotated(px: Vector2, rel: Basis) -> Vector2:
	var intr: Array = last_frame.get("intr", [480.0, 480.0, 320.0, 240.0])
	var v := rel * Vector3((px.x - intr[2]) / intr[0], -(px.y - intr[3]) / intr[1], -1.0)
	if v.z > -0.05: return px
	return Vector2(intr[2] + intr[0] * (v.x / -v.z), intr[3] - intr[1] * (v.y / -v.z))

func cam_dir_world(px: Vector2, head: Transform3D) -> Vector3:
	var intr: Array = last_frame.get("intr", [480.0, 480.0, 320.0, 240.0])
	var local := Vector3((px.x - intr[2]) / intr[0], -(px.y - intr[3]) / intr[1], -1.0).normalized()
	return head.basis * local

# ---------------------------------------------------------------- vision
func _on_vision_json(js: String) -> void:
	var d = JSON.parse_string(js)
	if typeof(d) == TYPE_DICTIONARY: on_vision(d)

## One vision frame: {w, h, intr:[fx,fy,cx,cy], ms, dets:[{c,s,x,y,w,h}], poses:[[[x,y,vis]×33], …]}
func on_vision(d: Dictionary) -> void:
	var now := Time.get_ticks_msec() * 1.0
	var prev_head := frame_head; var had_prev := not last_frame.is_empty()
	last_frame = d; frame_head = _head()
	if had_prev:  # remove head rotation since the previous camera frame so boxes stay matched while you look around
		var rel: Basis = frame_head.basis.inverse() * prev_head.basis
		det_tracker.compensate(func(px: Vector2) -> Vector2: return _cam_px_rotated(px, rel))
	vision_ms = lerp(vision_ms, float(d.get("ms", 0)), 0.2)
	_vf_count += 1
	if now - _vf_t > 1000.0: vision_fps = _vf_count * 1000.0 / (now - _vf_t); _vf_count = 0; _vf_t = now
	var dets := []
	for x in d.get("dets", []):
		if x.c in ["person"] or x.c in PELogic.ANIMALS:
			dets.append({"c": x.c, "s": x.s, "box": Rect2(x.x, x.y, x.w, x.h)})
	det_tracker.update(dets, now)
	var poses := []
	for p in d.get("poses", []):
		var lm := []
		for q in p: lm.append(Vector3(q[0], q[1], q[2]))
		if lm.size() == 33: poses.append(lm)
	if POSE_FEATURE and S.pose: pose_tracker.update(poses, d.w, d.h, now)
	for tr in pose_tracker.tracks:
		var tag: String = tr.state.tag
		if tag != "" and hands_logged.get(tr.id, "") != tag: _log("pose", "person %s" % tag)
		hands_logged[tr.id] = tag

func _pose_for(box: Rect2, now: float):
	var best = null; var bi := 0.0
	for tr in pose_tracker.tracks:
		if now - tr.t > 600.0 or tr.hits < 2: continue
		if not box.has_point(tr.c): continue
		var v := PELogic.iou(box, tr.box)
		if v >= bi: bi = v; best = tr
	return best

# ---------------------------------------------------------------- actions
func _add_waypoint() -> void:
	var h := _head(); var f := -h.basis.z
	var p := h.origin + Vector3(f.x, 0, f.z).normalized() * 3.0
	if f.y < -0.05:  # looking down: drop where the gaze hits the floor (≤ 10 m)
		var t := (h.origin.y - origin.global_position.y) / -f.y
		if t < 10.0: p = h.origin + f * t
	var w := {"name": "WP%d" % (waypoints.size() + 1), "pos": p}
	waypoints.append(w); _toast("WAYPOINT %s · %03d°" % [w.name, int(bearing_to(p))]); _log("waypoint", w.name)
	_squad_send()

func _mark_clear() -> void:
	var r := {"name": "Room %d" % (rooms.size() + 1), "pos": _head().origin}
	rooms.append(r); _toast("MARK CLEAR · " + r.name); _log("room", r.name + " clear")
	_squad_send()

func _toast(s: String) -> void: toast_text = s; toast_until = Time.get_ticks_msec() / 1000.0 + 2.0
func _log(type: String, text: String) -> void:
	events.append({"t": Time.get_datetime_string_from_system(), "type": type, "text": text})
	if events.size() > 500: events.pop_front()

# ---------------------------------------------------------------- squad (LAN UDP broadcast)
func _start_squad() -> void:
	squad.set_broadcast_enabled(true)
	squad_ok = squad.bind(SQUAD_PORT) == OK
	squad.set_dest_address("255.255.255.255", SQUAD_PORT)

## Positions are sent in the shared squad frame (set by SQUAD SYNC on every headset at the same spot/facing).
func _to_squad(p: Vector3) -> Vector3: return squad_origin.affine_inverse() * p
func _from_squad(p: Vector3) -> Vector3: return squad_origin * p

func _squad_send() -> void:
	if not (S.squad and squad_ok): return
	var me := _to_squad(_head().origin)
	var msg := {"v": 1, "app": "pigeon-eye-quest", "id": squad_id, "cs": S.callsign, "p": [me.x, me.y, me.z],
		"wps": waypoints.map(func(w): var q := _to_squad(w.pos); return [w.name, q.x, q.z]),
		"rooms": rooms.map(func(r): var q := _to_squad(r.pos); return [r.name, q.x, q.z])}
	squad.put_packet(JSON.stringify(msg).to_utf8_buffer())

func _squad_poll(now: float) -> void:
	while squad_ok and squad.get_available_packet_count() > 0:
		var pk := squad.get_packet().get_string_from_utf8()
		var m = JSON.parse_string(pk)
		if typeof(m) != TYPE_DICTIONARY or m.get("app") != "pigeon-eye-quest" or m.get("id") == squad_id: continue
		m["seen"] = now; squad_members[m.id] = m
	for k in squad_members.keys():
		if now - squad_members[k].seen > 10.0: squad_members.erase(k)
	if now - squad_t > 0.5: squad_t = now; _squad_send()

# ---------------------------------------------------------------- demo feed (desktop testing / no camera)
func _demo_frame(t: float) -> Dictionary:
	var W := 640.0; var H := 480.0
	var cx := 320.0 + 170.0 * sin(t * 0.6); var top := 120.0; var hgt := 300.0
	var up := sin(t * 0.35) > 0.2
	var lm := []
	for i in 33: lm.append([0.0, 0.0, 0.0])
	var put := func(i, x, y): lm[i] = [(cx + x) / W, (top + y) / H, 0.95]
	put.call(0, 0, 25)
	for i in range(1, 11): put.call(i, (i % 2) * 6 - 3, 20)
	put.call(11, -32, 70); put.call(12, 32, 70)
	if up:
		put.call(13, -45, 25); put.call(14, 45, 25); put.call(15, -50, -15); put.call(16, 50, -15)
	else:
		put.call(13, -42, 115); put.call(14, 42, 115); put.call(15, -46, 160); put.call(16, 46, 160)
	for k in [[17, 15], [19, 15], [21, 15], [18, 16], [20, 16], [22, 16]]:
		lm[k[0]] = [lm[k[1]][0], lm[k[1]][1] - (0.015 if up else -0.015), 0.9]
	put.call(23, -22, 165); put.call(24, 22, 165); put.call(25, -24, 230); put.call(26, 24, 230); put.call(27, -25, 290); put.call(28, 25, 290)
	put.call(29, -28, 296); put.call(30, 28, 296); put.call(31, -18, 299); put.call(32, 18, 299)
	var dets := [{"c": "person", "s": 0.88, "x": cx - 70, "y": top - 15 if up else top, "w": 140, "h": hgt + (15 if up else 0)},
		{"c": "dog", "s": 0.74, "x": 470 - 60 * sin(t * 0.4), "y": 360, "w": 110, "h": 85}]
	return {"w": W, "h": H, "intr": [480.0, 480.0, 320.0, 240.0], "ms": 18, "dets": dets, "poses": [lm] if S.pose else []}

# ---------------------------------------------------------------- per-frame
func _process(dt: float) -> void:
	var now_s := Time.get_ticks_msec() / 1000.0; var now := now_s * 1000.0
	if not xr_on: cam.position = Vector3(0, 1.6, 0)
	if demo and S.detect:
		demo_t += dt
		if fmod(demo_t, 1.0 / 15.0) < dt: on_vision(_demo_frame(demo_t))
	_poll_stick()
	# camera permission is granted asynchronously (system dialog); keep retrying until the camera runs
	if vision != null and S.detect and now_s - _vision_retry_t > 2.0:
		_vision_retry_t = now_s
		var vs: String = vision.getStatus()
		if not vs.begins_with("RUNNING") and vs != "loading models" and not vs.begins_with("opening"):
			if vision.hasPermission(): vision.start()
			else: vision_status = "vision: waiting for camera permission (Settings › Privacy › App permissions)"
	# path breadcrumb every 0.5 m
	var hp := _head().origin
	if path.is_empty() or Vector2(hp.x - path[-1].x, hp.z - path[-1].z).length() > 0.5:
		path.append(hp)
		if path.size() > 4000: path.pop_front()
	if S.squad: _squad_poll(now_s)
	hud.st = build_hud_state(now)
	hud.queue_redraw()

## Assembles everything the HUD draws. Public so tests can inspect it.
func build_hud_state(now: float) -> Dictionary:
	var st := {}
	var hdg := heading()
	st.heading = hdg; st.big = S.big; st.minimap = S.minimap; st.version = VERSION
	st.north_mode = "SET" if S.north_set else "RELATIVE"
	st.clock = Time.get_time_string_from_system()
	var vs := vision_status
	if vision_fps > 0.0 and S.detect: vs += " · %.0f Hz · %d ms" % [vision_fps, int(vision_ms)]
	st.vision = vs if S.detect else "vision: OFF"
	st.passthrough = passthrough_status
	st.squad = ("SQUAD %d · %s" % [squad_members.size(), S.callsign]) if S.squad and squad_ok else ("SQUAD OFF" if not S.squad else "SQUAD: port busy")
	var contacts := []; var rows := []; var skels := []; var mapk := []
	var counts := {}; var hands_up := 0; var hands_vis := -1
	var fy: float = last_frame.get("intr", [480.0, 480.0])[1]
	var fh: float = last_frame.get("h", 480.0); var fw: float = last_frame.get("w", 640.0)
	if S.detect:
		for tr in det_tracker.confirmed(now):
			counts[tr.c] = counts.get(tr.c, 0) + 1
			var dist: Dictionary = PELogic.box_distance(tr.c, tr.box, fy, fh)
			var ps = _pose_for(tr.box, now) if POSE_FEATURE and tr.c == "person" and S.pose else null
			var dtxt := ("≤" if dist.min else "~") + "%.0fm" % dist.d
			if ps != null:
				var sd := PELogic.shoulder_distance(ps.lm, fw, fh, fy)
				if dist.min and not is_nan(sd): dtxt = "~%.0fm (sh)" % sd; dist.d = sd
			var centre: Vector2 = tr.box.get_center()
			var dir: Vector3 = cam_dir_world(centre, frame_head)
			var wpos: Vector3 = frame_head.origin + dir * dist.d
			var brg: float = bearing_to(wpos)
			var a: Vector2 = cam_to_hud(tr.box.position); var b: Vector2 = cam_to_hud(tr.box.end)
			var lines := ["%s %d · %d%%" % [tr.c.to_upper(), tr.id, int(tr.s * 100)], "%s · %03d°" % [dtxt, int(brg)]]
			var up := false
			if ps != null:
				if ps.state.tag != "": lines.append(ps.state.tag); up = ps.state.hands_up == 2
				lines.append("HANDS: " + PELogic.hands_text(ps.state.hands))
				hands_vis = max(hands_vis, ps.state.hands)
				if ps.state.hands_up == 2: hands_up += 1
				var pred: Array = pose_tracker.predict(ps, now)
				var pts := []; var vis := []
				for p in pred: pts.append(cam_to_hud(Vector2(p.x * fw, p.y * fh))); vis.append(PELogic.vis(p, 0.65))
				skels.append({"pts": pts, "vis": vis, "hands_up": up})
			contacts.append({"rect": Rect2(a, b - a), "lines": lines, "hands_up": up})
			rows.append("%s %d  %s  %03d°%s" % [tr.c.to_upper(), tr.id, dtxt, int(brg), ("  " + ps.state.tag) if ps != null and ps.state.tag != "" else ""])
			mapk.append({"p": to_map(wpos), "c": tr.c, "hands_up": up})
	var cparts := []
	for k in counts: cparts.append("%s %d" % [k.to_upper(), counts[k]])
	var ctext := "  ".join(cparts)
	if hands_vis >= 0: ctext += "  ·  HANDS: " + PELogic.hands_text(hands_vis)
	if hands_up > 0: ctext += "  ·  HANDS UP ×%d" % hands_up
	st.counts = ctext if ctext != "" else "NO CONTACTS"
	st.contacts = contacts; st.contact_rows = rows; st.skeletons = skels; st.map_contacts = mapk
	st.me = to_map(_head().origin)
	st.path = path.slice(max(0, path.size() - 400)).map(func(p): return to_map(p))
	st.waypoints = waypoints.map(func(w): return {"name": w.name, "p": to_map(w.pos)})
	st.rooms = rooms.map(func(r): return {"name": r.name, "p": to_map(r.pos)})
	var sm := []; var marks := []
	for m in squad_members.values():
		var p: Vector3 = _from_squad(Vector3(m.p[0], m.p[1], m.p[2]))
		sm.append({"cs": m.cs, "p": to_map(p)}); marks.append({"brg": bearing_to(p), "col": Color("#00E5FF")})
		for w in m.get("wps", []): st.waypoints.append({"name": "%s:%s" % [m.cs, w[0]], "p": to_map(_from_squad(Vector3(w[1], 0, w[2])))})
		for r in m.get("rooms", []): st.rooms.append({"name": "%s:%s" % [m.cs, r[0]], "p": to_map(_from_squad(Vector3(r[1], 0, r[2])))})
	for w in waypoints: marks.append({"brg": bearing_to(w.pos), "col": Color("#FFB000")})
	st.squad_members = sm; st.tape_marks = marks; st.map_range = 20.0
	st.menu_open = menu_open; st.menu_items = _menu_items(); st.menu_sel = menu_sel
	st.toast = toast_text if Time.get_ticks_msec() / 1000.0 < toast_until else ""
	st.hint = "R-TRIG waypoint · A mark clear · B/≡ settings · X big text" if xr_on else "W waypoint · C clear · M settings · ←/→ turn · B big"
	return st
