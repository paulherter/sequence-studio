//! The only place that picks a system. Each branch has the same items: `free_bytes`, `volume_bytes`, `physical_memory`,
//! `install_fault_report`, `Badge` and `SleepLock`.

use winit::window::Window;

#[cfg(target_os = "macos")]
mod imp {
    use super::Window;
    pub use crate::disk_unix::{free_bytes, physical_memory, volume_bytes};
    pub use sq_platform_mac::install_fault_report;

    pub struct Badge(sq_platform_mac::DockProgress);

    impl Badge {
        pub fn new(_window: &Window) -> Badge {
            Badge(sq_platform_mac::DockProgress::default())
        }
        pub fn show(&mut self, percent: Option<u8>) {
            self.0.set(percent.map(|p| f64::from(p) / 100.0));
        }
    }

    pub use sq_platform_mac::SleepLock;
    pub use sq_platform_mac::{add_recent_document, install_open_handler};

    pub fn system_notifier(_window: &Window) -> Box<dyn crate::notify::Notifier> {
        struct Mac(sq_platform_mac::UserNotifier);
        impl crate::notify::Notifier for Mac {
            fn post(&mut self, n: &crate::notify::Notification) {
                self.0.post(&n.title, &n.body, n.reveal.as_deref());
            }
        }
        Box::new(Mac(sq_platform_mac::UserNotifier::new()))
    }
    pub fn app_is_active(_window: &Window) -> bool {
        sq_platform_mac::app_is_active()
    }
}

#[cfg(windows)]
mod imp {
    use super::Window;
    pub use sq_platform_win::{
        SleepLock, add_recent_document, free_bytes, install_fault_report, physical_memory, volume_bytes,
    };

    pub fn system_notifier(window: &Window) -> Box<dyn crate::notify::Notifier> {
        struct Balloon(sq_platform_win::BalloonNotifier);
        impl crate::notify::Notifier for Balloon {
            fn post(&mut self, n: &crate::notify::Notification) {
                self.0.post(&n.title, &n.body);
            }
        }
        // A WinRT toast whose click shows the file; the tray balloon when Windows refuses the toast.
        struct Toast(Option<sq_platform_win::ToastSender>);
        impl crate::notify::TryNotifier for Toast {
            fn try_post(&mut self, n: &crate::notify::Notification) -> bool {
                self.0.as_mut().is_some_and(|t| t.show(&crate::notify::toast_xml(n), n.reveal.clone()))
            }
        }
        let toast = std::env::current_exe().ok().and_then(|exe| sq_platform_win::ToastSender::new(&exe));
        Box::new(crate::notify::Fallback {
            primary: Toast(toast),
            fallback: Box::new(Balloon(sq_platform_win::BalloonNotifier::new(window))),
        })
    }
    pub fn app_is_active(_window: &Window) -> bool {
        sq_platform_win::app_is_active()
    }

    /// Windows hands a double clicked file over as a command line argument; nothing to install.
    pub fn install_open_handler(_sink: std::sync::mpsc::Sender<Option<std::path::PathBuf>>) {}

    pub struct Badge(sq_platform_win::TaskbarProgress);

    impl Badge {
        pub fn new(window: &Window) -> Badge {
            Badge(sq_platform_win::TaskbarProgress::new(window))
        }
        pub fn show(&mut self, percent: Option<u8>) {
            self.0.set(percent);
        }
    }
}

#[cfg(not(any(windows, target_os = "macos")))]
mod imp {
    use super::Window;
    use crate::FaultConfig;
    use std::path::Path;

    // The free-space probe is the shared unix `statvfs` one; the fault report, the launcher progress and the sleep lock
    // are Linux files of this crate (`fault_linux.rs`, `linux_power.rs`).
    #[cfg(unix)]
    pub use crate::disk_unix::{free_bytes, physical_memory, volume_bytes};
    #[cfg(not(unix))]
    pub fn free_bytes(_folder: &Path) -> Option<i64> {
        None
    }
    #[cfg(not(unix))]
    pub fn volume_bytes(_folder: &Path) -> (Option<i64>, Option<i64>) {
        (None, None)
    }
    #[cfg(not(unix))]
    pub fn physical_memory() -> Option<u64> {
        None
    }
    pub use crate::linux_power::SleepLock;
    pub fn install_fault_report(config: &FaultConfig) {
        #[cfg(target_os = "linux")]
        crate::fault_linux::install_fault_report(config);
        #[cfg(not(target_os = "linux"))]
        let _ = config;
    }
    pub struct Badge;
    impl Badge {
        pub fn new(_window: &Window) -> Badge {
            Badge
        }
        pub fn show(&mut self, percent: Option<u8>) {
            crate::linux_power::send_badge(percent);
        }
    }
    pub fn install_open_handler(_sink: std::sync::mpsc::Sender<Option<std::path::PathBuf>>) {}
    pub fn add_recent_document(_path: &Path) {}
    pub fn system_notifier(_window: &Window) -> Box<dyn crate::notify::Notifier> {
        Box::new(crate::notify::RecordingNotifier::default())
    }
    pub fn app_is_active(_window: &Window) -> bool {
        true
    }
}

pub use imp::{
    Badge, SleepLock, add_recent_document, free_bytes, install_fault_report, install_open_handler, physical_memory,
    volume_bytes,
};
pub(crate) use imp::{app_is_active, system_notifier};
