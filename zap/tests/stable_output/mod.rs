use std::fs;

use insta::glob;

fn generate(input: &str) -> Vec<String> {
	let code = zap::run(input, true).code.expect("Zap did not generate any code!");

	[Some(code.server), Some(code.client), code.types, code.tooling]
		.into_iter()
		.flatten()
		.flat_map(|output| [Some(output.code), output.defs])
		.flatten()
		.collect()
}

#[test]
fn generating_a_file_twice_gives_identical_code() {
	glob!(env!("CARGO_MANIFEST_DIR"), "tests/files/*.zap", |path| {
		let input = format!(
			"opt tooling = true\nopt types_output = \"network/types.luau\"\n{}",
			fs::read_to_string(path).unwrap()
		);
		let first = generate(&input);

		for _ in 0..8 {
			assert!(
				generate(&input) == first,
				"{} generated different code on another run",
				path.display()
			);
		}
	});
}
