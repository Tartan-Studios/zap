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

funct Ask = {
	call: Sync,
	args: u8,
	rets: u8,
}
"#;

const LIMIT_CODE: [&str; 6] = [
	"refuse_packet",
	"packet_refused_callback",
	"PacketRefusedCallback",
	"events_left",
	"event_frame",
	"buffer.len(buff) >",
];

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

fn error_messages(input: &str) -> Vec<String> {
	zap::run(input, true)
		.diagnostics
		.into_iter()
		.map(|diagnostic| diagnostic.message)
		.collect()
}

fn count(haystack: &str, needle: &str) -> usize {
	haystack.matches(needle).count()
}

#[test]
fn no_limit_code_is_generated_without_the_options() {
	let generated = generate("");

	for needle in LIMIT_CODE {
		assert_eq!(count(&generated.server, needle), 0, "{needle}");
		assert_eq!(count(&generated.defs, needle), 0, "{needle} definition");
	}
}

#[test]
fn the_options_only_add_server_code() {
	let default = generate("");
	let limited = generate("opt max_client_packet_bytes = 4096\nopt max_client_events_per_frame = 128");

	let mut remaining = limited.server.lines();
	for line in default.server.lines() {
		assert!(
			remaining.any(|kept| kept == line),
			"the limited output lost or reordered a line of the default output: {line}"
		);
	}

	assert_eq!(default.client, limited.client, "the client module changed");
}

#[test]
fn the_byte_limit_guards_every_client_remote() {
	let generated = generate("opt max_client_packet_bytes = 4096");

	assert_eq!(count(&generated.server, "if buffer.len(buff) > 4096 then"), 2);
	assert_eq!(count(&generated.server, "refuse_packet(player, \"PacketTooLarge\")"), 2);
	assert_eq!(count(&generated.server, "events_left"), 0);
	assert_eq!(count(&generated.server, "event_frame"), 0);
}

#[test]
fn the_event_limit_counts_every_client_remote_per_frame() {
	let generated = generate("opt max_client_events_per_frame = 128");

	assert_eq!(count(&generated.server, "buffer.len(buff) >"), 0);
	assert_eq!(
		count(&generated.server, "local events_left = events_left_this_frame(player)"),
		2
	);
	assert_eq!(count(&generated.server, "refuse_packet(player, \"TooManyEvents\")"), 2);
	assert_eq!(count(&generated.server, "RunService.Heartbeat:Connect(function()"), 1);
	assert_eq!(count(&generated.server, "player_events_left[player] = 128"), 1);
	assert_eq!(count(&generated.server, "player_events_left[player] = nil"), 1);
}

#[test]
fn the_refusal_callback_follows_the_casing() {
	for (casing, name) in [
		("PascalCase", "SetPacketRefusedCallback"),
		("camelCase", "setPacketRefusedCallback"),
		("snake_case", "set_packet_refused_callback"),
	] {
		let generated = generate(&format!(
			"opt casing = \"{casing}\"\nopt max_client_events_per_frame = 8"
		));

		assert_eq!(
			count(&generated.server, &format!("\t{name} = function(")),
			1,
			"{casing}"
		);
		assert_eq!(
			count(&generated.server, &format!("\t{name} = noop,")),
			1,
			"{casing} studio stub"
		);
		assert_eq!(
			count(&generated.defs, &format!("export declare const {name}: (")),
			1,
			"{casing} definition"
		);
	}
}

#[test]
fn a_server_with_no_client_events_still_gets_the_callback() {
	let input = "opt max_client_events_per_frame = 8\nevent Score = { from: Server, type: Reliable, call: ManyAsync, data: u8 }";
	let code = zap::run(input, true).code.expect("Zap did not generate any code!");

	assert_eq!(count(&code.server.code, "\tSetPacketRefusedCallback = function("), 1);
	assert_eq!(count(&code.server.code, "event_frame"), 0);
}

#[test]
fn limits_must_be_whole_numbers_of_at_least_one() {
	for value in ["0", "-4", "1.5", "4294967296", "\"big\"", "true"] {
		for option in ["max_client_packet_bytes", "max_client_events_per_frame"] {
			let messages = error_messages(&format!("opt {option} = {value}\n{EVENTS}"));

			assert!(
				messages.iter().any(|message| message.starts_with("invalid opt value")),
				"{option} = {value} was accepted: {messages:?}"
			);
		}
	}

	for value in ["1", "4294967295"] {
		let messages = error_messages(&format!("opt max_client_packet_bytes = {value}\n{EVENTS}"));
		assert!(messages.is_empty(), "{value} was refused: {messages:?}");
	}
}

#[test]
fn the_callback_name_is_reserved_only_while_a_limit_is_set() {
	let event = "event SetPacketRefusedCallback = { from: Client, type: Reliable, call: ManySync, data: u8 }";

	assert!(error_messages(event).is_empty());

	let messages = error_messages(&format!("opt max_client_packet_bytes = 64\n{event}"));
	assert!(
		messages
			.iter()
			.any(|message| message == "Zap exports SetPacketRefusedCallback at the top level"),
		"{messages:?}"
	);
}
