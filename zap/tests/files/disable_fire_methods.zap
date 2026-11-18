opt disable_fire_all = true
opt disable_fire_except = true
opt disable_fire_set = true

event Reliable = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: struct { count: u8, name: string.utf8(..16) },
}

event Unreliable = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: u16,
}

event FromClient = {
	from: Client,
	type: Reliable,
	call: ManyAsync,
	data: boolean,
}
