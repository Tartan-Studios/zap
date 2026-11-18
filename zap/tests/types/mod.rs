use std::{collections::BTreeSet, fs, path::Path, process::Command};

use crate::luau_tools::{scratch_dir, tool};

fn type_errors(dir: &Path, probe: &str) -> Vec<(usize, String)> {
	let file = dir.join(probe);

	let output = Command::new(tool("luau-lsp"))
		.arg("analyze")
		.arg("--platform=roblox")
		.arg(format!(
			"--definitions:@roblox={}",
			tool("globalTypes.d.luau").display()
		))
		.arg(&file)
		.output()
		.expect("could not run luau-lsp");

	let text = format!(
		"{}{}",
		String::from_utf8_lossy(&output.stdout),
		String::from_utf8_lossy(&output.stderr)
	);

	text.lines()
		.filter(|line| line.contains(probe) && line.contains("TypeError"))
		.map(|line| {
			let position = &line[line.find('(').expect("no position") + 1..];
			let row = position[..position.find(',').expect("no column")]
				.parse::<usize>()
				.expect("the line is not a number");

			(row, line.to_string())
		})
		.collect()
}

fn generated_dir() -> std::path::PathBuf {
	let dir = scratch_dir("types");
	let code = zap::run(include_str!("./probe.zap"), true)
		.code
		.expect("the probe file generated no code");

	fs::write(dir.join("server.luau"), code.server.code).unwrap();
	fs::write(dir.join("client.luau"), code.client.code).unwrap();
	fs::write(dir.join("ok.luau"), include_str!("./ok.luau")).unwrap();
	fs::write(dir.join("bad.luau"), include_str!("./bad.luau")).unwrap();

	dir
}

#[test]
fn correct_calls_type_check() {
	let dir = generated_dir();
	let errors = type_errors(&dir, "ok.luau");
	fs::remove_dir_all(&dir).ok();

	assert!(
		errors.is_empty(),
		"correct calls failed to type-check:\n{}",
		errors.into_iter().map(|(_, line)| line).collect::<Vec<_>>().join("\n")
	);
}

#[test]
fn every_wrong_call_is_a_type_error() {
	let dir = generated_dir();
	let errors = type_errors(&dir, "bad.luau");
	fs::remove_dir_all(&dir).ok();

	let expected = include_str!("./bad.luau")
		.lines()
		.enumerate()
		.filter(|(_, line)| line.ends_with("--> error"))
		.map(|(index, _)| index + 1)
		.collect::<BTreeSet<_>>();
	let found = errors.iter().map(|(row, _)| *row).collect::<BTreeSet<_>>();

	let missed = expected.difference(&found).collect::<Vec<_>>();
	let unexpected = errors
		.iter()
		.filter(|(row, _)| !expected.contains(row))
		.map(|(_, line)| line.as_str())
		.collect::<Vec<_>>();

	assert!(missed.is_empty(), "these wrong calls type-checked: lines {missed:?}");
	assert!(
		unexpected.is_empty(),
		"unexpected type errors:\n{}",
		unexpected.join("\n")
	);
}
