opt casing = "camelCase"
opt max_client_events_per_frame = 32

event Tap = {
	from: Client,
	type: Reliable,
	call: ManyAsync,
}

event Steer = {
	from: Client,
	type: Unreliable,
	call: ManySync,
	data: u8,
}
