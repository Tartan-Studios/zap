const EVENTS: &str = r#"
event Reliable = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: struct { count: u8 },
}

event Unreliable = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: u16,
}
"#;

struct Generated {
	server: String,
	defs: String,
}

fn generate(opts: &str) -> Generated {
	let script = zap::run(&format!("opt typescript = true\n{opts}\n{EVENTS}"), true);
	let server = script.code.expect("Zap did not generate any code!").server;

	Generated {
		server: server.code,
		defs: server.defs.expect("Zap did not generate TypeScript definitions!"),
	}
}

fn count(haystack: &str, needle: &str) -> usize {
	haystack.matches(needle).count()
}

fn assert_generated(generated: &Generated, method: &str) {
	let events = 2;

	assert_eq!(
		count(&generated.server, &format!("\t{method} = function(")),
		events,
		"{method}"
	);
	assert_eq!(
		count(&generated.server, &format!("\t{method} = noop")),
		events,
		"{method} studio stub"
	);
	assert_eq!(
		count(&generated.defs, &format!("\t{method}: (")),
		events,
		"{method} definition"
	);
}

#[test]
fn every_fire_method_is_generated_by_default() {
	let generated = generate("");

	for method in ["Fire", "FireAll", "FireExcept", "FireList", "FireSet"] {
		assert_generated(&generated, method);
	}
}

#[test]
fn disabled_fire_methods_are_left_out() {
	let generated = generate("opt disable_fire_except = true\nopt disable_fire_set = true");

	for method in ["FireExcept", "FireSet"] {
		assert_eq!(count(&generated.server, method), 0, "{method}");
		assert_eq!(count(&generated.defs, method), 0, "{method} definition");
	}

	for method in ["Fire", "FireAll", "FireList"] {
		assert_generated(&generated, method);
	}
}

#[test]
fn each_option_only_removes_its_own_method() {
	let except = generate("opt disable_fire_except = true");
	assert_eq!(count(&except.server, "FireExcept"), 0);
	assert_eq!(count(&except.server, "\tFireSet = function("), 2);

	let set = generate("opt disable_fire_set = true");
	assert_eq!(count(&set.server, "FireSet"), 0);
	assert_eq!(count(&set.server, "\tFireExcept = function("), 2);
}

#[test]
fn the_options_only_remove_code() {
	let default = generate("");
	let disabled = generate("opt disable_fire_all = true\nopt disable_fire_except = true\nopt disable_fire_set = true");

	let mut remaining = default.server.lines().filter(|line| !line.is_empty());
	for line in disabled.server.lines().filter(|line| !line.is_empty()) {
		assert!(
			remaining.any(|kept| kept == line),
			"the disabled output has a line the default output lacks: {line}"
		);
	}
}
