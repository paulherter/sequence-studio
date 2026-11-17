# sq-os

`Platform` (Mac, Windows, Linux) is the one answer to "which system am I on". `Platform::current()` is the only place that
reads `cfg(target_os)` for this; every property (command key name, folders, file manager, update asset, feedback name)
is a pure method on the value, so a test can ask all three systems on any host. Folder methods take the environment as a
closure and never touch the real one.

Layer 0: no dependencies except `workspace-hack`.
