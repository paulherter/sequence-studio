//! Storage-root validation sees the free space the app's platform probe reports.

use sq_editor_session::{StorageLocations, StorageProblem};
use sq_export::core::preflight::ExportPreflight;
use std::path::Path;

fn fake_free(_folder: &Path) -> Option<i64> {
    Some(1_000)
}

#[test]
fn a_root_with_too_little_space_is_refused() {
    ExportPreflight::install_host_probes(fake_free, || None);
    let dir = std::env::temp_dir().join(format!("sq-storage-free-{}", std::process::id()));
    let problem = StorageLocations::validate(&dir, 1_000_000, &StorageLocations::free_bytes);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(problem, Some(StorageProblem::NotEnoughSpace { free: 1_000, needed: 1_000_000 }));
}
