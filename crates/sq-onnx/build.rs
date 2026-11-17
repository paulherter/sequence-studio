//! Builds the vendored C face over ONNX Runtime. It loads `onnxruntime.dll` at run time, so nothing links against it.

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    cc::Build::new().file("vendor/csqonnx.c").include("vendor").warnings(true).compile("csqonnx");
}
