use std::{fs, path::Path, process::Command};

use insta::assert_snapshot;

use crate::luau_tools::{scratch_dir, tool};

fn ir_instructions(module: &Path, stats: &Path) -> u64 {
	let output = Command::new(tool("luau-compile"))
		.arg("--codegennull")
		.arg("-O2")
		.arg("--record-stats=function")
		.arg(format!("--stats-file={}", stats.display()))
		.arg(module)
		.output()
		.expect("could not run luau-compile");

	assert!(
		output.status.success(),
		"luau-compile rejected {}: {}",
		module.display(),
		String::from_utf8_lossy(&output.stderr)
	);

	let stats = fs::read_to_string(stats).expect("luau-compile wrote no stats");
	let count = |text: &str| -> u64 {
		text.match_indices("\"irCount\":")
			.map(|(at, key)| {
				text[at + key.len()..]
					.trim_start()
					.chars()
					.take_while(char::is_ascii_digit)
					.collect::<String>()
					.parse::<u64>()
					.expect("irCount is not a number")
			})
			.sum()
	};

	count(&stats)
}

#[test]
fn native_code_size_of_every_fixture() {
	let dir = scratch_dir("native");
	let mut fixtures = fs::read_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/files"))
		.unwrap()
		.map(|entry| entry.unwrap().path())
		.filter(|path| path.extension().is_some_and(|extension| extension == "zap"))
		.collect::<Vec<_>>();
	fixtures.sort();

	let mut report = String::new();
	let (mut server_total, mut client_total) = (0, 0);

	for fixture in fixtures {
		let name = fixture.file_stem().unwrap().to_string_lossy().to_string();
		let code = zap::run(&fs::read_to_string(&fixture).unwrap(), true)
			.code
			.unwrap_or_else(|| panic!("{name} generated no code"));

		let server = dir.join(format!("{name}.server.luau"));
		let client = dir.join(format!("{name}.client.luau"));
		fs::write(&server, &code.server.code).unwrap();
		fs::write(&client, &code.client.code).unwrap();

		let server_ir = ir_instructions(&server, &dir.join("server.json"));
		let client_ir = ir_instructions(&client, &dir.join("client.json"));
		server_total += server_ir;
		client_total += client_ir;

		report.push_str(&format!("{name}: server {server_ir}, client {client_ir}\n"));
	}

	report.push_str(&format!("total: server {server_total}, client {client_total}\n"));
	fs::remove_dir_all(&dir).ok();

	assert_snapshot!(report);
}
