@tool
extends EditorPlugin

var exp: PVExport

func _enter_tree() -> void:
	exp = PVExport.new(); add_export_plugin(exp)

func _exit_tree() -> void:
	remove_export_plugin(exp); exp = null

class PVExport extends EditorExportPlugin:
	func _get_name() -> String: return "PigeonVision"
	func _supports_platform(p: EditorExportPlatform) -> bool: return p is EditorExportPlatformAndroid
	func _get_android_libraries(p: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["pigeonvision/bin/pigeonvision-release.aar"])
	func _get_android_dependencies(p: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["com.google.mediapipe:tasks-vision:0.10.26"])
