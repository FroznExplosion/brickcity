class_name PartTransfer
extends RefCounted
## A part package from the host to a joining player, in chunks over the match's own
## connection (Docs/ModularParts.md section 7, stage 10). The netcode carries the offer and
## the chunks as they are; this side makes and checks them.
##
##     host:   var t := PartTransfer.offer(dir)        -> {id, hash, size, count}, chunks
##     client: var rx := PartTransfer.new(offer)       refuses an offer over the cap
##             rx.take(i, bytes) ... until rx.done()   any order, again is harmless
##             rx.finish(into)                         the hash checked, then imported
##
## The part is checked twice: the bytes against the hash the lobby gave (the host cannot
## swap the part for another), then as any package is (PartPackage.read: data only).

## The size of one chunk, and the most one transfer may be (a package's own cap).
const CHUNK := 32 * 1024
const MAX := PartPackage.MAX_PACKAGE

var offer: Dictionary
var why := ""
var _chunks: Array = []
var _got := 0


## What the host sends for the part in `dir`: {ok, offer: {id, rev, hash, size, count},
## chunks: [PackedByteArray]} or {ok: false, why}.
static func make_offer(dir: String) -> Dictionary:
	var p := PartPackage.pack(dir)
	if not p.ok:
		return p
	var bytes: PackedByteArray = p.bytes
	var chunks := []
	var i := 0
	while i < bytes.size():
		chunks.append(bytes.slice(i, mini(i + CHUNK, bytes.size())))
		i += CHUNK
	return {"ok": true, "chunks": chunks, "offer": {"id": p.id, "rev": p.rev, "hash": p.hash,
			"size": bytes.size(), "count": chunks.size()}}


## A client's side of one transfer. `expect_hash`: the hash the lobby said (the offer's must
## match it). Check `why` after: non-empty, it was refused.
func _init(p_offer: Dictionary, expect_hash: String = "") -> void:
	offer = p_offer
	var size := int(offer.get("size", -1))
	var count := int(offer.get("count", -1))
	if size <= 0 or size > MAX:
		why = "a package of %d bytes: %d at most" % [size, MAX]
	elif count != ceili(float(size) / CHUNK):
		why = "%d chunks for %d bytes" % [count, size]
	elif expect_hash != "" and String(offer.get("hash", "")) != expect_hash:
		why = "not the part the lobby named"
	else:
		_chunks.resize(count)


## Chunk `i` arrived. False if it is refused (out of range, the wrong size, refused offer).
func take(i: int, bytes: PackedByteArray) -> bool:
	if why != "" or i < 0 or i >= _chunks.size():
		return false
	var want := CHUNK if i < _chunks.size() - 1 else int(offer.size) - CHUNK * (_chunks.size() - 1)
	if bytes.size() != want:
		return false
	if _chunks[i] == null:
		_got += 1
	_chunks[i] = bytes
	return true


## How much is in, 0..1: the join screen's bar.
func progress() -> float:
	return float(_got) / maxf(_chunks.size(), 1)


func done() -> bool:
	return why == "" and _got == _chunks.size()


## The chunks it still waits for: what to ask again for.
func wanted() -> Array:
	var out := []
	for i in _chunks.size():
		if _chunks[i] == null:
			out.append(i)
	return out


## Put the part together, check it, and import it into `into`: PartPackage.import_file's
## answer, or {ok: false, why}.
func finish(into: String = PartCatalog.CUSTOM_DIR, official: PartCatalog = null) -> Dictionary:
	if not done():
		return {"ok": false, "why": why if why != "" else "%d chunks still to come" % wanted().size()}
	var bytes := PackedByteArray()
	for c in _chunks:
		bytes.append_array(c)
	var tmp := "user://.transfer_%s.%s" % [String(offer.hash).left(16), PartPackage.EXT]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "why": "cannot write the download"}
	f.store_buffer(bytes)
	f.close()
	var got := PartPackage.read(tmp)
	if got.ok and got.hash != String(offer.hash):
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "why": "what came is not the part offered"}
	var r := PartPackage.import_file(tmp, into, official) if got.ok else got
	DirAccess.remove_absolute(tmp)
	return r
