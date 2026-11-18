opt casing = "snake_case"
opt disable_fire_all = true
opt disable_fire_except = true
opt disable_fire_set = true

event score_changed = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: (score: u32, delta: i16),
}

event button_pressed = {
	from: Client,
	type: Reliable,
	call: ManyAsync,
	data: (button: enum { a, b, x, y }, held: boolean),
}

funct ask = {
	call: Async,
	args: string.utf8(..20),
	rets: string.utf8(..20),
}
