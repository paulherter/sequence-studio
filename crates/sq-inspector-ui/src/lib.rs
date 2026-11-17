//! Inspector panels of the draw UI (Swift `SQInspectorUI`). One module per area; each worker owns its folder.

pub mod audio_masks;
pub mod captions;
pub mod clip_sections;
pub mod color;
pub mod ec;
pub mod ec_draw;
pub mod graphics;
pub mod keyframes;
pub mod open_state;
pub mod text;

/// Test helper for the platform wording check: every title, shortcut and help of a menu built by a panel (and its submenus)
/// reads in the wording of the platform the test runs on, so off the Mac no row names the Command key or a Mac.
#[cfg(test)]
pub(crate) fn assert_menu_wording(menu: &str, items: &[sq_uikit::sqmenu_model::SQMenuItem]) {
    use sq_uikit::platform_wording::PlatformWording;
    let platform = sq_os::Platform::current();
    for i in items {
        let help = i.help.clone().unwrap_or_default();
        for text in [i.title.as_str(), i.shortcut.as_str(), help.as_str()] {
            assert_eq!(
                PlatformWording::adapt(text, platform),
                text,
                "{menu}: \"{text}\" is not in {platform:?} wording"
            );
            if platform != sq_os::Platform::Mac {
                assert!(!text.contains('\u{2318}'), "{menu}: \"{text}\" names the Command key off the Mac");
            }
        }
        if let Some(sub) = &i.submenu {
            assert_menu_wording(menu, sub);
        }
    }
}
