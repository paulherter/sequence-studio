//! The platform probes the app installs at start reach the preflight (one test: the probes are process-wide).

use sq_export::core::preflight::{ExportPreflight, SpaceVerdict};
use std::path::Path;

fn fake_free(_folder: &Path) -> Option<i64> {
    Some(5_000_000)
}

fn fake_memory() -> Option<u64> {
    Some(8 << 30)
}

#[test]
fn installed_probes_answer_free_space_and_memory() {
    assert_eq!(ExportPreflight::free_bytes(Path::new("/tmp")), None);
    assert_eq!(ExportPreflight::physical_memory(), None);
    assert!(ExportPreflight::install_host_probes(fake_free, fake_memory));
    assert!(!ExportPreflight::install_host_probes(fake_free, fake_memory));
    let free = ExportPreflight::free_bytes(Path::new("/tmp"));
    assert_eq!(free, Some(5_000_000));
    assert_eq!(ExportPreflight::physical_memory(), Some(8 << 30));
    // The low-disk verdict of the preflight now sees the space.
    assert_eq!(ExportPreflight::space_verdict(free, 10_000_000), SpaceVerdict::Insufficient);
}
