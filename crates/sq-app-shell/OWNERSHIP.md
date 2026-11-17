# sq-app-shell: ownership

`App` lives in `UiRoot<App>` (`Rc<RefCell<App>>`) on the UI thread; async flows hold `UiRef<App>` (weak) and borrow
only inside `with` closures. No host stores the session, the services or another host.

| field | owner | lifetime | shared-by |
|---|---|---|---|
| `App.session: EditorSession` | `App` | app | lent to hosts as `&` (`sync`) and `&mut` (`HostCx`) per call |
| `App.services: AppServices` (boxed platform traits) | `App` | app | lent to hosts through `HostCx::services` per call |
| `App.hosts: Vec<Slot>` | `App` | app | none |
| `App.ui: UiCx` | `App` | app | lent to hosts through `HostCx::ui` per call |
| `App.inbox: Inbox<AppMessage>` | `App` | app | `Sender` clones in service threads (channel, `Mutex` inside) |
| `App.clock: Arc<dyn Clock>` | `App` | app | the `UiExecutor` reads the same clock |
| `Headless.root: UiRoot<App>` | `Headless` | harness | `UiRef<App>` weak handles in tasks |
