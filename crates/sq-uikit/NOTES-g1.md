# sq-uikit group g1 notes

Ported: design_tokens (golden from `oracle/sq-uikit/run.sh`), scrub_math, sqfont_field_model, keyframe_control_state, sqicon,
ease_curve_source, autosave_version_label, localization, zoom_scroll_bar_gesture (with `KeyframeZoomBarGeometry`),
command_map, menu_spec, command_support, key_group, key_glyph, key_binding_text (with `WindowsKeyRoute`), menu_keys, panel_cycle.
The German catalog is copied to `resources/Localization/de.lproj/Localizable.strings` and read with `parse_strings`.

## Shapes other modules rely on
- `SQL10n` is the process-wide front (`SQL10n::string(key)`, `format(fmt, &[&str])`, `localized(text)`, `plural` lives in
  localization_counts). Language variants are `string_in`, `format_in`, `localized_in`; `SQL10n::install(lang)` once at launch,
  otherwise English unless `SQ_LANGUAGE` is set. Instance form: `Catalogs` (tests, several languages side by side). The key lists
  are `SQL10n::CHROME_KEYS / SETTINGS_KEYS / DIALOG_KEYS`; `SQL10n::required_keys()`.
  localization_counts (g3) was written against `string(key, Option<&str>)` / `format(fmt, args, Option<&str>)`; it must call the
  `*_in` forms (or drop the `None`). Same for keymap_import (`format(.., None)`).
- `CommandMap`: `pub entries: Vec<Entry>`, `command_for(&KeyBinding, Option<PanelID>)`, `binding_for(&EditorCommand)`,
  `duplicates()`, `premiere_default()`, `sq_default()` (needs `keymap_store::{Keymap, KeymapOverride}`), `current()` / `set_current()`.
- `CommandSupport::is_*(&EditorCommand)`, `KeyGroup::of(&EditorCommand)`, `KeyBindingText::{text, mac, windows}(&KeyBinding, ..)`,
  `EditorMenus::{all, visible, file, ...}() -> &'static [MenuSpec]` / `MenuSpec`, `ScrubMath::*` (namespace enum).
- `UiDefaults` (appearance_palette) is the one injected settings store; the font recents use it too.
- Cargo.toml: added `sq-core-edit`, `sq-core-effects`, `sq-core-graphics` (menu parameters). g2 needs the same plus `sq-core-file`,
  `sq-core-project`.

## Ownership (PORTING section 11)
| field | owner | lifetime | shared-by |
|---|---|---|---|
| `command_map::CURRENT` (`Mutex<Option<CommandMap>>`) | `CommandMap::set_current` | process | readers clone the map (`current()`) |
| `command_map` premiere/sq default (`OnceLock<CommandMap>`) | first caller | process | clones |
| `localization::GLOBAL` (`OnceLock<Catalogs>`) | first caller / `SQL10n::install` | process | read-only |
| `menu_spec` lists and sets (`OnceLock`) | first caller | process | read-only |

## Deviations and shortcuts
- `autosave_version_label` takes the formatted absolute date from the shell and always uses the English "12 min. ago" wording
  (the Swift non-Mac branch); the Mac RelativeDateTimeFormatter branch is not ported.
- `SQL10n` replaces `Bundle.module`, `UserDefaults` and `Locale.preferredLanguages` reads by `install` and `selected_language(env, stored,
  is_app_bundle, preferred)`. `SQL10n.errorText` takes any `Error` (its Display), not `LocalizedError`.
- Pattern keys (`%@`) are matched by a small backtracking matcher equal to the Swift regex `^p0(.+?)p1...$` (dot matches newline);
  tie order of equal-length patterns follows the sorted key order, Swift's depends on dictionary order.
- `sqfont_field_model::fold` strips Latin-1 accents only (shortcut noted in code).
- `format_string` knows `%@`, `%%` and the integer forms; other printf specifiers are copied.
- Mac-only pieces: none in this group.

## Waiting on
Nothing: the merge is done; the cross-module tests live in `tests/command_tables.rs`. `AppMenuLiteralTests` (scans Swift sources) is not portable.
