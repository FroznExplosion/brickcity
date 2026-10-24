class_name SteamParts
extends RefCounted
## Steam Workshop for part packages (Docs/ModularParts.md section 7, stage 10), through
## GodotSteam's UGC calls when the game runs with it. Without it (today: GodotSteam is not
## in the project) every call says so and the host's download is the way a part comes.
##
## A published part keeps its item id beside it (PartLobby.STEAM_FILE), so the lobby can
## name it and a joining player subscribes instead of downloading from the host.


static func available() -> bool:
	return Engine.has_singleton("Steam")


static func _steam() -> Object:
	return Engine.get_singleton("Steam") if available() else null


## Subscribe to item `item` (it downloads in Steam's own time). False without Steam.
static func subscribe(item: int) -> bool:
	var s := _steam()
	if s == null or not s.has_method(&"subscribeItem"):
		return false
	s.call(&"subscribeItem", item)
	return true


## Where a subscribed item's files are once downloaded: its folder, or "" (not yet, or no
## Steam). Its .bcpart there is imported as any package: PartPackage.import_file.
static func installed_folder(item: int) -> String:
	var s := _steam()
	if s == null or not s.has_method(&"getItemInstallInfo"):
		return ""
	var info = s.call(&"getItemInstallInfo", item)
	return String(info.get("folder", "")) if info is Dictionary and info.get("ret", false) else ""


## Remember that the part in `dir` is Workshop item `item`.
static func keep_item(dir: String, item: int) -> Error:
	var f := FileAccess.open(dir + PartLobby.STEAM_FILE, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify({"item": item}))
	return OK
