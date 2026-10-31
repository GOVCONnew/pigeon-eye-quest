package com.govconnew.pigeonvision

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject

/**
 * PIGEON EYE vision plugin for Meta Quest 3.
 * Opens a headset passthrough camera through the Passthrough Camera API, which is plain Android Camera2 on
 * Horizon OS v74+ and needs horizonos.permission.HEADSET_CAMERA. Runs MediaPipe EfficientDet-Lite0 (people and
 * animals only, no weapon/object classes) and Pose Landmarker lite on-device. Results go to Godot as JSON.
 * Nothing leaves the headset.
 */
class PigeonVision(godot: Godot) : GodotPlugin(godot) {
    companion object {
        const val TAG = "PigeonVision"
        const val HEADSET_CAMERA = "horizonos.permission.HEADSET_CAMERA"
        val KEEP = setOf("person", "dog", "cat", "horse", "sheep", "cow", "bird", "bear")
        private val META_SOURCE = CameraCharacteristics.Key("com.meta.extra_metadata.camera_source", Int::class.java)
        private val META_POSITION = CameraCharacteristics.Key("com.meta.extra_metadata.position", Int::class.java)
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var detector: ObjectDetector? = null
    private var pose: PoseLandmarker? = null
    @Volatile private var poseOn = true
    @Volatile private var busy = false
    @Volatile private var minIntervalMs = 0L
    private var lastRun = 0L
    private var status = "idle"
    private var intr = doubleArrayOf(0.0, 0.0, 0.0, 0.0)
    private var camW = 640; private var camH = 480
    private var bmp: Bitmap? = null
    private var px: IntArray? = null
    private var frames = 0L

    override fun getPluginName() = "PigeonVision"
    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("vision_result", String::class.java),
        SignalInfo("vision_status", String::class.java))

    private fun setStatus(s: String) { status = s; Log.i(TAG, s); emitSignal("vision_status", s) }

    @UsedByGodot fun getStatus(): String = status
    @UsedByGodot fun setPoseEnabled(on: Boolean) { poseOn = on }
    /** 0 = every frame; e.g. 100 = at most 10 Hz (low-power mode). */
    @UsedByGodot fun setMinIntervalMs(ms: Int) { minIntervalMs = ms.toLong() }

    @UsedByGodot fun hasPermission(): Boolean {
        val a = activity ?: return false
        return a.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
            a.checkSelfPermission(HEADSET_CAMERA) == PackageManager.PERMISSION_GRANTED
    }
    @UsedByGodot fun requestPermission() { activity?.requestPermissions(arrayOf(Manifest.permission.CAMERA, HEADSET_CAMERA), 4711) }

    /** Lists cameras with Meta metadata: diagnostics for the settings screen. */
    @UsedByGodot fun listCameras(): String {
        val cm = activity?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return "[]"
        val arr = JSONArray()
        for (id in cm.cameraIdList) {
            val c = cm.getCameraCharacteristics(id)
            arr.put(JSONObject().put("id", id).put("source", runCatching { c.get(META_SOURCE) }.getOrNull() ?: -1)
                .put("position", runCatching { c.get(META_POSITION) }.getOrNull() ?: -1))
        }
        return arr.toString()
    }

    private var asked = false
    @UsedByGodot fun start(): Boolean {
        val a = activity ?: return false
        if (!hasPermission()) {
            setStatus("waiting for camera permission")
            if (!asked) { asked = true; a.runOnUiThread { requestPermission() } }
            return false
        }
        if (thread != null) { if (status.startsWith("RUNNING") || status.startsWith("opening") || status == "loading models") return true; stop() }
        thread = HandlerThread("pigeonvision").also { it.start() }
        handler = Handler(thread!!.looper)
        handler!!.post { try { open(a) } catch (e: Throwable) { setStatus("CAMERA ERROR: ${e.message}") } }
        return true
    }

    override fun onMainRequestPermissionsResult(requestCode: Int, permissions: Array<String>?, grantResults: IntArray?) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults)
        if (hasPermission()) start() else setStatus("CAMERA PERMISSION DENIED — Settings › Privacy › App permissions")
    }

    @UsedByGodot fun stop() {
        runCatching { session?.close() }; runCatching { device?.close() }; runCatching { reader?.close() }
        session = null; device = null; reader = null
        thread?.quitSafely(); thread = null; handler = null
        setStatus("stopped")
    }

    private fun models(a: Context) {
        if (detector == null) detector = ObjectDetector.createFromOptions(a, ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("efficientdet_lite0_float16.tflite").build())
            .setRunningMode(RunningMode.VIDEO).setScoreThreshold(0.35f).setMaxResults(12)
            .setCategoryAllowlist(KEEP.toList()).build())
        if (pose == null) pose = PoseLandmarker.createFromOptions(a, PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("pose_landmarker_lite.task").build())
            .setRunningMode(RunningMode.VIDEO).setNumPoses(4).setMinPoseDetectionConfidence(0.5f).build())
    }

    @Suppress("MissingPermission")
    private fun open(a: Context) {
        setStatus("loading models")
        models(a)
        val cm = a.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        // Prefer passthrough camera (source 0) on the left (position 0); fall back to the first camera.
        var pick: String? = null
        for (id in cm.cameraIdList) {
            val c = cm.getCameraCharacteristics(id)
            val src = runCatching { c.get(META_SOURCE) }.getOrNull(); val pos = runCatching { c.get(META_POSITION) }.getOrNull()
            if (src == 0 && (pick == null || pos == 0)) pick = id
        }
        if (pick == null) pick = cm.cameraIdList.firstOrNull()
        if (pick == null) { setStatus("NO PASSTHROUGH CAMERA (Horizon OS v74+ needed)"); return }
        val ch = cm.getCameraCharacteristics(pick)
        val sizes = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.YUV_420_888)
        val sz = sizes?.minByOrNull { Math.abs(it.width - 640) + Math.abs(it.height - 480) }
        if (sz != null) { camW = sz.width; camH = sz.height }
        val k = ch.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
        val full = ch.get(CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE)
        if (k != null && k.size >= 4 && full != null && full.width() > 0) {
            val sx = camW.toDouble() / full.width(); val sy = camH.toDouble() / full.height()
            intr = doubleArrayOf(k[0] * sx, k[1] * sy, k[2] * sx, k[3] * sy)
        } else intr = doubleArrayOf(camW * 0.75, camW * 0.75, camW / 2.0, camH / 2.0) // ~67° HFOV fallback
        reader = ImageReader.newInstance(camW, camH, ImageFormat.YUV_420_888, 2).also { r ->
            r.setOnImageAvailableListener({ onImage(it) }, handler)
        }
        setStatus("opening camera $pick")
        cm.openCamera(pick, object : CameraDevice.StateCallback() {
            override fun onOpened(d: CameraDevice) {
                device = d
                d.createCaptureSession(listOf(reader!!.surface), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s
                        val rq = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(reader!!.surface) }
                        s.setRepeatingRequest(rq.build(), null, handler)
                        setStatus("RUNNING cam $pick ${camW}x$camH")
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) { setStatus("CAMERA SESSION FAILED") }
                }, handler)
            }
            override fun onDisconnected(d: CameraDevice) { d.close(); device = null; setStatus("camera disconnected (retrying)") }
            override fun onError(d: CameraDevice, e: Int) { d.close(); device = null; setStatus("CAMERA ERROR $e (retrying)") }
        }, handler)
    }

    private fun onImage(r: ImageReader) {
        val img = r.acquireLatestImage() ?: return
        val now = SystemClock.uptimeMillis()
        if (busy || now - lastRun < minIntervalMs) { img.close(); return }
        busy = true; lastRun = now
        try {
            val b = yuvToBitmap(img); img.close()
            val t0 = SystemClock.uptimeMillis()
            val mp = BitmapImageBuilder(b).build()
            val det = detector!!.detectForVideo(mp, now)
            val out = JSONObject().put("t", now).put("w", camW).put("h", camH)
                .put("intr", JSONArray(intr.toList()))
            val dets = JSONArray(); var persons = 0
            for (d in det.detections()) {
                val c = d.categories().firstOrNull() ?: continue
                if (c.categoryName() !in KEEP) continue
                if (c.categoryName() == "person") persons++
                val bb = d.boundingBox()
                dets.put(JSONObject().put("c", c.categoryName()).put("s", c.score().toDouble())
                    .put("x", bb.left.toDouble()).put("y", bb.top.toDouble()).put("w", bb.width().toDouble()).put("h", bb.height().toDouble()))
            }
            out.put("dets", dets)
            val poses = JSONArray()
            if (poseOn && persons > 0) {
                val pr = pose!!.detectForVideo(mp, now)
                for (lm in pr.landmarks()) {
                    val one = JSONArray()
                    for (p in lm) one.put(JSONArray(listOf(p.x().toDouble(), p.y().toDouble(), (p.visibility().orElse(1f)).toDouble())))
                    poses.put(one)
                }
            }
            out.put("poses", poses).put("ms", SystemClock.uptimeMillis() - t0)
            frames++
            emitSignal("vision_result", out.toString())
        } catch (e: Throwable) {
            Log.e(TAG, "frame", e); runCatching { img.close() }
        } finally { busy = false }
    }

    /** YUV_420_888 → ARGB (BT.601), plain Kotlin; 640×480 ≈ 5–10 ms on Quest 3. */
    private fun yuvToBitmap(img: android.media.Image): Bitmap {
        val w = img.width; val h = img.height
        if (bmp == null || bmp!!.width != w || bmp!!.height != h) { bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888); px = IntArray(w * h) }
        val yP = img.planes[0]; val uP = img.planes[1]; val vP = img.planes[2]
        val yB = yP.buffer; val uB = uP.buffer; val vB = vP.buffer
        val ys = yP.rowStride; val us = uP.rowStride; val ups = uP.pixelStride; val vs = vP.rowStride; val vps = vP.pixelStride
        val o = px!!
        for (j in 0 until h) {
            val yr = j * ys; val ur = (j shr 1) * us; val vr = (j shr 1) * vs
            for (i in 0 until w) {
                val y = (yB.get(yr + i).toInt() and 0xff) - 16
                val u = (uB.get(ur + (i shr 1) * ups).toInt() and 0xff) - 128
                val v = (vB.get(vr + (i shr 1) * vps).toInt() and 0xff) - 128
                val yy = 1192 * (if (y < 0) 0 else y)
                var r = (yy + 1634 * v) shr 10; var g = (yy - 833 * v - 400 * u) shr 10; var bl = (yy + 2066 * u) shr 10
                r = r.coerceIn(0, 255); g = g.coerceIn(0, 255); bl = bl.coerceIn(0, 255)
                o[j * w + i] = (0xff shl 24) or (r shl 16) or (g shl 8) or bl
            }
        }
        bmp!!.setPixels(o, 0, w, 0, 0, w, h)
        return bmp!!
    }
}
