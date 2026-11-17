//! The queue a menu row pushes into (Swift: the row's closure called the panel through `[weak self]`).
//!
//! A row is built from `&self` and cannot change its panel, so it records what was picked; the panel applies the picks on
//! its own turn (`pump`), right after the menu closed. UI thread only.

use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

/// Picks of the menu rows, in the order they were made.
pub(crate) struct MenuQueue<T>(Rc<RefCell<Vec<T>>>);

impl<T> Clone for MenuQueue<T> {
    fn clone(&self) -> Self {
        MenuQueue(Rc::clone(&self.0))
    }
}

impl<T> Default for MenuQueue<T> {
    fn default() -> Self {
        MenuQueue(Rc::new(RefCell::new(Vec::new())))
    }
}

impl<T: Clone + 'static> MenuQueue<T> {
    /// A row that records `cmd` when it is picked.
    pub(crate) fn row(&self, title: &str, cmd: T) -> SQMenuItem {
        let mut item = SQMenuItem::new(title);
        self.set_action(&mut item, cmd);
        item
    }

    /// Records `cmd`.
    pub(crate) fn push(&self, cmd: T) {
        self.0.borrow_mut().push(cmd);
    }

    /// Makes `item` record `cmd` when it is picked.
    pub(crate) fn set_action(&self, item: &mut SQMenuItem, cmd: T) {
        let q = self.clone();
        item.action = Some(Rc::new(move || q.push(cmd.clone())));
    }

    /// Takes the picks made so far.
    pub(crate) fn drain(&self) -> Vec<T> {
        std::mem::take(&mut *self.0.borrow_mut())
    }
}
