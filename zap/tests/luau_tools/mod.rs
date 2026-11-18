use std::{path::PathBuf, process, time::SystemTime};

pub fn tool(name: &str) -> PathBuf {
	let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
		.join("../.luau-tools")
		.join(name);

	assert!(
		path.exists(),
		"{} is missing; run `python3 scripts/fetch-luau-tools.py` to install the pinned Luau tools",
		path.display()
	);

	path
}

pub fn scratch_dir(label: &str) -> PathBuf {
	let nanos = SystemTime::now()
		.duration_since(SystemTime::UNIX_EPOCH)
		.expect("the clock is before 1970")
		.as_nanos();
	let dir = std::env::temp_dir().join(format!("zap-{label}-{}-{nanos}", process::id()));

	std::fs::create_dir_all(&dir).expect("could not create a scratch directory");

	dir
}
