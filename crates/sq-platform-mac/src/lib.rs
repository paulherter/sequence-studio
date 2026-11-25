//! macOS-only services of the app (see the README). Empty on other systems.
#![cfg(target_os = "macos")]

mod clipboard;
mod color_space;
mod display;
mod dock;
mod emoji_shaping;
mod fault;
mod glass;
mod keyboard;
mod model;
mod notify;
mod open_file;
mod power;
mod reduce_motion;
mod system_watch;
mod title_bar_setting;
mod window_drag;

pub use clipboard::clipboard_facts;
pub use color_space::{layer_report, tag_surface_display_p3, tag_surface_srgb};
pub use display::{edr_values, max_edr_component_value};
pub use dock::DockProgress;
pub use emoji_shaping::install_emoji_sequence_shaper;
pub use fault::install_fault_report;
pub use glass::install_glass_clock;
pub use keyboard::active_keyboard;
pub use notify::{UserNotifier, app_is_active};
pub use open_file::{add_recent_document, install_open_handler, path_of_file_url};
pub use power::SleepLock;
pub use reduce_motion::reduce_motion;
pub use sq_fault_text::FaultConfig;
pub use system_watch::{DisplayLink, MacPower, MemoryPressureWatch, watch_main_run_loop, watch_power_changes};
pub use title_bar_setting::title_bar_double_click_setting;
pub use window_drag::keep_clicks_out_of_the_titlebar_drag;

pub use model::{NativeItem, NativeMenu, Role, Row, Shortcut, ShortcutKey, translate};

use muda::accelerator::{Key, KeyAccelerator, Modifiers, NamedKey};
use muda::{CheckMenuItem, IsMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use sq_draw_shell::ShellMenu;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

/// The system menu bar, built from the shell's menu model (the rows the drawn bar shows on Windows). Picked rows call the
/// row's own action, so a pick takes the path of a click in the drawn bar.
pub struct MenuBar {
    /// The installed bar; replacing it swaps the system menu.
    menu: Option<Menu>,
    shown: Vec<NativeMenu>,
    actions: Vec<Option<Rc<dyn Fn()>>>,
    picked: Arc<Mutex<Vec<usize>>>,
    /// A pick may have toggled a check the model did not change: rebuild once more.
    stale: bool,
}

impl MenuBar {
    /// Prepares the bar; `wake` runs on the main thread when a row is picked so the loop calls [`MenuBar::run_picked`].
    /// Call on the main thread once the event loop runs, then [`MenuBar::update`].
    pub fn install(wake: impl Fn() + Send + Sync + 'static) -> MenuBar {
        let picked = Arc::new(Mutex::new(Vec::new()));
        let queue = Arc::clone(&picked);
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            if let Ok(slot) = e.id().0.parse::<usize>() {
                queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(slot);
                wake();
            }
        }));
        MenuBar { menu: None, shown: Vec::new(), actions: Vec::new(), picked, stale: false }
    }

    /// Shows `menus`; the system bar is rebuilt only when titles, shortcuts, enabled or checked state differ.
    pub fn update(&mut self, menus: &[ShellMenu]) {
        let (native, actions) = translate(menus);
        self.actions = actions;
        if self.menu.is_some() && !self.stale && native == self.shown {
            return;
        }
        match build(&native) {
            Ok(menu) => {
                menu.init_for_nsapp();
                self.menu = Some(menu);
                self.shown = native;
                self.stale = false;
            }
            Err(e) => eprintln!("menu bar: {e}"),
        }
    }

    /// Runs the actions of the rows picked since the last call; true when there were any.
    pub fn run_picked(&mut self) -> bool {
        let slots = std::mem::take(&mut *self.picked.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        for &slot in &slots {
            if let Some(Some(action)) = self.actions.get(slot) {
                action();
            }
        }
        self.stale |= !slots.is_empty();
        !slots.is_empty()
    }
}

fn build(menus: &[NativeMenu]) -> Result<Menu, muda::Error> {
    let menu = Menu::new();
    for m in menus {
        let sub = Submenu::new(&m.title, true);
        fill(&sub, &m.items)?;
        menu.append(&sub)?;
        if m.title == "Help" {
            sub.set_as_help_menu_for_nsapp();
        }
    }
    Ok(menu)
}

fn fill(sub: &Submenu, items: &[NativeItem]) -> Result<(), muda::Error> {
    for item in items {
        match item {
            NativeItem::Separator => sub.append(&PredefinedMenuItem::separator())?,
            NativeItem::Header(title) => sub.append(&MenuItem::new(title, false, None))?,
            NativeItem::Sub { title, enabled, items } => {
                let inner = Submenu::new(title, *enabled);
                fill(&inner, items)?;
                sub.append(&inner)?;
            }
            NativeItem::Row(row) => {
                let item: Box<dyn IsMenuItem> = row_item(row);
                sub.append(item.as_ref())?;
            }
        }
    }
    Ok(())
}

fn row_item(row: &Row) -> Box<dyn IsMenuItem> {
    let text = Some(row.title.as_str());
    match row.role {
        Role::Hide => return Box::new(PredefinedMenuItem::hide(text)),
        Role::HideOthers => return Box::new(PredefinedMenuItem::hide_others(text)),
        Role::ShowAll => return Box::new(PredefinedMenuItem::show_all(text)),
        Role::Minimize => return Box::new(PredefinedMenuItem::minimize(text)),
        Role::Zoom => return Box::new(PredefinedMenuItem::zoom(text)),
        Role::BringAllToFront => return Box::new(PredefinedMenuItem::bring_all_to_front(text)),
        Role::Action => {}
    }
    let id = row.slot.to_string();
    let accel = row.shortcut.map(accelerator);
    if row.checked {
        let item = CheckMenuItem::with_id(id, &row.title, row.enabled, true, None);
        let _ = item.set_key_accelerator(accel);
        Box::new(item)
    } else {
        let item = MenuItem::with_id(id, &row.title, row.enabled, None);
        let _ = item.set_key_accelerator(accel);
        Box::new(item)
    }
}

fn accelerator(s: Shortcut) -> KeyAccelerator {
    let mut mods = Modifiers::empty();
    for (on, m) in [
        (s.control, Modifiers::CONTROL),
        (s.option, Modifiers::ALT),
        (s.shift, Modifiers::SHIFT),
        (s.command, Modifiers::META),
    ] {
        if on {
            mods |= m;
        }
    }
    let key = match s.key {
        ShortcutKey::Char(c) => Key::Character(c.to_string()),
        ShortcutKey::Space => Key::Character(" ".into()),
        ShortcutKey::Left => Key::Named(NamedKey::ArrowLeft),
        ShortcutKey::Right => Key::Named(NamedKey::ArrowRight),
        ShortcutKey::Up => Key::Named(NamedKey::ArrowUp),
        ShortcutKey::Down => Key::Named(NamedKey::ArrowDown),
        ShortcutKey::Home => Key::Named(NamedKey::Home),
        ShortcutKey::End => Key::Named(NamedKey::End),
        ShortcutKey::PageUp => Key::Named(NamedKey::PageUp),
        ShortcutKey::PageDown => Key::Named(NamedKey::PageDown),
        ShortcutKey::Delete => Key::Named(NamedKey::Backspace),
        ShortcutKey::Return => Key::Named(NamedKey::Enter),
        ShortcutKey::ForwardDelete => Key::Named(NamedKey::Delete),
        ShortcutKey::Function(n) => Key::Named(function_key(n)),
    };
    KeyAccelerator::new(mods, key)
}

fn function_key(n: i64) -> NamedKey {
    match n {
        1 => NamedKey::F1,
        2 => NamedKey::F2,
        3 => NamedKey::F3,
        4 => NamedKey::F4,
        5 => NamedKey::F5,
        6 => NamedKey::F6,
        7 => NamedKey::F7,
        8 => NamedKey::F8,
        9 => NamedKey::F9,
        10 => NamedKey::F10,
        11 => NamedKey::F11,
        _ => NamedKey::F12,
    }
}
