// Swift: SharedUIController+Jobs.swift `ExportNotifier.post/requestOnce`, MacShell/ExportNotificationDelegate.swift
//! "Export finished" and other notifications through UserNotifications. As in Swift: only an app with a bundle
//! identifier posts (a bare binary has none), the system permission is asked once, a click on a finished export shows the
//! file in Finder (its folder when the file is gone).

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, NSObject};
use objc2::{ClassType, define_class, msg_send};
use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};

#[link(name = "UserNotifications", kind = "framework")]
unsafe extern "C" {}

const PATH_KEY: &CStr = c"sq.export.path";

fn nsstring(s: &str) -> *mut AnyObject {
    let Some(class) = AnyClass::get(c"NSString") else { return std::ptr::null_mut() };
    let Ok(c) = CString::new(s.replace('\0', "")) else { return std::ptr::null_mut() };
    // SAFETY: `stringWithUTF8String:` copies the NUL terminated string and returns an autoreleased NSString.
    unsafe { msg_send![class, stringWithUTF8String: c.as_ptr()] }
}

fn string_of(value: *mut AnyObject) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // SAFETY: `value` is an NSString (checked by the caller's key); `UTF8String` is valid while it lives, copied at once.
    unsafe {
        let c: *const c_char = msg_send![value, UTF8String];
        (!c.is_null()).then(|| CStr::from_ptr(c).to_string_lossy().into_owned())
    }
}

/// Shows `file` in Finder, or its folder when it is gone.
fn reveal(file: &Path) {
    let (target, is_file) = if file.exists() {
        (file.to_path_buf(), true)
    } else {
        (file.parent().map(Path::to_path_buf).unwrap_or_default(), false)
    };
    let (Some(workspace_class), Some(url_class), Some(array_class)) =
        (AnyClass::get(c"NSWorkspace"), AnyClass::get(c"NSURL"), AnyClass::get(c"NSArray"))
    else {
        return;
    };
    // SAFETY: main thread (the delegate runs on it); plain constructors and the two documented NSWorkspace calls.
    unsafe {
        let url: *mut AnyObject = msg_send![url_class, fileURLWithPath: nsstring(&target.to_string_lossy())];
        let workspace: *mut AnyObject = msg_send![workspace_class, sharedWorkspace];
        if url.is_null() || workspace.is_null() {
            return;
        }
        if is_file {
            let list: *mut AnyObject = msg_send![array_class, arrayWithObject: url];
            let () = msg_send![workspace, activateFileViewerSelectingURLs: list];
        } else {
            let _: bool = msg_send![workspace, openURL: url];
        }
    }
}

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "SQNotificationDelegate"]
    struct NotificationDelegate;

    impl NotificationDelegate {
        #[unsafe(method(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:))]
        fn did_receive(&self, _center: &AnyObject, response: &AnyObject, done: &block2::Block<dyn Fn()>) {
            // SAFETY: `response` is the UNNotificationResponse; its notification's request content carries our userInfo.
            let path = unsafe {
                let notification: *mut AnyObject = msg_send![response, notification];
                let request: *mut AnyObject = msg_send![notification, request];
                let content: *mut AnyObject = msg_send![request, content];
                let info: *mut AnyObject = msg_send![content, userInfo];
                let value: *mut AnyObject = msg_send![info, objectForKey: nsstring(&PATH_KEY.to_string_lossy())];
                string_of(value)
            };
            if let Some(p) = path {
                reveal(&PathBuf::from(p));
            }
            done.call(());
        }

        // Show the banner also when the app is in front (our own rule decides when to post at all).
        #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
        fn will_present(&self, _center: &AnyObject, _n: &AnyObject, done: &block2::Block<dyn Fn(usize)>) {
            done.call((26,)); // banner (16) | list (8) | sound (2)
        }
    }
);

/// UserNotifications for this app. Main thread only.
pub struct UserNotifier {
    asked: bool,
    /// The delegate must outlive the center's weak reference.
    delegate: Option<Retained<AnyObject>>,
}

impl UserNotifier {
    pub fn new() -> UserNotifier {
        UserNotifier { asked: false, delegate: None }
    }

    fn center() -> Option<*mut AnyObject> {
        let class = AnyClass::get(c"UNUserNotificationCenter")?;
        // SAFETY: `currentNotificationCenter` raises for a process without a bundle: guarded by `has_bundle`.
        let center: *mut AnyObject = unsafe { msg_send![class, currentNotificationCenter] };
        (!center.is_null()).then_some(center)
    }

    fn has_bundle() -> bool {
        let Some(class) = AnyClass::get(c"NSBundle") else { return false };
        // SAFETY: plain getters on the main bundle.
        unsafe {
            let bundle: *mut AnyObject = msg_send![class, mainBundle];
            !bundle.is_null()
                && !{
                    let id: *mut AnyObject = msg_send![bundle, bundleIdentifier];
                    id
                }
                .is_null()
        }
    }

    fn ask_once(&mut self, center: *mut AnyObject) {
        if self.asked {
            return;
        }
        self.asked = true;
        // SAFETY: the delegate object is kept in `self`; `requestAuthorization` takes options (alert | sound) and a block.
        unsafe {
            let delegate: Retained<AnyObject> = msg_send![NotificationDelegate::class(), new];
            let () = msg_send![center, setDelegate: &*delegate];
            self.delegate = Some(delegate);
            let handler = RcBlock::new(|_granted: objc2::runtime::Bool, _error: Option<&AnyObject>| {});
            let () = msg_send![center, requestAuthorizationWithOptions: 0b110usize, completionHandler: &*handler];
        }
    }
}

impl Default for UserNotifier {
    fn default() -> Self {
        Self::new()
    }
}

impl UserNotifier {
    /// Posts one notification; a click shows `reveal` in Finder. A process without a bundle identifier posts nothing.
    pub fn post(&mut self, title: &str, body: &str, reveal: Option<&Path>) {
        if !Self::has_bundle() {
            return;
        }
        let (Some(center), Some(content_class), Some(request_class), Some(dict_class), Some(sound_class)) = (
            Self::center(),
            AnyClass::get(c"UNMutableNotificationContent"),
            AnyClass::get(c"UNNotificationRequest"),
            AnyClass::get(c"NSDictionary"),
            AnyClass::get(c"UNNotificationSound"),
        ) else {
            return;
        };
        self.ask_once(center);
        // SAFETY: main thread; plain setters on a fresh mutable content, a request without trigger (delivered now) and
        // `addNotificationRequest:withCompletionHandler:` with no handler (nullable).
        unsafe {
            let content: Retained<AnyObject> = msg_send![content_class, new];
            let () = msg_send![&*content, setTitle: nsstring(title)];
            let () = msg_send![&*content, setBody: nsstring(body)];
            let sound: *mut AnyObject = msg_send![sound_class, defaultSound];
            let () = msg_send![&*content, setSound: sound];
            if let Some(file) = reveal {
                let info: *mut AnyObject = msg_send![dict_class, dictionaryWithObject: nsstring(&file.to_string_lossy()),
                    forKey: nsstring(&PATH_KEY.to_string_lossy())];
                let () = msg_send![&*content, setUserInfo: info];
            }
            let id = nsstring(&format!(
                "sq-{}",
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos())
            ));
            let request: *mut AnyObject = msg_send![request_class, requestWithIdentifier: id, content: &*content, trigger: std::ptr::null::<AnyObject>()];
            let none: *const AnyObject = std::ptr::null();
            let () = msg_send![center, addNotificationRequest: request, withCompletionHandler: none];
        }
    }
}

/// Whether this app is the active (front) application.
pub fn app_is_active() -> bool {
    let Some(class) = AnyClass::get(c"NSApplication") else { return true };
    // SAFETY: `sharedApplication` and `isActive` on the main thread.
    unsafe {
        let app: *mut AnyObject = msg_send![class, sharedApplication];
        !app.is_null() && msg_send![app, isActive]
    }
}
