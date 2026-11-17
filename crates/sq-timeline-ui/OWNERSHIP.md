# sq-timeline-ui ownership

| field | owner | lifetime | shared-by |
|---|---|---|---|
| `KeystoneEaseSource.model: Rc<RefCell<KeystonesPanelModel>>` | the Keystones panel host (UI thread) | while the curve popover is open | the popover's source and the panel: both on the UI thread, borrows are short and never held across a call into the other (Swift: one `@MainActor` class instance) |
