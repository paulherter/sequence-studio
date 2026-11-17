//! Open With and double click on a project: Launch Services sends the running app an Apple Event ("open documents"),
//! winit 0.30 has no hook for it, so the handler is registered here with `NSAppleEventManager`. Also the Dock's and the
//! File menu's recent documents (`NSDocumentController.noteNewRecentDocumentURL:`).

use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, NSObject};
use objc2::{ClassType, define_class, msg_send, sel};
use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::mpsc::Sender;

type Sink = Sender<Option<PathBuf>>;

static SINK: Mutex<Option<Sink>> = Mutex::new(None);

/// 'aevt' / 'odoc' (kCoreEventClass / kAEOpenDocuments), '----' (keyDirectObject), 'rapp' (kAEReopenApplication).
const CORE_EVENT: u32 = 0x6165_7674;
const OPEN_DOCUMENTS: u32 = 0x6F64_6F63;
const REOPEN: u32 = 0x7261_7070;
const DIRECT_OBJECT: u32 = 0x2D2D_2D2D;

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "SQOpenDocumentsHandler"]
    struct OpenHandler;

    impl OpenHandler {
        #[unsafe(method(handleOpen:withReply:))]
        fn handle_open(&self, event: &AnyObject, _reply: &AnyObject) {
            for path in paths_of(event) {
                send(Some(path));
            }
        }

        #[unsafe(method(handleReopen:withReply:))]
        fn handle_reopen(&self, _event: &AnyObject, _reply: &AnyObject) {
            send(None);
        }
    }
);

fn send(path: Option<PathBuf>) {
    if let Ok(slot) = SINK.lock()
        && let Some(tx) = slot.as_ref()
    {
        let _ = tx.send(path);
    }
}

/// The file URLs an "open documents" event carries.
fn paths_of(event: &AnyObject) -> Vec<PathBuf> {
    // SAFETY: `event` is the live NSAppleEventDescriptor AppKit passed to the handler; every call below is a plain
    // getter on it or on the descriptors it returns (nil-checked), on the main thread.
    unsafe {
        let list: *mut AnyObject = msg_send![event, paramDescriptorForKeyword: DIRECT_OBJECT];
        if list.is_null() {
            return Vec::new();
        }
        let count: isize = msg_send![list, numberOfItems];
        let items: Vec<*mut AnyObject> =
            if count == 0 { vec![list] } else { (1..=count).map(|i| msg_send![list, descriptorAtIndex: i]).collect() };
        items.into_iter().filter_map(|d| url_path(d)).collect()
    }
}

/// `file:///a/b%20c.sqproj` of a descriptor's string value as a path.
unsafe fn url_path(descriptor: *mut AnyObject) -> Option<PathBuf> {
    if descriptor.is_null() {
        return None;
    }
    // SAFETY: the caller's contract: a live descriptor; `stringValue` is nil or an NSString, `UTF8String` a C string
    // that lives as long as that string (copied out at once).
    let text = unsafe {
        let value: *mut AnyObject = msg_send![descriptor, stringValue];
        if value.is_null() {
            return None;
        }
        let c: *const c_char = msg_send![value, UTF8String];
        if c.is_null() {
            return None;
        }
        CStr::from_ptr(c).to_string_lossy().into_owned()
    };
    path_of_file_url(&text)
}

/// `file://[host]/path` with percent escapes decoded; `None` for anything else.
pub fn path_of_file_url(url: &str) -> Option<PathBuf> {
    let rest = url.strip_prefix("file://")?;
    let path = &rest[rest.find('/')?..];
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(v) = u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?, 16)
        {
            out.push(v);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok().map(PathBuf::from)
}

/// Routes the system's open-document and reopen requests to `sink` (`Some(path)` to open, `None` to raise the window).
/// Call once the app finished launching, on the main thread: AppKit installs its own handler before that.
pub fn install_open_handler(sink: Sink) {
    if let Ok(mut slot) = SINK.lock() {
        *slot = Some(sink);
    }
    let Some(manager_class) = AnyClass::get(c"NSAppleEventManager") else { return };
    // SAFETY: main thread; the handler object is leaked on purpose (the manager does not retain its target), and the
    // selectors exist on it (defined above).
    unsafe {
        let manager: *mut AnyObject = msg_send![manager_class, sharedAppleEventManager];
        if manager.is_null() {
            return;
        }
        let handler: Retained<AnyObject> = msg_send![OpenHandler::class(), new];
        let target: *const AnyObject = Retained::into_raw(handler);
        let () = msg_send![manager, setEventHandler: target, andSelector: sel!(handleOpen:withReply:),
            forEventClass: CORE_EVENT, andEventID: OPEN_DOCUMENTS];
        let () = msg_send![manager, setEventHandler: target, andSelector: sel!(handleReopen:withReply:),
            forEventClass: CORE_EVENT, andEventID: REOPEN];
    }
}

/// Puts `path` into the Dock menu's and File > Open Recent's system list.
pub fn add_recent_document(path: &Path) {
    let (Some(url_class), Some(controller_class), Some(string_class)) =
        (AnyClass::get(c"NSURL"), AnyClass::get(c"NSDocumentController"), AnyClass::get(c"NSString"))
    else {
        return;
    };
    let Ok(c) = CString::new(path.to_string_lossy().as_bytes()) else { return };
    // SAFETY: main thread; the strings and the URL are autoreleased, `noteNewRecentDocumentURL:` takes an NSURL.
    unsafe {
        let string: *mut AnyObject = msg_send![string_class, stringWithUTF8String: c.as_ptr()];
        let url: *mut AnyObject = msg_send![url_class, fileURLWithPath: string];
        let controller: *mut AnyObject = msg_send![controller_class, sharedDocumentController];
        if !url.is_null() && !controller.is_null() {
            let () = msg_send![controller, noteNewRecentDocumentURL: url];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_url_becomes_a_path_with_escapes_decoded() {
        assert_eq!(
            path_of_file_url("file:///Users/p/My%20Film.sqproj"),
            Some(PathBuf::from("/Users/p/My Film.sqproj"))
        );
        assert_eq!(path_of_file_url("file://localhost/a/b.sqproj"), Some(PathBuf::from("/a/b.sqproj")));
        assert_eq!(path_of_file_url("https://x/a"), None);
    }
}
