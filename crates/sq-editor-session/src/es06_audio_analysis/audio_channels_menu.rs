// Swift: AudioChannelsMenu.swift
//! The "Audio Channels" rows of a Project item's menu (source settings): which channels of the file the item's clips
//! play. Pure: builds SQ rows, the panel applies the picked map.

use std::rc::Rc;

use sq_core_model::AudioChannelMap;
use sq_uikit::sqmenu_model::SQMenuItem;

/// Rows of the Audio Channels menu.
// Swift: AudioChannelsMenu.swift:6
pub enum AudioChannelsMenu {}

impl AudioChannelsMenu {
    /// Up to this many channels every pair is offered; beyond it only the neighbors (1 + 2, 3 + 4, ...), so a
    /// 16-channel file does not open a list of 120 pairs.
    const ALL_PAIRS_LIMIT: i64 = 4;

    /// Channel pairs offered for Stereo and Dual Mono (0-based, first < second).
    pub(crate) fn pairs(channels: i64) -> Vec<(i64, i64)> {
        if channels < 2 {
            return Vec::new();
        }
        if channels <= Self::ALL_PAIRS_LIMIT {
            return (0..channels).flat_map(|a| ((a + 1)..channels).map(move |b| (a, b))).collect();
        }
        (0..channels - 1).step_by(2).map(|a| (a, a + 1)).collect()
    }

    /// Rows for a file with `channels` channels; `current` is the item's map (`None` = the file's layout). Empty for
    /// files with fewer than two channels: there is nothing to choose.
    // Swift: AudioChannelsMenu.swift:21
    pub fn items(
        channels: i64,
        current: Option<&AudioChannelMap>,
        pick: Rc<dyn Fn(Option<AudioChannelMap>)>,
    ) -> Vec<SQMenuItem> {
        if channels < 2 {
            return Vec::new();
        }
        let row = |title: &str, map: Option<AudioChannelMap>| {
            let mut i = SQMenuItem::new(title);
            i.is_checked = map.is_some() && map.as_ref() == current;
            let pick = Rc::clone(&pick);
            i.action = Some(Rc::new(move || pick(map.clone())));
            i
        };
        let mono: Vec<SQMenuItem> =
            (0..channels).map(|c| row(&format!("Channel {}", c + 1), AudioChannelMap::mono(c))).collect();
        let all = Self::pairs(channels);
        let stereo: Vec<SQMenuItem> =
            all.iter().map(|(a, b)| row(&format!("{} + {}", a + 1, b + 1), AudioChannelMap::stereo(*a, *b))).collect();
        let dual: Vec<SQMenuItem> = all
            .iter()
            .map(|(a, b)| row(&format!("{} + {}", a + 1, b + 1), AudioChannelMap::dual_mono(*a, *b)))
            .collect();
        let group = |title: &str, rows: Vec<SQMenuItem>| {
            let mut g = SQMenuItem::new(title);
            g.is_checked = rows.iter().any(|r| r.is_checked);
            g.submenu = Some(rows);
            g
        };
        let mut file_layout = row("File Layout", None);
        file_layout.is_checked = current.is_none();
        vec![
            file_layout,
            SQMenuItem::separator(),
            group("Mono", mono),
            group("Stereo", stereo),
            group("Dual Mono", dual),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_files_offer_every_pair_big_ones_the_neighbors() {
        assert_eq!(AudioChannelsMenu::pairs(1), vec![]);
        assert_eq!(AudioChannelsMenu::pairs(3), vec![(0, 1), (0, 2), (1, 2)]);
        assert_eq!(AudioChannelsMenu::pairs(6), vec![(0, 1), (2, 3), (4, 5)]);
    }

    #[test]
    fn rows_check_the_current_map() {
        let pick: Rc<dyn Fn(Option<AudioChannelMap>)> = Rc::new(|_| {});
        assert!(AudioChannelsMenu::items(1, None, Rc::clone(&pick)).is_empty());
        let cur = AudioChannelMap::stereo(0, 1);
        let rows = AudioChannelsMenu::items(2, cur.as_ref(), Rc::clone(&pick));
        assert!(!rows[0].is_checked); // File Layout is not the current one
        let stereo = rows[3].submenu.as_ref().expect("stereo group");
        assert!(rows[3].is_checked && stereo[0].is_checked);
        let none = AudioChannelsMenu::items(2, None, pick);
        assert!(none[0].is_checked && !none[2].is_checked);
    }
}
