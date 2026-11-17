// Swift: MenuOutline.swift
//! A menu as text for the parity audit: one line per row (kind, title, key, disabled, checked, icon), submenus indented.
//! The format is the Swift one byte for byte, so `diff` of a Swift and a Rust dump lists the differences.

use crate::sqmenu_model::{SQMenuIcon, SQMenuItem, SQMenuItemKind};

/// The outline of `items`, `depth` levels indented.
pub fn menu_outline(items: &[SQMenuItem], depth: usize) -> String {
    let mut out = String::new();
    let pad = "  ".repeat(depth);
    for i in items {
        match i.kind {
            SQMenuItemKind::Separator => {
                out.push_str(&format!("{pad}---\n"));
                continue;
            }
            SQMenuItemKind::Header => {
                out.push_str(&format!("{pad}# {}\n", i.title));
                continue;
            }
            SQMenuItemKind::Caption => {
                out.push_str(&format!("{pad}~ {}\n", i.title));
                continue;
            }
            SQMenuItemKind::Action => {}
        }
        let mut line = format!("{pad}{}", i.title);
        if !i.shortcut.is_empty() {
            line.push_str(&format!("  [{}]", i.shortcut));
        }
        if !i.is_enabled {
            line.push_str("  (off)");
        }
        if i.is_checked {
            line.push_str("  (x)");
        }
        match &i.icon {
            SQMenuIcon::None => {}
            SQMenuIcon::Symbol(s) => line.push_str(&format!("  <{}>", s.raw_value())),
            SQMenuIcon::Swatch(c) => line.push_str(&format!("  <#{c:x}>")),
            _ => line.push_str("  <icon>"),
        }
        if let Some(s) = i.leading_symbol {
            line.push_str(&format!("  <lead {}>", s.raw_value()));
        }
        out.push_str(&line);
        out.push('\n');
        if let Some(sub) = &i.submenu {
            out.push_str(&menu_outline(sub, depth + 1));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_print_key_state_and_nest_submenus_like_the_swift_outline() {
        let mut copy = SQMenuItem::new("Copy");
        copy.shortcut = "⌘C".into();
        let mut paste = SQMenuItem::new("Paste");
        paste.is_enabled = false;
        let mut grid = SQMenuItem::new("Grid");
        grid.is_checked = true;
        let mut label = SQMenuItem::new("Label");
        label.submenu = Some(vec![SQMenuItem::new("Red")]);
        let items = vec![copy, paste, SQMenuItem::separator(), SQMenuItem::header("View"), grid, label];
        assert_eq!(menu_outline(&items, 0), "Copy  [⌘C]\nPaste  (off)\n---\n# View\nGrid  (x)\nLabel\n  Red\n");
    }
}
