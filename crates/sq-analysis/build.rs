//! Builds Apple's LZFSE reference decoder (BSD-3-Clause, vendored unmodified in `vendor/lzfse`).

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    cc::Build::new()
        .files(
            ["lzfse_decode.c", "lzfse_decode_base.c", "lzfse_fse.c", "lzvn_decode_base.c"]
                .map(|f| format!("vendor/lzfse/{f}")),
        )
        .include("vendor/lzfse")
        .warnings(false)
        .compile("clzfse");
}
