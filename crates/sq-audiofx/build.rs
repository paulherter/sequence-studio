//! Builds the vendored RNNoise C library (BSD-3-Clause, see `vendor/rnnoise/COPYING`).

fn main() {
    let dir = "vendor/rnnoise";
    let mut build = cc::Build::new();
    build.include(dir).include("vendor/rnnoise/include").warnings(false);
    for file in ["celt_lpc.c", "denoise.c", "kiss_fft.c", "pitch.c", "rnn.c", "rnn_data.c"] {
        build.file(format!("{dir}/{file}"));
    }
    build.compile("rnnoise");
    println!("cargo:rerun-if-changed={dir}");
}
