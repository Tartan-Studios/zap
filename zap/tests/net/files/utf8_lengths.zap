type Profile = struct {
	name: string.utf8(3..20),
	code: string.utf8(5),
}

event Chat = {
	from: Client,
	type: Reliable,
	call: ManyAsync,
	data: string.utf8(..16),
}

event Rename = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: (name: string.utf8(3..20), code: string.utf8(5)),
}

event Shout = {
	from: Client,
	type: Unreliable,
	call: SingleSync,
	data: string.utf8(1..4),
}

event Profile = {
	from: Client,
	type: Reliable,
	call: SingleSync,
	data: Profile,
}

event Echo = {
	from: Server,
	type: Reliable,
	call: ManySync,
	data: (text: string.utf8(..16), raw: string.binary(..16)),
}
