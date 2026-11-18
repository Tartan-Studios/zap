opt casing = "camelCase"

event scoreChanged = {
	from: Server,
	type: OrderedUnreliable,
	call: SingleSync,
	data: (score: u32, delta: i16),
}

event buttonPressed = {
	from: Client,
	type: Reliable,
	call: Polling,
	data: (button: enum { A, B }, held: boolean),
}
