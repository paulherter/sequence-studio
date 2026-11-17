//! The text logic of `build.rs` for the Windows import libraries, in its own file so the crate's tests cover it
//! (`lib.rs` includes this file under `cfg(test)`; `build.rs` includes it as a module).

/// The `.def` text with a `LIBRARY <dll>` line in front, unless it already names its library (a second `LIBRARY` line would
/// make `llvm-lib` / `lib.exe` refuse it or take the wrong name).
pub fn def_with_library(text: &str, dll: &str) -> String {
    let named = text.lines().any(|l| l.split_whitespace().next().is_some_and(|w| w.eq_ignore_ascii_case("LIBRARY")));
    if named { text.to_string() } else { format!("LIBRARY {dll}\n{text}") }
}

/// `SQ_REQUIRE_DELAYLOAD=1`: the package builds set it, so a missing tool or `.def` file fails the build instead of
/// quietly giving an exe that loads the FFmpeg DLLs before `main` again.
pub fn delay_load_required(value: Option<&str>) -> bool {
    value == Some("1")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_def_without_a_library_line_gets_one() {
        let text = def_with_library("EXPORTS\n    av_alloc\n", "avcodec-63.dll");
        assert_eq!(text, "LIBRARY avcodec-63.dll\nEXPORTS\n    av_alloc\n");
    }

    #[test]
    fn a_def_that_names_its_library_is_left_alone_in_any_case() {
        for named in [
            "LIBRARY avcodec-63.dll\nEXPORTS\n a\n",
            "  library \"avcodec-63.dll\"\nEXPORTS\n a\n",
            "Library avcodec-63\n",
        ] {
            assert_eq!(def_with_library(named, "avcodec-63.dll"), named);
        }
        let exports_only = "EXPORTS\n    library_open\n";
        assert!(
            def_with_library(exports_only, "x.dll").starts_with("LIBRARY x.dll\n"),
            "a symbol named library_… is no statement"
        );
    }

    #[test]
    fn only_a_one_makes_the_delay_load_required() {
        assert!(delay_load_required(Some("1")));
        for no in [None, Some("0"), Some(""), Some("true")] {
            assert!(!delay_load_required(no), "{no:?}");
        }
    }
}
