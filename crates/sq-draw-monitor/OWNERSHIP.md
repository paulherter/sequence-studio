# sq-draw-monitor ownership

| field | owner | lifetime | shared-by |
|---|---|---|---|
| `MenuQueue<T>` (`Rc<RefCell<Vec<T>>>`) | `MonitorPanelModel` (`MenuCommand`), `SourceMonitorCore` (`SourceMenuCommand`), `MeterPanel`, `ScopesPanel` | as long as the owner | the `Rc<dyn Fn()>` actions of the `SQMenuItem` rows that owner built; UI thread only |
| `MonitorPanelModel.defaults` (`Box<dyn UiDefaults>`) | the model | as the model | none (the host hands each model a handle to the same backing store) |
| `SourceMonitorCore.engine` (`Box<dyn ProgramEngine>`) | the core | as the core | none; the app polls `tick` once per frame |
| `GraphicsLayerOverlay.source`, `MonitorPanel.captions` (`Box<dyn ...>`) | the overlay / panel | as the panel | none; every call receives the session |

The queue replaces Swift's `[weak self]` captured in menu closures: a row is built from `&self` and cannot mutate its owner,
so it records what was picked; the owner applies the picks on its own turn (`sync`, `pump`, `handle`).
