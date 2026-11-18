type Kind = enum { Small, Large }

type Shape = enum "kind" {
	Circle { radius: f32 },
	Square { side: u16, filled: boolean },
}

type Item = struct {
	id: u16,
	name: string.utf8(..32),
	kind: Kind,
	tags: string.binary(..8)[..4],
	note: string.utf8(..16)?,
}

event Detailed = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: struct {
		count: u8,
		delta: i32,
		ratio: f64,
		active: boolean,
		items: Item[..8],
		scores: map { [string.utf8(..8)]: u32 },
		shape: Shape,
		position: vector(f32, f32, f32),
		part: Instance?,
		owner: Instance,
	},
}

event Pair = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: (label: string.utf8(..16), amount: u16),
}

event Ping = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: (),
}

event Moved = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: struct { x: f32, z: f32 },
}

event Ordered = {
	from: Server,
	type: OrderedUnreliable,
	call: ManyAsync,
	data: u16,
}

event Tick = {
	from: Server,
	type: OrderedUnreliable,
	call: ManyAsync,
	data: (),
}

namespace Nested = {
	event Note = {
		from: Server,
		type: Reliable,
		call: ManyAsync,
		data: string.utf8(..32),
	}
}
