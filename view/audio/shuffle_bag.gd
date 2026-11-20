class_name ShuffleBag
extends RefCounted
## A shuffled round of indices: every index comes out once before any comes out
## again, and a new round never opens with the index that closed the last one.

var _size: int
var _order: Array[int] = []
var _at: int = 0
var _last: int = -1


func _init(size: int) -> void:
	_size = maxi(size, 1)
	_at = _size


func next(rng: RandomNumberGenerator) -> int:
	if _at >= _size:
		_refill(rng)
	var got: int = _order[_at]
	_at += 1
	_last = got
	return got


func _refill(rng: RandomNumberGenerator) -> void:
	_order.clear()
	for i: int in _size:
		_order.append(i)
	# Fisher-Yates with the caller's seeded generator.
	for i: int in range(_size - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var held: int = _order[i]
		_order[i] = _order[j]
		_order[j] = held
	# Don't open a round with the line that closed the last.
	if _size > 1 and _order[0] == _last:
		var swap: int = rng.randi_range(1, _size - 1)
		var held: int = _order[0]
		_order[0] = _order[swap]
		_order[swap] = held
	_at = 0
