use std::{fs, path::PathBuf, process, time::SystemTime};

use insta::assert_snapshot;
use lune::Runtime;

fn transcript_path() -> PathBuf {
	let nanos = SystemTime::now()
		.duration_since(SystemTime::UNIX_EPOCH)
		.expect("the clock is before 1970")
		.as_nanos();

	std::env::temp_dir().join(format!("zap-wire-{}-{nanos}.txt", process::id()))
}

#[test]
fn every_send_method_writes_the_same_bytes_and_the_client_reads_them_back() {
	let script = zap::run(include_str!("./wire.zap"), true);
	let code = script.code.expect("Zap did not generate any code!");
	let path = transcript_path();

	let mut runtime = Runtime::new().with_args(vec![
		code.server.code.clone(),
		code.client.code.clone(),
		path.to_string_lossy().into_owned(),
	]);

	let (exit_code, _) = tokio::runtime::Runtime::new()
		.expect("Unable to setup tokio")
		.block_on(async { runtime.run("wire", include_str!("./wire.luau")).await })
		.expect("the wire script failed to run");

	assert_eq!(exit_code, 0, "the wire script reported an error");

	let transcript = fs::read_to_string(&path).expect("the wire script wrote no transcript");
	fs::remove_file(&path).ok();

	assert_snapshot!(transcript);
}
