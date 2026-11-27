opt disable_fire_except = true
opt disable_fire_set = true
opt max_client_packet_bytes = 4096
opt max_client_events_per_frame = 128
opt traffic_counters = true

type Kind = enum { Small, Large }

event Scored = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: struct { points: u16, kind: Kind, note: string.utf8(..20)? },
}

event Moved = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: (x: f32, z: f32),
}

event Pressed = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: Kind,
}

event Polled = {
	from: Client,
	type: Reliable,
	call: Polling,
	data: (label: string.utf8(..10)),
}

funct Buy = {
	call: Async,
	args: (item: string.utf8(..20), count: u8),
	rets: (boolean, u32?),
}
