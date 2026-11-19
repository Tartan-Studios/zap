opt max_client_packet_bytes = 1024
opt max_client_events_per_frame = 64

event Tap = {
	from: Client,
	type: Reliable,
	call: ManySync,
}

event Aim = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: struct { x: i16, y: i16, label: string.utf8(..8) },
}

event Steer = {
	from: Client,
	type: Unreliable,
	call: SingleSync,
	data: u16,
}

event Look = {
	from: Client,
	type: OrderedUnreliable,
	call: Polling,
	data: (pitch: i8, yaw: i8),
}

event Score = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: u32,
}

funct Ask = {
	call: Sync,
	args: u8,
	rets: u8,
}
