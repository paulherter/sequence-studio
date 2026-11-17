// Swift: TextAnimatorChoices.swift
//! The choices of the text animator rows (Animation section: In / Out by character, word or line) and the Look menu.

use std::rc::Rc;

use sq_core_model::anchored_animation::{
    SegmentShape, TextAnimator, TextAnimatorEffect, TextAnimatorOrder, TextAnimatorUnit, TextSlideDirection,
};
use sq_core_time::Id;
use sq_core_time::ease_names::ease_name;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

/// Which controls of an animator side take input.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    Effect,
    Unit,
    Easing,
    Direction,
    Order,
    Stagger,
    Length,
    Distance,
    Blur,
    Loops,
}

impl Control {
    /// Every control, in declaration order.
    pub const ALL: [Control; 10] = [
        Control::Effect,
        Control::Unit,
        Control::Easing,
        Control::Direction,
        Control::Order,
        Control::Stagger,
        Control::Length,
        Control::Distance,
        Control::Blur,
        Control::Loops,
    ];
}

/// The choices of the text animator rows, shared by every text block so they list the same entries in the same order.
pub enum TextAnimatorChoices {}

impl TextAnimatorChoices {
    /// A new animator's unit length (TextInspectorModel creates it with 0.3 s); the Length field's reset target.
    pub const DEFAULT_DURATION_MILLISECONDS: i64 = 300;
    /// The Stagger field's reset when no animator is set (by word).
    pub const DEFAULT_STAGGER_MILLISECONDS: i64 = 80;
    /// Saved title templates join the Look popup under this id prefix and with " (Template)" after their name.
    pub const TEMPLATE_ID_PREFIX: &'static str = "template:";

    pub fn effects() -> [(&'static str, Option<TextAnimatorEffect>); 8] {
        [
            ("None", None),
            ("Fade", Some(TextAnimatorEffect::Fade)),
            ("Pop", Some(TextAnimatorEffect::Pop)),
            ("Slide", Some(TextAnimatorEffect::Slide)),
            ("Typewriter", Some(TextAnimatorEffect::Typewriter)),
            ("Blur", Some(TextAnimatorEffect::Blur)),
            ("Wave (Loop)", Some(TextAnimatorEffect::Wave)),
            ("Pulse (Loop)", Some(TextAnimatorEffect::Pulse)),
        ]
    }

    pub fn units() -> [(&'static str, TextAnimatorUnit); 3] {
        [
            ("By Character", TextAnimatorUnit::Character),
            ("By Word", TextAnimatorUnit::Word),
            ("By Line", TextAnimatorUnit::Line),
        ]
    }

    pub fn directions() -> [(&'static str, TextSlideDirection); 4] {
        [
            ("Up", TextSlideDirection::Up),
            ("Down", TextSlideDirection::Down),
            ("Left", TextSlideDirection::Left),
            ("Right", TextSlideDirection::Right),
        ]
    }

    pub fn easings() -> [(&'static str, SegmentShape); 5] {
        [
            (ease_name::STEADY, SegmentShape::Linear),
            (ease_name::SMOOTH, SegmentShape::EaseInOut),
            (ease_name::SMOOTH_IN, SegmentShape::EaseIn),
            (ease_name::SMOOTH_OUT, SegmentShape::EaseOut),
            ("Overshoot", SegmentShape::Overshoot),
        ]
    }

    pub fn orders() -> [(&'static str, TextAnimatorOrder); 3] {
        [
            ("Forward", TextAnimatorOrder::Forward),
            ("Reverse", TextAnimatorOrder::Reverse),
            ("From Center", TextAnimatorOrder::Center),
        ]
    }

    /// Which controls of an animator side take input: everything but the effect needs an animator; Length not for
    /// Typewriter (each unit appears at once), Direction and Distance for Slide and Wave, Loops for the loop effects,
    /// Blur for Blur.
    pub fn is_enabled(c: Control, a: Option<&TextAnimator>) -> bool {
        let effect = a.map(|a| a.effect);
        match c {
            Control::Effect => true,
            Control::Unit | Control::Easing | Control::Order | Control::Stagger => a.is_some(),
            Control::Length => a.is_some() && effect != Some(TextAnimatorEffect::Typewriter),
            Control::Direction | Control::Distance => {
                effect == Some(TextAnimatorEffect::Slide) || effect == Some(TextAnimatorEffect::Wave)
            }
            Control::Loops => effect.is_some_and(TextAnimatorEffect::is_loop),
            Control::Blur => effect == Some(TextAnimatorEffect::Blur),
        }
    }

    /// Right-click on the Look popup: Update / Save as New / Rename / Delete for an editable Look (`name`), only Save
    /// as New for a built-in one or none.
    pub fn look_menu_items(
        editable: Option<&str>,
        update: Rc<dyn Fn()>,
        save_new: Rc<dyn Fn()>,
        rename: Rc<dyn Fn()>,
        delete: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        let item = |title: &str, action: Rc<dyn Fn()>| {
            let mut i = SQMenuItem::new(title);
            i.action = Some(action);
            i
        };
        let save = item("Save as New Look\u{2026}", save_new);
        let Some(name) = editable else { return vec![save] };
        let mut update_item = SQMenuItem::new("Update");
        update_item.title = SQL10n::format("Update \u{201C}%@\u{201D}", &[name]);
        update_item.action = Some(update);
        vec![update_item, save, item("Rename\u{2026}", rename), item("Delete", delete)]
    }

    pub fn template_title(name: &str) -> String {
        format!("{name} (Template)")
    }

    /// The template id inside a Look popup token (`template:<uuid>`).
    pub fn template_id(token: &str) -> Option<Id> {
        Id::parse(token.strip_prefix(Self::TEMPLATE_ID_PREFIX)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn animator(effect: TextAnimatorEffect) -> TextAnimator {
        TextAnimator::new(effect, TextAnimatorUnit::Word, Time::new(3, 10), Time::new(2, 25))
    }

    #[test]
    fn controls_follow_the_effect() {
        assert!(TextAnimatorChoices::is_enabled(Control::Effect, None));
        assert!(!TextAnimatorChoices::is_enabled(Control::Unit, None));
        let typewriter = animator(TextAnimatorEffect::Typewriter);
        assert!(!TextAnimatorChoices::is_enabled(Control::Length, Some(&typewriter)));
        let slide = animator(TextAnimatorEffect::Slide);
        assert!(TextAnimatorChoices::is_enabled(Control::Direction, Some(&slide)));
        assert!(!TextAnimatorChoices::is_enabled(Control::Loops, Some(&slide)));
        assert!(TextAnimatorChoices::is_enabled(Control::Loops, Some(&animator(TextAnimatorEffect::Pulse))));
        assert!(TextAnimatorChoices::is_enabled(Control::Blur, Some(&animator(TextAnimatorEffect::Blur))));
    }

    #[test]
    fn look_menu_lists_four_rows_for_an_editable_look() {
        let noop: Rc<dyn Fn()> = Rc::new(|| {});
        let titles = |name| {
            TextAnimatorChoices::look_menu_items(
                name,
                Rc::clone(&noop),
                Rc::clone(&noop),
                Rc::clone(&noop),
                Rc::clone(&noop),
            )
            .into_iter()
            .map(|i| i.title)
            .collect::<Vec<_>>()
        };
        assert_eq!(titles(None), ["Save as New Look\u{2026}"]);
        assert_eq!(
            titles(Some("Neon")),
            ["Update \u{201C}Neon\u{201D}", "Save as New Look\u{2026}", "Rename\u{2026}", "Delete"]
        );
    }

    #[test]
    fn template_token_round_trips() {
        let id = Id::fixed(7);
        assert_eq!(TextAnimatorChoices::template_id(&format!("template:{id}")), Some(id));
        assert_eq!(TextAnimatorChoices::template_id("look:1"), None);
    }
}
