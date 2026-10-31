## PIGEON EYE — pure logic (no scene/XR dependencies; unit-tested headless in tests/run_tests.gd).
## Ported from the iPhone web app (js/poselogic.js v1.3.0, js/detectors.js tracking ideas).
## Landmarks: Array of 33 Vector3(x, y, visibility), x/y normalised to [0,1] of the camera frame.
class_name PELogic
extends RefCounted

const EDGES := [[11, 12], [11, 13], [13, 15], [12, 14], [14, 16], [15, 17], [15, 19], [15, 21], [16, 18], [16, 20], [16, 22], [11, 23], [12, 24], [23, 24], [23, 25], [25, 27], [24, 26], [26, 28], [27, 29], [29, 31], [28, 30], [30, 32]]
const CFG := {"vis_min": 0.5, "up_on": 0.30, "up_off": 0.12, "hold_on_ms": 500.0, "hold_off_ms": 350.0, "shoulder_m": 0.40}
const HEIGHTS := {"person": 1.70, "dog": 0.55, "cat": 0.25, "horse": 1.6, "sheep": 0.8, "cow": 1.4, "bird": 0.2, "bear": 1.0}
const ANIMALS := ["dog", "cat", "horse", "sheep", "cow", "bird", "bear"]

static func vis(p, t: float = -1.0) -> bool:
	if p == null: return false
	var th: float = CFG.vis_min if t < 0.0 else t
	return p.z >= th and p.x >= -0.02 and p.x <= 1.02 and p.y >= -0.02 and p.y <= 1.02

static func bbox(lm: Array, w: float, h: float) -> Rect2:
	var x0 := 1e9; var y0 := 1e9; var x1 := -1e9; var y1 := -1e9
	for p in lm:
		if not vis(p, 0.3): continue
		x0 = min(x0, p.x * w); y0 = min(y0, p.y * h); x1 = max(x1, p.x * w); y1 = max(y1, p.y * h)
	if x1 < x0: return Rect2()
	return Rect2(x0, y0, x1 - x0, y1 - y0)

static func hands_visible(lm: Array) -> int:
	var n := 0
	for s in [[15, 17, 19, 21], [16, 18, 20, 22]]:
		for i in s:
			if vis(lm[i]): n += 1; break
	return n

static func hands_text(n: int) -> String:
	return "2 visible" if n == 2 else ("1 visible" if n == 1 else "not visible")

## Arm raise score: (shoulderY - wristY) / shoulder width in px. NAN if unknown.
static func raise_score(lm: Array, left: bool, w: float, h: float) -> float:
	var sh = lm[11 if left else 12]; var wr = lm[15 if left else 16]; var a = lm[11]; var b = lm[12]
	if not vis(sh) or not vis(wr) or not vis(a, 0.3) or not vis(b, 0.3): return NAN
	var sw := Vector2((a.x - b.x) * w, (a.y - b.y) * h).length()
	if sw < 4.0: return NAN
	return (sh.y - wr.y) * h / sw

static func shoulder_distance(lm: Array, w: float, h: float, focal: float) -> float:
	var a = lm[11]; var b = lm[12]
	if not vis(a) or not vis(b): return NAN
	var px := Vector2((a.x - b.x) * w, (a.y - b.y) * h).length()
	return NAN if px < 6.0 else CFG.shoulder_m * focal / px

## Pinhole distance from box height; cut-off boxes (touching the frame edge) give a lower bound.
static func box_distance(cls: String, box: Rect2, focal_y: float, img_h: float) -> Dictionary:
	var hm: float = HEIGHTS.get(cls, 1.0)
	var d: float = hm * focal_y / maxf(box.size.y, 1.0)
	var cut := box.position.y <= 2.0 or box.end.y >= img_h - 2.0
	return {"d": d, "min": cut}

static func iou(a: Rect2, b: Rect2) -> float:
	var i := a.intersection(b)
	var ia := i.size.x * i.size.y if a.intersects(b) else 0.0
	return ia / (a.size.x * a.size.y + b.size.x * b.size.y - ia + 1e-9)

static func wrap360(d: float) -> float:
	return fposmod(d, 360.0)

## Shortest signed difference b - a in degrees (-180, 180].
static func ang_diff(a: float, b: float) -> float:
	return fposmod(b - a + 180.0, 360.0) - 180.0

static func cardinal(d: float) -> String:
	return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][int(floor(wrap360(d) / 45.0 + 0.5)) % 8]

## Pixel → (yaw, pitch) offset in degrees from the camera axis, using intrinsics [fx, fy, cx, cy].
static func pixel_angles(px: float, py: float, intr: Array) -> Vector2:
	return Vector2(rad_to_deg(atan((px - intr[2]) / intr[0])), rad_to_deg(atan((py - intr[3]) / intr[1])))


## One Euro filter (Casiez et al. 2012): low jitter when still, low lag when moving.
class OneEuro:
	var min_cutoff: float; var beta: float; var d_cutoff: float
	var x = null; var dx := 0.0; var t := 0.0
	func _init(mc: float = 0.8, b: float = 0.008, dc: float = 1.0) -> void:
		min_cutoff = mc; beta = b; d_cutoff = dc
	static func _alpha(cutoff: float, dt: float) -> float:
		var tau := 1.0 / (TAU * cutoff); return 1.0 / (1.0 + tau / dt)
	func filter(v: float, t_sec: float) -> float:
		if x == null: x = v; dx = 0.0; t = t_sec; return v
		var dt: float = max(1e-3, t_sec - t); t = t_sec
		var d: float = (v - x) / dt
		dx += _alpha(d_cutoff, dt) * (d - dx)
		var cutoff := min_cutoff + beta * absf(dx)
		x += _alpha(cutoff, dt) * (v - x)
		return x


## Hands-up hysteresis + hold time (upper body only, so it works crouched).
class PoseState:
	var arm := {"l": {"up": false, "since": -1.0, "score": NAN}, "r": {"up": false, "since": -1.0, "score": NAN}}
	var hands := 0; var hands_up := 0; var tag := ""
	func update(lm: Array, w: float, h: float, now_ms: float) -> PoseState:
		for s in ["l", "r"]:
			var r := PELogic.raise_score(lm, s == "l", w, h)
			var st: Dictionary = arm[s]
			var want: bool = (not (is_nan(r) or r < PELogic.CFG.up_off)) if st.up else (not is_nan(r) and r > PELogic.CFG.up_on)
			if want != st.up:
				if st.since < 0.0: st.since = now_ms
				if now_ms - st.since >= (PELogic.CFG.hold_on_ms if want else PELogic.CFG.hold_off_ms):
					st.up = want; st.since = -1.0
			else:
				st.since = -1.0
			st.score = r
		hands_up = int(arm.l.up) + int(arm.r.up)
		tag = "HANDS UP" if hands_up == 2 else ("1 HAND UP" if hands_up == 1 else "")
		hands = PELogic.hands_visible(lm)
		return self


## Pose identity tracking frame-to-frame: greedy match on (1-IoU) + centroid + landmark distance; One Euro per
## coordinate; velocity for prediction between pose frames.
class PoseTracker:
	var max_miss_ms := 600.0; var gate := 1.6; var tracks: Array = []; var next_id := 1
	var min_cutoff := 0.8; var beta := 0.008

	static func centroid(lm: Array, w: float, h: float):
		var s := Vector2.ZERO; var n := 0
		for i in [11, 12, 23, 24, 0]:
			if PELogic.vis(lm[i], 0.3): s += Vector2(lm[i].x * w, lm[i].y * h); n += 1
		if n == 0:
			var b := PELogic.bbox(lm, w, h)
			return null if b.size == Vector2.ZERO else b.get_center()
		return s / n

	static func lm_dist(a: Array, b: Array, w: float, h: float) -> float:
		var s := 0.0; var n := 0
		for i in 33:
			if PELogic.vis(a[i], 0.4) and PELogic.vis(b[i], 0.4):
				s += Vector2((a[i].x - b[i].x) * w, (a[i].y - b[i].y) * h).length(); n += 1
		return s / n if n else INF

	func update(poses: Array, w: float, h: float, t_ms: float) -> Array:
		var dets := []
		for lm in poses:
			var b := PELogic.bbox(lm, w, h); var c = centroid(lm, w, h)
			if b.size != Vector2.ZERO and c != null: dets.append({"lm": lm, "box": b, "c": c})
		var pairs := []
		for i in tracks.size():
			var tr: Dictionary = tracks[i]; var pred := predict(tr, t_ms)
			for j in dets.size():
				var d: Dictionary = dets[j]; var bd: float = max(tr.box.size.length(), 1.0)
				var cost: float = (1.0 - PELogic.iou(tr.box, d.box)) + (tr.c - d.c).length() / bd + min(2.0, lm_dist(pred, d.lm, w, h) / bd)
				if cost < gate: pairs.append([cost, i, j])
		pairs.sort_custom(func(a, b): return a[0] < b[0])
		var ut := {}; var ud := {}
		for p in pairs:
			if ut.has(p[1]) or ud.has(p[2]): continue
			ut[p[1]] = true; ud[p[2]] = true; _absorb(tracks[p[1]], dets[p[2]], w, h, t_ms)
		for j in dets.size():
			if ud.has(j): continue
			var tr := {"id": next_id, "filters": [], "hits": 0, "state": PoseState.new(), "vel": [], "lm": [], "t": -1.0}
			next_id += 1; _absorb(tr, dets[j], w, h, t_ms); tracks.append(tr)
		tracks = tracks.filter(func(tr): return t_ms - tr.t <= max_miss_ms)
		return tracks

	func _absorb(tr: Dictionary, d: Dictionary, w: float, h: float, t_ms: float) -> void:
		var ts := t_ms / 1000.0; var prev: Array = tr.lm
		var dt: float = max(1e-3, (t_ms - tr.t) / 1000.0) if tr.t >= 0.0 else 0.0
		var out := []
		for i in d.lm.size():
			if tr.filters.size() <= i: tr.filters.append([OneEuro.new(min_cutoff, beta), OneEuro.new(min_cutoff, beta)])
			var p: Vector3 = d.lm[i]
			out.append(Vector3(tr.filters[i][0].filter(p.x * w, ts) / w, tr.filters[i][1].filter(p.y * h, ts) / h, p.z))
		var vel := []
		for i in out.size():
			vel.append(Vector2((out[i].x - prev[i].x) / dt, (out[i].y - prev[i].y) / dt) if prev.size() == out.size() and dt > 0.0 else Vector2.ZERO)
		tr.lm = out; tr.vel = vel; tr.box = d.box; tr.c = d.c; tr.t = t_ms; tr.hits += 1
		tr.state.update(out, w, h, t_ms)

	## Landmarks extrapolated to t_ms with the last velocity (max 150 ms ahead).
	func predict(tr: Dictionary, t_ms: float) -> Array:
		var dt := clampf((t_ms - tr.t) / 1000.0, 0.0, 0.15)
		if dt == 0.0 or tr.vel.is_empty(): return tr.lm
		var out := []
		for i in tr.lm.size(): out.append(Vector3(tr.lm[i].x + tr.vel[i].x * dt, tr.lm[i].y + tr.vel[i].y * dt, tr.lm[i].z))
		return out


## Detection tracker (v0.1.1): IDs persist while people/pets move. Each track keeps a constant-velocity box model;
## association is greedy on (1 - IoU) + centre distance / box size against the *predicted* box, same class only.
## Head rotation between frames is removed by the caller via compensate(). Confirmed after 2 hits; a track survives
## 1.2 s without detections (brief occlusion / missed frames) and is shown for 0.5 s after its last hit.
class DetTracker:
	var tracks: Array = []; var next_id := 1; var confirm_hits := 2; var max_miss_ms := 1200.0; var show_ms := 500.0; var gate := 1.4

	func _pred(tr: Dictionary, t_ms: float) -> Rect2:
		var dt := clampf((t_ms - tr.t) / 1000.0, 0.0, 0.5)
		return Rect2(tr.box.position + tr.v * dt, tr.box.size)

	## Shift every track by a function px -> px (e.g. head-rotation compensation between camera frames).
	func compensate(f: Callable) -> void:
		for tr in tracks:
			var c: Vector2 = f.call(tr.box.get_center())
			tr.box = Rect2(c - tr.box.size / 2.0, tr.box.size)

	func update(dets: Array, t_ms: float) -> Array:
		var pairs := []
		for i in tracks.size():
			var pb := _pred(tracks[i], t_ms)
			var sz: float = maxf(pb.size.length(), 1.0)
			for j in dets.size():
				if tracks[i].c != dets[j].c: continue
				var cost: float = (1.0 - PELogic.iou(pb, dets[j].box)) + (pb.get_center() - dets[j].box.get_center()).length() / sz
				if cost < gate: pairs.append([cost, i, j])
		pairs.sort_custom(func(a, b): return a[0] < b[0])
		var ut := {}; var ud := {}
		for p in pairs:
			if ut.has(p[1]) or ud.has(p[2]): continue
			ut[p[1]] = true; ud[p[2]] = true
			var tr: Dictionary = tracks[p[1]]; var d: Dictionary = dets[p[2]]
			var dt: float = maxf((t_ms - tr.t) / 1000.0, 1e-3)
			var nv: Vector2 = (d.box.get_center() - tr.box.get_center()) / dt
			tr.v = tr.v.lerp(nv, 0.5).limit_length(2000.0)
			tr.box = Rect2(tr.box.position.lerp(d.box.position, 0.7), tr.box.size.lerp(d.box.size, 0.6))
			tr.s = d.s; tr.t = t_ms; tr.hits += 1
		for j in dets.size():
			if ud.has(j): continue
			tracks.append({"id": next_id, "c": dets[j].c, "box": dets[j].box, "s": dets[j].s, "t": t_ms, "hits": 1, "v": Vector2.ZERO})
			next_id += 1
		tracks = tracks.filter(func(tr): return t_ms - tr.t <= max_miss_ms)
		return tracks

	func confirmed(t_ms: float) -> Array:
		return tracks.filter(func(tr): return tr.hits >= confirm_hits and t_ms - tr.t <= show_ms)
