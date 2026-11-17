//! Builds the vendored C face over whisper.cpp. It loads `whisper.dll` at run time, so nothing links against it.

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    cc::Build::new().file("vendor/csqwhisper.c").include("vendor").warnings(true).compile("csqwhisper");
}
