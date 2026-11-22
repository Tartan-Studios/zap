const EVENTS: &str = r#"
event Tap = {
	from: Client,
	type: Reliable,
	call: ManySync,
	data: u8,
}

event Steer = {
	from: Client,
	type: OrderedUnreliable,
	call: SingleSync,
	data: u16,
}

event Score = {
	from: Server,
	type: Reliable,
	call: ManyAsync,
	data: u32,
}

event Wind = {
	from: Server,
	type: Unreliable,
	call: ManyAsync,
	data: f32,
}

namespace Shop = {
	event Opened = {
		from: Server,
		type: Reliable,
		call: SingleSync,
		data: u8,
	}

	funct Price = {
		call: Sync,
		args: u8,
		rets: u16,
	}
}

funct Ask = {
	call: Async,
	args: u8,
	rets: u8,
}
"#;

const NAMES: [&str; 7] = ["Tap", "Steer", "Score", "Wind", "Shop.Opened", "Shop.Price", "Ask"];

struct Generated {
	server: String,
	client: String,
	defs: String,
}

fn generate(opts: &str) -> Generated {
	let script = zap::run(&format!("opt typescript = true\n{opts}\n{EVENTS}"), true);
	let code = script.code.expect("Zap did not generate any code!");

	Generated {
		server: code.server.code,
		client: code.client.code,
		defs: code.server.defs.expect("Zap did not generate TypeScript definitions!"),
	}
}

fn count(haystack: &str, needle: &str) -> usize {
	haystack.matches(needle).count()
}

fn counter_names(server: &str) -> Vec<&str> {
	let list = server
		.lines()
		.find_map(|line| line.trim_start().strip_prefix("for slot, name in { "))
		.expect("the server lists no counter names");

	list.trim_end_matches(" } do")
		.split(", ")
		.map(|name| name.trim_matches('"'))
		.collect()
}

#[test]
fn turning_the_option_off_changes_nothing() {
	let default = generate("");
	let off = generate("opt traffic_counters = false");

	assert_eq!(default.server, off.server);
	assert_eq!(default.client, off.client);
	assert_eq!(default.defs, off.defs);
	assert_eq!(count(&default.server, "traffic"), 0);
	assert_eq!(count(&default.defs, "TrafficCounters"), 0);
}

#[test]
fn the_option_only_adds_server_code() {
	for limits in [
		"",
		"opt max_client_packet_bytes = 4096\nopt max_client_events_per_frame = 128",
	] {
		let default = generate(limits);
		let counted = generate(&format!("{limits}\nopt traffic_counters = true"));

		let mut remaining = counted.server.lines();
		for line in default.server.lines() {
			assert!(
				remaining.any(|kept| kept == line),
				"the counted output lost or reordered a line of the default output: {line}"
			);
		}

		assert_eq!(default.client, counted.client, "the client module changed");
	}
}

#[test]
fn every_event_and_function_has_a_counter() {
	let generated = generate("opt traffic_counters = true");
	let mut names = counter_names(&generated.server);
	names.sort_unstable();

	let mut expected = NAMES.to_vec();
	expected.sort_unstable();

	assert_eq!(names, expected);
	assert_eq!(
		count(&generated.server, "local traffic_counters = buffer.create(224)"),
		1,
		"seven counters of four f64s each"
	);
}

#[test]
fn the_reliable_loop_counts_every_event_in_one_place() {
	let generated = generate("opt traffic_counters = true");

	assert_eq!(count(&generated.server, "local traffic_start = incoming_read"), 1);
	assert_eq!(count(&generated.server, "incoming_read - traffic_start"), 1);
	assert_eq!(count(&generated.server, "local traffic_at = id * 32"), 1);
}

#[test]
fn the_api_follows_the_casing() {
	for (casing, name, fields) in [
		(
			"PascalCase",
			"GetTrafficCounters",
			["Received", "ReceivedBytes", "Sent", "SentBytes"],
		),
		(
			"camelCase",
			"getTrafficCounters",
			["received", "receivedBytes", "sent", "sentBytes"],
		),
		(
			"snake_case",
			"get_traffic_counters",
			["received", "received_bytes", "sent", "sent_bytes"],
		),
	] {
		let generated = generate(&format!("opt casing = \"{casing}\"\nopt traffic_counters = true"));
		let [received, received_bytes, sent, sent_bytes] = fields;

		assert_eq!(
			count(&generated.server, &format!("\t{name} = get_traffic_counters,")),
			2,
			"{casing}: the API and the studio stub"
		);
		assert_eq!(
			count(
				&generated.server,
				&format!(
					"local function get_traffic_counters(): {{ [string]: {{ {received}: number, {received_bytes}: number, {sent}: number, {sent_bytes}: number }} }}"
				)
			),
			1,
			"{casing}: the return type"
		);
		for field in fields {
			assert_eq!(
				count(
					&generated.server,
					&format!("\t{field} = buffer.readf64(traffic_counters, ")
				),
				1,
				"{casing}: {field}"
			);
		}
		assert_eq!(
			count(
				&generated.defs,
				&format!(
					"export declare const {name}: () => {{ [name: string]: {{ {received}: number; {received_bytes}: number; {sent}: number; {sent_bytes}: number }} }}"
				)
			),
			1,
			"{casing} definition"
		);
		assert_eq!(count(&generated.client, "traffic"), 0, "{casing} client");
	}
}

#[test]
fn the_api_name_is_reserved_only_while_counting() {
	let event = "event GetTrafficCounters = { from: Client, type: Reliable, call: ManySync, data: u8 }";

	assert!(zap::run(event, true).diagnostics.is_empty());

	let messages = zap::run(&format!("opt traffic_counters = true\n{event}"), true)
		.diagnostics
		.into_iter()
		.map(|diagnostic| diagnostic.message)
		.collect::<Vec<_>>();
	assert!(
		messages
			.iter()
			.any(|message| message == "Zap exports GetTrafficCounters at the top level"),
		"{messages:?}"
	);
}

#[test]
fn server_event_parameters_cannot_hide_the_counters() {
	for name in ["traffic_counters", "traffic_sent_start"] {
		for event in [
			format!("event Rerouted = {{ from: Server, type: Reliable, call: ManySync, data: ({name}: u8) }}"),
			format!(
				"namespace Roads = {{ event Rerouted = {{ from: Server, type: Unreliable, call: ManySync, data: (lane: u8, {name}: u16) }} }}"
			),
		] {
			let messages = zap::run(&format!("opt traffic_counters = true\n{event}"), true)
				.diagnostics
				.into_iter()
				.map(|diagnostic| diagnostic.message)
				.collect::<Vec<_>>();
			assert_eq!(
				messages,
				[format!(
					"the traffic counters use the name '{name}' in the server's send methods"
				)],
				"{event}"
			);

			assert!(
				zap::run(&event, true).diagnostics.is_empty(),
				"{event} was refused without the option"
			);
		}

		let client_event =
			format!("event Rerouted = {{ from: Client, type: Reliable, call: ManySync, data: ({name}: u8) }}");
		assert!(
			zap::run(&format!("opt traffic_counters = true\n{client_event}"), true)
				.diagnostics
				.is_empty(),
			"{client_event} was refused"
		);
	}
}
