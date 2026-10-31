## Headless tests: godot --headless --xr-mode off --path godot -s tests/run_tests.gd
extends SceneTree

var passed := 0; var failed := 0

func check(name: String, ok: bool, info = "") -> void:
	if ok: passed += 1; print("ok   ", name)
	else: failed += 1; print("FAIL ", name, " — ", info)

func body(up_l := false, up_r := false, dx := 0.0) -> Array:
	var lm := []
	for i in 33: lm.append(Vector3(0.5 + dx, 0.5, 0.0))
	var s := func(i, x, y): lm[i] = Vector3(x + dx, y, 0.95)
	s.call(0, 0.5, 0.2); s.call(11, 0.45, 0.3); s.call(12, 0.55, 0.3); s.call(23, 0.46, 0.55); s.call(24, 0.54, 0.55)
	s.call(13, 0.43, 0.2 if up_l else 0.4); s.call(14, 0.57, 0.2 if up_r else 0.4)
	s.call(15, 0.42, 0.1 if up_l else 0.5); s.call(16, 0.58, 0.1 if up_r else 0.5)
	s.call(25, 0.46, 0.75); s.call(26, 0.54, 0.75); s.call(27, 0.46, 0.92); s.call(28, 0.54, 0.92)
	return lm

func shift(lm: Array, dx: float) -> Array: return lm.map(func(p): return Vector3(p.x + dx, p.y, p.z))

func _init() -> void:
	# --- geometry / compass helpers
	check("wrap360 / ang_diff across north", PELogic.wrap360(-10) == 350.0 and PELogic.ang_diff(350, 10) == 20.0 and PELogic.ang_diff(10, 350) == -20.0)
	check("cardinal", PELogic.cardinal(44) == "NE" and PELogic.cardinal(359) == "N" and PELogic.cardinal(180) == "S")
	var d: Dictionary = PELogic.box_distance("person", Rect2(100, 100, 50, 200), 480, 480)
	check("pinhole distance 1.7 m × 480 / 200 px ≈ 4.1 m, not cut off", absf(d.d - 4.08) < 0.01 and not d.min, d)
	check("box touching frame edge → lower bound", PELogic.box_distance("person", Rect2(0, 0, 50, 480), 480, 480).min)
	var a := PELogic.pixel_angles(800, 240, [480.0, 480.0, 320.0, 240.0])
	check("pixel_angles: 480 px right at f=480 → 45°", absf(a.x - 45.0) < 0.01 and absf(a.y) < 0.01, a)
	# --- hands
	check("hands visible 2", PELogic.hands_visible(body()) == 2)
	var lm1 := body(); lm1[15] = Vector3(0.4, 0.5, 0.1); lm1[17] = Vector3(0, 0, 0); lm1[19] = Vector3(0, 0, 0); lm1[21] = Vector3(0, 0, 0)
	check("hands visible 1", PELogic.hands_visible(lm1) == 1)
	var ps := PELogic.PoseState.new()
	for i in 10: ps.update(body(true, true), 640, 480, i * 100.0)
	check("HANDS UP after hold ≥ 0.5 s", ps.tag == "HANDS UP", ps.tag)
	var ps2 := PELogic.PoseState.new(); ps2.update(body(true, true), 640, 480, 0); ps2.update(body(true, true), 640, 480, 300)
	check("not HANDS UP before hold time", ps2.tag == "", ps2.tag)
	var ps3 := PELogic.PoseState.new()
	for i in 10: ps3.update(body(true, false), 640, 480, i * 100.0)
	check("1 HAND UP", ps3.tag == "1 HAND UP", ps3.tag)
	# --- One Euro (same numbers as the web app's unit tests)
	var f := PELogic.OneEuro.new(); var rng := RandomNumberGenerator.new(); rng.seed = 3
	var raw := 0.0; var out := 0.0
	for i in 300:
		var n := (rng.randf() - 0.5) * 6.0; var y: float = f.filter(100.0 + n, i / 30.0)
		if i > 30: raw += absf(n); out += absf(y - 100.0)
	check("one-euro: >3× jitter reduction on still point", out * 3.0 < raw, out / raw)
	var f2 := PELogic.OneEuro.new(); var y2 := 0.0
	for i in 60: y2 = f2.filter(600.0 * i / 30.0, i / 30.0)
	check("one-euro: ≤14 px lag on 600 px/s ramp", 600.0 * 59 / 30 - y2 <= 14.0, 600.0 * 59 / 30 - y2)
	# --- pose tracker
	var T := PELogic.PoseTracker.new(); var ids := {}
	for i in 60: T.update([shift(body(), -0.3 + i * 0.01)], 720, 720, i * 33.0); ids[T.tracks[0].id] = true
	check("pose tracker: stable id while walking across", ids.size() == 1 and T.tracks.size() == 1, ids)
	var T2 := PELogic.PoseTracker.new()
	for i in 31:
		var pa := shift(body(), -0.3 + i * 0.02); var pb := shift(body(true, true), 0.3 - i * 0.02)
		T2.update([pa, pb] if i % 2 else [pb, pa], 720, 720, i * 33.0)
	var t1 = T2.tracks.filter(func(t): return t.id == 1)[0]
	check("pose tracker: crossing people keep ids", T2.tracks.size() == 2 and t1.lm[15].y < t1.lm[11].y and t1.lm[11].x < 0.5, t1.lm[11])
	var T3 := PELogic.PoseTracker.new(); T3.update([body()], 720, 720, 0); T3.update([body(), shift(body(), 0.4)], 720, 720, 33); var two := T3.tracks.size()
	T3.update([body()], 720, 720, 700)
	check("pose tracker: new person new id, gone after 600 ms", two == 2 and T3.tracks.size() == 1 and T3.tracks[0].id == 1)
	var T4 := PELogic.PoseTracker.new(); T4.min_cutoff = 50.0; T4.beta = 0.0
	for i in 20: T4.update([shift(body(), i * 0.01)], 720, 720, i * 33.0)
	var tr: Dictionary = T4.tracks[0]; var v: float = tr.vel[11].x
	check("pose tracker: prediction = velocity × dt, capped 150 ms", absf(T4.predict(tr, tr.t + 66)[11].x - tr.lm[11].x - v * 0.066) < 1e-6 and absf(T4.predict(tr, tr.t + 1000)[11].x - tr.lm[11].x - v * 0.15) < 1e-6, v)
	# --- detection tracker
	var D := PELogic.DetTracker.new()
	for i in 5: D.update([{"c": "person", "s": 0.9, "box": Rect2(100 + i * 4, 100, 50, 150)}], i * 66.0)
	check("det tracker: one confirmed track after 3+ hits", D.confirmed(5 * 66.0).size() == 1 and D.tracks[0].id == 1)
	D.update([], 2000.0)
	check("det tracker: dropped after 1.2 s unseen", D.tracks.is_empty())
	# person walking fast across the frame at 8 Hz with dropped frames keeps one id; a second person gets another id
	var D2 := PELogic.DetTracker.new(); var seen := {}
	for i in 40:
		if i % 5 == 3: continue  # missed detections
		var x := 40.0 + i * 13.0  # ~105 px/s at 8 Hz
		var ds := [{"c": "person", "s": 0.8, "box": Rect2(x, 120, 80, 220)}]
		if i > 10: ds.append({"c": "dog", "s": 0.7, "box": Rect2(600 - i * 5.0, 380, 90, 70)})
		D2.update(ds, i * 125.0)
		for t in D2.confirmed(i * 125.0): if t.c == "person": seen[t.id] = true
	check("det tracker: walking person keeps one id through missed frames", seen.size() == 1, seen)
	check("det tracker: pet tracked with its own id", D2.tracks.any(func(t): return t.c == "dog" and t.id != 1))
	# head turn: boxes jump 120 px between frames; compensation keeps the id
	var D3 := PELogic.DetTracker.new()
	for i in 3: D3.update([{"c": "person", "s": 0.9, "box": Rect2(300, 100, 60, 200)}], i * 100.0)
	D3.compensate(func(p: Vector2) -> Vector2: return p - Vector2(200, 0))
	D3.update([{"c": "person", "s": 0.9, "box": Rect2(100, 100, 60, 200)}], 300.0)
	check("det tracker: head-turn compensation keeps id", D3.tracks.size() == 1 and D3.tracks[0].id == 1, D3.tracks.size())
	# --- full app in demo mode (no XR): HUD state
	var main: Node3D = load("res://main.tscn").instantiate()
	main.S.demo = true
	root.add_child(main)
	await create_timer(3.0).timeout
	main.S.north_offset = 0.0; main.S.north_set = false
	var st: Dictionary = main.build_hud_state(Time.get_ticks_msec() * 1.0)
	check("app (demo): contacts confirmed with distance + bearing", st.contacts.size() >= 1 and st.contact_rows.any(func(r): return r.begins_with("PERSON") and "°" in r), st.contact_rows)
	check("v0.1.1: boxes only — no skeleton, no hands readout", st.skeletons.is_empty() and not ("HANDS" in st.counts) and not st.contacts.any(func(c): return "HANDS" in str(c.lines)), st.counts)
	check("v0.1.1: pose disabled in settings + plugin flag", main.S.pose == false and main.POSE_FEATURE == false)
	check("app (demo): no weapon classes anywhere", not ("knife" in str(st) or "gun" in str(st).to_lower() or "weapon" in str(st).to_lower()))
	main._handle_action("waypoint"); main._handle_action("clear")
	st = main.build_hud_state(Time.get_ticks_msec() * 1.0)
	check("waypoint + MARK CLEAR land on the minimap", st.waypoints.size() == 1 and st.rooms.size() == 1 and absf(st.waypoints[0].p.y - 3.0) < 0.01, st.waypoints)
	main.cam.rotate_y(deg_to_rad(-90))
	check("heading follows head yaw (turn right 90° → 090°)", absf(main.heading() - 90.0) < 0.5, main.heading())
	main.S.north_offset = -main._yaw_cw() + 0.0; main.S.north_offset = 0.0
	main._handle_action("menu"); for i in 6: main._handle_action("down")
	main._handle_action("select")
	check("settings: SET NORTH makes current heading 000°", absf(PELogic.ang_diff(0, main.heading())) < 0.5 and main.S.north_set, main.heading())
	main._handle_action("menu")
	# squad loopback: a fake member packet on the LAN port
	var peer := PacketPeerUDP.new(); peer.set_dest_address("127.0.0.1", main.SQUAD_PORT)
	peer.put_packet(JSON.stringify({"v": 1, "app": "pigeon-eye-quest", "id": "peer1", "cs": "FALCON", "p": [2.0, 1.6, -5.0], "wps": [["WP1", 4.0, -4.0]], "rooms": [["Room 1", 0.0, -2.0]]}).to_utf8_buffer())
	await create_timer(0.8).timeout
	st = main.build_hud_state(Time.get_ticks_msec() * 1.0)
	check("squad: member position + shared waypoint/room received over UDP", st.squad_members.size() == 1 and st.squad_members[0].cs == "FALCON" and st.waypoints.any(func(w): return w.name == "FALCON:WP1"), st.squad_members)
	# screenshot of the desktop HUD (only when a display/renderer is available)
	if DisplayServer.get_name() != "headless":
		main._handle_action("menu"); main._handle_action("menu")
		await create_timer(0.5).timeout
		var img: Image = main.hud_vp.get_texture().get_image()
		if img: img.save_png("res://../docs/shot_hud_demo.png"); print("saved docs/shot_hud_demo.png")
		main._handle_action("menu"); await create_timer(0.3).timeout
		img = main.hud_vp.get_texture().get_image()
		if img: img.save_png("res://../docs/shot_settings.png")
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
