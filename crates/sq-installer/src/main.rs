//! `sq-installer`: the Sequence Studio setup program (Windows installer and uninstaller). Developer modes that work on any
//! system: `--shot <screen> [--theme dark|light] [--scale 2] [--at <seconds>] --out <png>` renders a screen without a
//! window; `--list-screens` names them.

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use sq_draw::GlyphAtlas;
use sq_installer::args::Args;
use sq_installer::shots;
use sq_setup_engine::payload;

/// Inter, carried inside the program: the setup has no fonts folder next to it.
const INTER: &[u8] =
    include_bytes!("../../../Packages/SQText/Sources/SQText/Resources/Fonts/Inter-VariableFont_opsz,wght.ttf");

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn shot(args: &[String]) -> Result<(), String> {
    let name = flag(args, "--shot").ok_or("--shot needs a screen name")?;
    let machine = shots::machine(&name).ok_or_else(|| format!("unknown screen {name}; --list-screens names them"))?;
    let light = flag(args, "--theme").is_some_and(|t| t == "light");
    let scale: f32 = flag(args, "--scale").and_then(|s| s.parse().ok()).unwrap_or(2.0);
    let at: f64 = flag(args, "--at").and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let out = flag(args, "--out").ok_or("--shot needs --out <png>")?;
    let atlas = GlyphAtlas::inter_bytes(INTER.to_vec()).ok_or("the built-in font did not load")?;
    shots::write_png(&shots::picture(&machine, &atlas, light, scale, at), std::path::Path::new(&out))
}

/// `--pack <stage> --out <setup.exe>`: this program without any payload, plus the stage folder as its payload.
fn pack(args: &Args) -> Result<(), String> {
    let (Some(stage), Some(out)) = (&args.pack, &args.out) else {
        return Err("--pack needs <stage folder> and --out <file>".into());
    };
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let stub_len = payload::stub_len(&exe).map_err(|e| e.to_string())?;
    let mut stub = std::fs::read(&exe).map_err(|e| format!("{}: {e}", exe.display()))?;
    stub.truncate(usize::try_from(stub_len).map_err(|e| e.to_string())?);
    let version = sq_installer::build_version();
    payload::pack(&stub, stage, &version, out).map_err(|e| e.to_string())
}

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--list-screens") {
        println!("{}", shots::SCREENS.join("\n"));
        return std::process::ExitCode::SUCCESS;
    }
    let parsed = if args.iter().any(|a| a == "--shot") { Ok(Args::default()) } else { Args::parse(&args) };
    let result = match parsed {
        _ if args.iter().any(|a| a == "--shot") => shot(&args),
        Ok(a) if a.pack.is_some() => pack(&a),
        #[cfg(windows)]
        Ok(a) => {
            return match GlyphAtlas::inter_bytes(INTER.to_vec()) {
                Some(atlas) => sq_installer::windows::run(&a, atlas),
                None => {
                    eprintln!("sq-installer: the built-in font did not load");
                    std::process::ExitCode::FAILURE
                }
            };
        }
        #[cfg(not(windows))]
        Ok(_) => Err("the installer runs on Windows; here only --shot, --list-screens and --pack work".to_string()),
        Err(e) => Err(e),
    };
    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sq-installer: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}
