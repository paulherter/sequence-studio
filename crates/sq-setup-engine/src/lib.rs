//! The logic under the setup program: everything that is not drawing. The installer window (`sq-installer`) shows what
//! this crate does; the Linux first-run flow of the app uses the same job and error types.
//!
//! Layers: [`version`] (compare), [`job`] (what is being done and its steps), [`error`] (the `SQI-` codes and their
//! sentences). The install plan, the payload and the engine that runs a plan are added beside them.

pub mod detect;
pub mod engine;
pub mod error;
pub mod host;
pub mod identity;
pub mod job;
pub mod log;
pub mod payload;
pub mod plan;
pub mod version;

#[cfg(windows)]
mod windows_host;
#[cfg(windows)]
pub use windows_host::WindowsHost;

#[cfg(test)]
mod engine_tests;

pub use detect::{
    InstallSource, Installed, LocationCheck, UpdateKind, check_location, default_location, detect_installed,
    measure_data, other_channel_installed, quiet_location, resolve_location, update_kind,
};
pub use engine::{JobEnd, JobSpec, Progress, finish_uninstall_copy, run_job, uninstall_copy_name};
pub use error::{ErrorCode, SetupError, SpaceFacts, describe_io};
pub use host::{FakeHost, Host, KnownFolders};
pub use identity::Identity;
pub use job::{Job, Step};
pub use log::Log;
pub use payload::{Payload, UnpackEnd};
pub use plan::{Action, Options, PlanEnv, inverse, plan};
pub use version::Version;

/// `412 MB`, `2.1 GB`, `under 1 MB`: sizes as the screens print them (binary units, as Windows Explorer does). Above
/// 1 GB one decimal; below, whole megabytes.
pub fn format_size(bytes: u64) -> String {
    const MB: u64 = 1 << 20;
    const GB: u64 = 1 << 30;
    if bytes >= GB {
        // Tenths, rounded half up, from integers so the text never depends on float printing.
        let tenths = (bytes * 10 + GB / 2) / GB;
        format!("{}.{} GB", tenths / 10, tenths % 10)
    } else if bytes >= MB {
        format!("{} MB", (bytes + MB / 2) / MB)
    } else {
        "under 1 MB".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::format_size;

    #[test]
    fn sizes_print_as_the_screens_show_them() {
        assert_eq!(format_size(0), "under 1 MB");
        assert_eq!(format_size(900_000), "under 1 MB");
        assert_eq!(format_size(412 << 20), "412 MB");
        assert_eq!(format_size(1 << 30), "1.0 GB");
        assert_eq!(format_size((2.1 * f64::from(1u32 << 30)) as u64), "2.1 GB");
        assert_eq!(format_size(12 << 30), "12.0 GB");
        assert_eq!(format_size((1 << 30) - 1), "1024 MB", "just below a gigabyte stays in megabytes");
    }
}
