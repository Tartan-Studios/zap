opt casing = "PascalCase"

type Kind = enum { Small, Medium, Large }

type Shape = enum "kind" {
	Circle { radius: f32(0..100) },
	Square { side: u16(1..500), filled: boolean },
	Empty {},
}

type Leaf = struct {
	id: u16,
	label: string.utf8(1..12),
	next: Leaf?,
}

type Item = struct {
	id: u32,
	name: string.utf8(..24),
	code: string.binary(4),
	kind: Kind,
	tags: string.binary(..6)[..3],
	note: string.utf8(..16)?,
	weight: f64(0..1000),
	slot: u8(1..9),
	offset: i16(-300..300),
	ratio: f32,
}

type Everything = struct {
	numbers: struct { a: u8, b: u16, c: u32, d: i8, e: i16, f: i32, g: f32, h: f64 },
	ranged: struct { a: u8(10..20), b: i32(-5..5), c: f64(-1..1), d: f32(0.5..2.5), e: u16(..1000) },
	text: struct { utf8: string.utf8(..40), binary: string.binary(..40), fixed: string.binary(3), sized: string.utf8(2..6) },
	bytes: struct { any: buffer(..32), fixed: buffer(5) },
	items: Item[..4],
	pair: u8[2],
	scores: map { [string.utf8(..10)]: u32 },
	byKind: map { [Kind]: boolean },
	seen: set { string.utf8(..8) },
	shape: Shape,
	shapes: Shape[..3],
	leaf: Leaf,
	maybe: Item?,
	flag: boolean,
	flags: boolean[..9],
	position: vector(f32, f32, f32),
	flat: vector(i16, i16),
	color: Color3,
	brick: BrickColor,
	point: Vector3,
	place: Vector2,
	frame: CFrame,
	aligned: AlignedCFrame,
	stamp: DateTime,
	stampMillis: DateTimeMillis,
	part: Instance.Part,
	anything: Instance,
	maybePart: Instance.Part?,
	choice: (string.binary(..8) | u16 | boolean),
	maybeChoice: (Kind | Instance.Model)?,
	unknownValue: unknown,
}

event Everything = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: Everything,
}

event Tuple = {
	from: Server,
	type: Reliable,
	call: ManySync,
	data: (count: u8, label: string.utf8(..12), maybe: Kind?, items: Item[..2]),
}

event Ping = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: (),
}

event Moved = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: struct { x: f32, z: f32, kind: Kind },
}

event Ordered = {
	from: Server,
	type: OrderedUnreliable,
	call: SingleAsync,
	data: (sequence: u16, shape: Shape),
}

event Polled = {
	from: Server,
	type: Reliable,
	call: Polling,
	data: (label: string.utf8(..12), amount: u32),
}

namespace Deep = {
	namespace Deeper = {
		event Note = {
			from: Server,
			type: Reliable,
			call: ManyAsync,
			data: struct { id: u16, label: string.utf8(1..12) },
		}
	}
}
