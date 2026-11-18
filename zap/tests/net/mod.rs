use std::{
	fmt::Write,
	fs,
	path::{Path, PathBuf},
	process,
	time::SystemTime,
};

use insta::{Settings, assert_snapshot, glob};
use lune::Runtime;
use zap::{
	config::{
		Casing, Config, Enum, EvCall, EvSource, EvType, FnCall, NumTy, Parameter, Range, Struct, Ty,
		TypeScriptEnumType, YieldType,
	},
	parser,
};

fn lua_string(text: &str) -> String {
	format!("{text:?}")
}

fn lua_number(number: f64) -> String {
	if number.is_finite() {
		format!("{number:?}")
	} else if number > 0.0 {
		"math.huge".into()
	} else {
		"-math.huge".into()
	}
}

fn lua_range(range: &Range) -> String {
	let mut fields = vec![];

	if let Some(min) = range.min() {
		fields.push(format!("min = {}", lua_number(min)));
	}

	if let Some(max) = range.max() {
		fields.push(format!("max = {}", lua_number(max)));
	}

	format!("{{ {} }}", fields.join(", "))
}

fn length_cap(range: &Range, fixed_when_exact: bool) -> String {
	if fixed_when_exact && range.exact().is_some() {
		return "nil".into();
	}

	let (numty, offset) = range.numty();
	lua_number(offset + numty.max())
}

fn numty_name(numty: NumTy) -> &'static str {
	match numty {
		NumTy::F32 => "f32",
		NumTy::F64 => "f64",
		NumTy::U8 => "u8",
		NumTy::U16 => "u16",
		NumTy::U32 => "u32",
		NumTy::I8 => "i8",
		NumTy::I16 => "i16",
		NumTy::I32 => "i32",
	}
}

struct Describer {
	const_number_enums: bool,
}

impl Describer {
	fn fields(&self, struct_ty: &Struct) -> String {
		let fields = struct_ty
			.fields
			.iter()
			.map(|(name, ty)| format!("{{ name = {}, ty = {} }}", lua_string(name), self.ty(ty)))
			.collect::<Vec<_>>();

		format!("{{ {} }}", fields.join(", "))
	}

	fn number(&self, ty: &Ty) -> String {
		match ty {
			Ty::Num(numty, range) => format!(
				"{{ kind = \"num\", numty = \"{}\", range = {} }}",
				numty_name(*numty),
				lua_range(range)
			),
			_ => unreachable!("vector components are always numbers"),
		}
	}

	fn ty(&self, ty: &Ty) -> String {
		match ty {
			Ty::Num(..) => self.number(ty),
			Ty::Str(utf8, range) => format!(
				"{{ kind = \"str\", utf8 = {utf8}, range = {}, cap = {} }}",
				lua_range(range),
				length_cap(range, !utf8)
			),
			Ty::Buf(range) => format!(
				"{{ kind = \"buf\", range = {}, cap = {} }}",
				lua_range(range),
				length_cap(range, true)
			),
			Ty::Vector(x, y, z) => format!(
				"{{ kind = \"vector\", x = {}, y = {}, z = {} }}",
				self.number(x),
				self.number(y),
				z.as_ref().map(|z| self.number(z)).unwrap_or("nil".into())
			),
			Ty::Arr(item, range) => format!(
				"{{ kind = \"arr\", item = {}, range = {}, cap = {} }}",
				self.ty(item),
				lua_range(range),
				length_cap(range, true)
			),
			Ty::Map(key, value) => format!(
				"{{ kind = \"map\", key = {}, value = {} }}",
				self.ty(key),
				self.ty(value)
			),
			Ty::Set(key) => format!("{{ kind = \"set\", key = {} }}", self.ty(key)),
			Ty::Opt(inner) => format!("{{ kind = \"opt\", inner = {} }}", self.ty(inner)),
			Ty::Ref(tydecl) => format!("{{ kind = \"ref\", name = {} }}", lua_string(&tydecl.to_string())),
			Ty::Enum(Enum::Unit(variants)) => {
				let values = variants
					.iter()
					.enumerate()
					.map(|(index, variant)| {
						if self.const_number_enums {
							index.to_string()
						} else {
							lua_string(variant)
						}
					})
					.collect::<Vec<_>>();

				format!("{{ kind = \"enum\", values = {{ {} }} }}", values.join(", "))
			}
			Ty::Enum(Enum::Tagged { tag, variants }) => {
				let variants = variants
					.iter()
					.map(|(name, fields)| {
						format!("{{ name = {}, fields = {} }}", lua_string(name), self.fields(fields))
					})
					.collect::<Vec<_>>();

				format!(
					"{{ kind = \"tagged\", tag = {}, variants = {{ {} }} }}",
					lua_string(tag),
					variants.join(", ")
				)
			}
			Ty::Struct(struct_ty) => format!("{{ kind = \"struct\", fields = {} }}", self.fields(struct_ty)),
			Ty::Or(members, optional) => format!(
				"{{ kind = \"or\", optional = {optional}, members = {{ {} }} }}",
				members
					.iter()
					.map(|member| self.ty(member))
					.collect::<Vec<_>>()
					.join(", ")
			),
			Ty::Instance(class) => format!(
				"{{ kind = \"instance\", class = {} }}",
				class.map(lua_string).unwrap_or("nil".into())
			),
			Ty::Unknown => "{ kind = \"unknown\" }".into(),
			Ty::BrickColor => "{ kind = \"BrickColor\" }".into(),
			Ty::DateTimeMillis => "{ kind = \"DateTimeMillis\" }".into(),
			Ty::DateTime => "{ kind = \"DateTime\" }".into(),
			Ty::Color3 => "{ kind = \"Color3\" }".into(),
			Ty::Vector2 => "{ kind = \"Vector2\" }".into(),
			Ty::Vector3 => "{ kind = \"Vector3\" }".into(),
			Ty::AlignedCFrame => "{ kind = \"AlignedCFrame\" }".into(),
			Ty::CFrame => "{ kind = \"CFrame\" }".into(),
			Ty::Boolean => "{ kind = \"boolean\" }".into(),
		}
	}

	fn parameters(&self, parameters: &[Parameter]) -> String {
		format!(
			"{{ {} }}",
			parameters
				.iter()
				.map(|parameter| self.ty(&parameter.ty))
				.collect::<Vec<_>>()
				.join(", ")
		)
	}
}

fn path(segments: &[&str], name: &str) -> String {
	let names = segments
		.iter()
		.copied()
		.chain(std::iter::once(name))
		.map(lua_string)
		.collect::<Vec<_>>();

	format!("{{ {} }}", names.join(", "))
}

fn schema(config: &Config) -> String {
	let describer = Describer {
		const_number_enums: matches!(config.typescript_enum, TypeScriptEnumType::ConstNumber),
	};

	let mut out = String::from("{\n");

	writeln!(
		out,
		"\tcasing = \"{}\",",
		match config.casing {
			Casing::Pascal => "Pascal",
			Casing::Camel => "Camel",
			Casing::Snake => "Snake",
		}
	)
	.unwrap();

	writeln!(out, "\tyields = {},", config.yield_type == YieldType::Yield).unwrap();
	writeln!(
		out,
		"\tdisabled = {{ FireAll = {}, FireExcept = {}, FireSet = {} }},",
		config.disable_fire_all, config.disable_fire_except, config.disable_fire_set
	)
	.unwrap();

	out.push_str("\ttypes = {\n");
	for tydecl in &config.tydecls {
		writeln!(
			out,
			"\t\t[{}] = {},",
			lua_string(&tydecl.to_string()),
			describer.ty(&tydecl.ty.borrow())
		)
		.unwrap();
	}
	out.push_str("\t},\n");

	out.push_str("\tevents = {\n");
	let mut events = config.evdecls();
	events.sort_by_key(|event| event.display_path());
	for event in events {
		writeln!(
			out,
			"\t\t{{ path = {}, from = \"{}\", reliability = \"{}\", call = \"{}\", params = {} }},",
			path(&event.path, event.name),
			match event.from {
				EvSource::Server => "Server",
				EvSource::Client => "Client",
			},
			match event.evty {
				EvType::Reliable => "Reliable",
				EvType::Unreliable(false) => "Unreliable",
				EvType::Unreliable(true) => "OrderedUnreliable",
			},
			match event.call {
				EvCall::SingleSync => "SingleSync",
				EvCall::SingleAsync => "SingleAsync",
				EvCall::ManySync => "ManySync",
				EvCall::ManyAsync => "ManyAsync",
				EvCall::Polling => "Polling",
			},
			describer.parameters(&event.data)
		)
		.unwrap();
	}
	out.push_str("\t},\n");

	out.push_str("\tfunctions = {\n");
	let mut functions = config.fndecls();
	functions.sort_by_key(|function| function.display_path());
	for function in functions {
		writeln!(
			out,
			"\t\t{{ path = {}, call = \"{}\", args = {}, rets = {} }},",
			path(&function.path, function.name),
			match function.call {
				FnCall::Async => "Async",
				FnCall::Sync => "Sync",
			},
			describer.parameters(&function.args),
			match &function.rets {
				Some(rets) => format!(
					"{{ {} }}",
					rets.iter().map(|ty| describer.ty(ty)).collect::<Vec<_>>().join(", ")
				),
				None => "{}".into(),
			}
		)
		.unwrap();
	}
	out.push_str("\t},\n");

	out.push('}');
	out
}

fn report_path() -> PathBuf {
	let nanos = SystemTime::now()
		.duration_since(SystemTime::UNIX_EPOCH)
		.expect("the clock is before 1970")
		.as_nanos();

	std::env::temp_dir().join(format!("zap-net-{}-{nanos}.txt", process::id()))
}

fn seed(name: &str) -> u64 {
	name.bytes()
		.fold(2166136261u64, |hash, byte| {
			(hash ^ byte as u64).wrapping_mul(16777619) % 2147483647
		})
		.max(1)
}

pub fn run_net_test(name: &str, input: &str) -> String {
	let (config, _) = parser::parse(input);
	let config = config.unwrap_or_else(|| panic!("{name} does not parse"));

	let strict = zap::run(input, true);
	let strict = strict
		.code
		.unwrap_or_else(|| panic!("{name} generated no code: {:#?}", strict.diagnostics));
	let loose = zap::run(&format!("opt write_checks = false\n{input}"), true)
		.code
		.unwrap_or_else(|| panic!("{name} generated no code without write checks"));

	let report = report_path();

	let mut runtime = Runtime::new().with_args(vec![
		strict.server.code.clone(),
		strict.client.code.clone(),
		loose.client.code.clone(),
		schema(&config),
		seed(name).to_string(),
		report.to_string_lossy().into_owned(),
	]);

	let result = tokio::runtime::Runtime::new()
		.expect("Unable to setup tokio")
		.block_on(async { runtime.run(name, include_str!("./net.luau")).await });

	let text = fs::read_to_string(&report).unwrap_or_default();
	fs::remove_file(&report).ok();

	match result {
		Ok((0, _)) => text,
		Ok((code, _)) => panic!("{name}: the network test exited with {code}\n{text}"),
		Err(error) => panic!("{name}: the network test failed\n{text}\n{error}"),
	}
}

fn net_snapshot(path: &Path) {
	let input = fs::read_to_string(path).unwrap();
	let name = path.file_stem().unwrap().to_string_lossy().to_string();
	let report = run_net_test(&name, &input);

	let mut settings = Settings::new();
	settings.set_prepend_module_to_snapshot(false);
	settings.set_input_file(path);
	settings.set_snapshot_suffix(name);
	settings.bind(|| assert_snapshot!(report));
}

#[test]
fn every_fixture_survives_the_network() {
	glob!(env!("CARGO_MANIFEST_DIR"), "tests/files/*.zap", net_snapshot);
}

#[test]
fn every_type_and_call_style_survives_the_network() {
	glob!(env!("CARGO_MANIFEST_DIR"), "tests/net/files/*.zap", net_snapshot);
}
