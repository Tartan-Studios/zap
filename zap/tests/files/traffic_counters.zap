opt traffic_counters = true
opt max_client_packet_bytes = 1024
opt max_client_events_per_frame = 64

event FoodOrdered = {
	from: Client,
	type: Reliable,
	call: ManySync,
	data: struct { dish: string.utf8(..16), count: u8 },
}

event Waved = {
	from: Client,
	type: Reliable,
	call: SingleSync,
}

event Steered = {
	from: Client,
	type: Unreliable,
	call: SingleSync,
	data: u16,
}

event Looked = {
	from: Client,
	type: OrderedUnreliable,
	call: Polling,
	data: (pitch: i8, yaw: i8),
}

event Scored = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: u32,
}

event Moved = {
	from: Server,
	type: Unreliable,
	call: ManySync,
	data: (x: f32, z: f32),
}

event Tracked = {
	from: Server,
	type: OrderedUnreliable,
	call: SingleSync,
	data: u8,
}

funct Ask = {
	call: Sync,
	args: u8,
	rets: u8,
}

funct Buy = {
	call: Async,
	args: (item: string.utf8(..20), count: u8),
	rets: (boolean, u32?),
}

namespace Shop = {
	event Opened = {
		from: Server,
		type: Reliable,
		call: SingleSync,
		data: string.utf8(..12),
	}

	event Browsed = {
		from: Client,
		type: Reliable,
		call: SingleAsync,
		data: u8,
	}
}
