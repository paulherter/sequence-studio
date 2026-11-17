# sq-core-file

Port of `ProjectFile.swift`, `ProjectFile+V19 ... V94` and `ProjectFile+Salvage.swift`: the `.sqproj` reader and writer over
`sq_core_model::Project`.

- `ProjectFile::encode / decode / read / write / autosave / read_salvaging`: the file envelope `{appFormat, formatVersion, project}`,
  the lowest-version-that-holds-the-content rule (`written_version`), the migration chain (`migrations`), safe writes with
  `.bak` copies of older files.
- `ProjectFixups`: logic that lives in higher `sq-core-*` crates (group pruning, variant pruning, the v10 Scale step, the v24
  shadow color step). `NoFixups` is the no-op default; `sq-core-project` supplies the real one.
- Output equals Swift's as parsed content (keys sorted, same key sets and numbers); bytes differ (no `\/`, spacing).

Open points and limits: `NOTES.md`.
