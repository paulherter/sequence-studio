//! The pinned Whisper ONNX exports (int8 dynamic quantized, Apache-2.0): repo, commit, then per file the name in the repo,
//! size and sha256 (from the Hugging Face API; the small json files hashed after download). `PINS` are the
//! `onnx-community/whisper-*_timestamped` exports whose decoder returns cross-attentions (word timing); `LEGACY_PINS` are the
//! earlier `Xenova/whisper-*` exports (no attentions), kept so a model downloaded under them keeps working.

/// One file: name in the repo, size, sha256.
pub type PinnedFile = (&'static str, u64, &'static str);

/// A model size and where its files come from.
#[derive(Clone, Copy, Debug)]
pub struct OnnxWhisperPin {
    /// "tiny", "base" or "small".
    pub size: &'static str,
    /// Hugging Face repo.
    pub repo: &'static str,
    /// Commit the hashes belong to.
    pub commit: &'static str,
    /// The files.
    pub files: &'static [PinnedFile],
    /// The decoder returns cross-attentions and `generation_config.json` lists the alignment heads (word timing).
    pub aligned: bool,
}

const TOKENIZER: PinnedFile =
    ("tokenizer.json", 2_480_466, "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566");

/// The earlier exports: tiny (about 41 MB), base (about 77 MB), small (about 249 MB); the service defaults to small like the ggml engine.
pub const LEGACY_PINS: &[OnnxWhisperPin] = &[
    OnnxWhisperPin {
        size: "tiny",
        repo: "Xenova/whisper-tiny",
        commit: "5332fcc35e32a33b86612b9a57a89be7906102b1",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                10_124_910,
                "fd9d995b9dcb0520f0dbf6cf68651af639fc385f594d9d876e69ca2802dc438e",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                30_727_765,
                "6c0c125986b007d2e3734bec84c18bda0152071b90b87fadac6d7764499927a0",
            ),
            TOKENIZER,
            ("config.json", 2_248, "2b2e4e519084e0ea028b19b153f95202735a971870d6844aa26e559edd292e94"),
        ],
        aligned: false,
    },
    OnnxWhisperPin {
        size: "base",
        repo: "Xenova/whisper-base",
        commit: "64da57285918e20ea79ea5c88eed7197933abaa8",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                23_200_850,
                "3e345e977b55620a37c0c2b2af0644e019afdfad562dcf71eb929bb7274285f9",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                53_707_539,
                "a6beb6baabb66f00b6a686d828c95ffca6146d51900cbad0266cad38f64cf861",
            ),
            TOKENIZER,
            ("config.json", 2_248, "d1d347fdb422e6347c2f843a90d375aa67ea3f4b3e20d2c3075f9a9f6243685b"),
        ],
        aligned: false,
    },
    OnnxWhisperPin {
        size: "small",
        repo: "Xenova/whisper-small",
        commit: "2d67713f236afa48a18992566e7647f6ca848e13",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                92_324_809,
                "969f5ac12974340386bf7a02ea6626003e5e2dee396ffc6ab0eec282bf55ba06",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                156_780_950,
                "fcfc6100dc7339e7507e10f8b274350be7c4f8d8b575f0293f94cc0e156d6d24",
            ),
            TOKENIZER,
            ("config.json", 2_232, "5a6429d21d7a3379dd0861b74510f9f7076f32b563bffc9fcb072482d55ab3be"),
        ],
        aligned: false,
    },
];

/// The timestamped exports: tiny (about 41 MB), base (about 77 MB), small (about 249 MB), like the earlier ones.
pub const PINS: &[OnnxWhisperPin] = &[
    OnnxWhisperPin {
        size: "tiny",
        repo: "onnx-community/whisper-tiny_timestamped",
        commit: "517244293732ee2d58139af5814231b7e6830a0d",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                10_097_109,
                "d4397fbfed1975bb5dd1bedb748808367331c85293f54cbc927774728daec2b2",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                30_730_264,
                "ced2053c1aa8ff7048927197416a5c169f50010e7b280e5d564b46a991fca011",
            ),
            TOKENIZER,
            ("config.json", 2_243, "46aeea0a406afbeb563fc8e59ca10609203df4299af6a83f73752fef369efd2d"),
            ("generation_config.json", 3_772, "f5c67e5a4f7102f8cb4d058bc95da276bbc19eeec997267c3bb0f25ef68facd1"),
        ],
        aligned: true,
    },
    OnnxWhisperPin {
        size: "base",
        repo: "onnx-community/whisper-base_timestamped",
        commit: "608c49e61301901684bc36cac8f74b95ff6b5a8e",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                23_159_167,
                "2714484ebe1bae7c1646e8eadb768bb9d415cf11763466d21f23039a29c62e6f",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                53_712_708,
                "cf9a8d5bcddc0917a0078135b484cedcaf44f28909cd91910abd29dced9171db",
            ),
            TOKENIZER,
            ("config.json", 2_243, "f4d0608f7d918166da7edb3e188de5ef1bfe70d9802e785d271fd88111e9cf4b"),
            ("generation_config.json", 3_832, "61070cf8de25b1e9256e8e102ded49d8d24a8369ed36ef84fdf21549e68125a0"),
        ],
        aligned: true,
    },
    OnnxWhisperPin {
        size: "small",
        repo: "onnx-community/whisper-small_timestamped",
        commit: "65caa70f294b46e1c33ff820aae6b16d048ab818",
        files: &[
            (
                "onnx/encoder_model_quantized.onnx",
                92_240_498,
                "9f5635b596e6084045c7426ca6f6f99db8ce606ea895397c3b4a3c0aa3f9b070",
            ),
            (
                "onnx/decoder_model_merged_quantized.onnx",
                156_795_750,
                "c831996a6d5a535cf17447b0d7ecc36da6b72696e6fb906852ba6136b9199abb",
            ),
            TOKENIZER,
            ("config.json", 2_227, "457854d452f17661e197d74aee12b8e74fb75ba30ebfaa7426d0d61ea1e08a18"),
            ("generation_config.json", 3_893, "f538b28220c6a6d6f1af1458d4141cacb4ef4963df3de98a19490440c412ddf0"),
        ],
        aligned: true,
    },
];

/// The pin of a size.
pub fn pin(size: &str) -> Option<&'static OnnxWhisperPin> {
    PINS.iter().find(|p| p.size == size)
}

/// The earlier, attention-less pin of a size.
pub fn legacy_pin(size: &str) -> Option<&'static OnnxWhisperPin> {
    LEGACY_PINS.iter().find(|p| p.size == size)
}
