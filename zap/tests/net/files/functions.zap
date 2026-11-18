type Kind = enum { Small, Medium, Large }

type Order = struct {
	dish: string.utf8(1..20),
	count: u8(1..9),
	extras: string.utf8(..12)[..4],
	kind: Kind,
}

funct Order = {
	call: Async,
	args: Order,
	rets: (boolean, u32?, string.utf8(..40)?),
}

funct Quote = {
	call: Sync,
	args: (dish: string.utf8(1..20), count: u8),
	rets: f64,
}

funct Nothing = {
	call: Async,
	args: (),
	rets: (),
}

namespace Shop = {
	funct Basket = {
		call: Async,
		args: (items: u16[..6]),
		rets: map { [u16]: u8 },
	}
}
