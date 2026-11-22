opt casing = "snake_case"
opt traffic_counters = true

event chat_sent = {
	from: Client,
	type: Reliable,
	call: ManyAsync,
	data: (channel: u8, text: string.utf8(..40)),
}

event aimed = {
	from: Client,
	type: OrderedUnreliable,
	call: SingleSync,
	data: vector(f32, f32, f32),
}

event announced = {
	from: Server,
	type: Reliable,
	call: ManySync,
	data: string.utf8(..30),
}

event waved = {
	from: Server,
	type: Unreliable,
	call: SingleAsync,
}

namespace board = {
	event scored = {
		from: Server,
		type: OrderedUnreliable,
		call: ManySync,
		data: struct { points: u16, label: string.binary(..10)? },
	}

	funct lookup = {
		call: Sync,
		args: u16,
		rets: string.utf8(..12)?,
	}
}

funct ping = {
	call: Async,
	args: (),
	rets: u8,
}
