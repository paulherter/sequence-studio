// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile.swift (paths, write, read, backups, atomic write, autosave)

use crate::{CURRENT_VERSION, FILE_EXTENSION, LEGACY_FILE_EXTENSIONS, Migrations, ProjectFile, ProjectFileError};
use sq_core_model::Project;
use sq_core_time::Timestamp;
use sq_os::Platform;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The JSON file inside a package folder.
pub const FILE_NAME: &str = "project.json";
/// Snapshot folder name.
pub const AUTOSAVE_DIR: &str = "Autosave";

/// Files without `appFormat` below this were provably written by an older build (the lowest version any build writes is
/// 36); from 36 on they are unknown and never backed up.
const UNKNOWN_AUTHOR_FLOOR: i64 = 36;

/// New projects are one plain file where a package would show up as a folder (Windows). A path that already exists keeps
/// its form: a folder stays a package, a file stays a file. Both open on every platform.
pub const NEW_PROJECTS_ARE_FILES: bool = Platform::native().new_projects_are_files();

fn extension_lowercased(path: &Path) -> String {
    path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// The path has the project extension (or a legacy one).
pub fn is_project_path(path: &Path) -> bool {
    let e = extension_lowercased(path);
    e == FILE_EXTENSION || LEGACY_FILE_EXTENSIONS.contains(&e.as_str())
}

/// The path has a legacy project extension.
pub fn is_legacy_path(path: &Path) -> bool {
    LEGACY_FILE_EXTENSIONS.contains(&extension_lowercased(path).as_str())
}

/// The sibling `<name>.sqproj` a legacy project is saved to; `<name> 2.sqproj` etc. when that already exists.
pub fn converted_path(path: &Path) -> PathBuf {
    let dir = path.parent().unwrap_or(Path::new(""));
    let name = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let mut candidate = dir.join(format!("{name}.{FILE_EXTENSION}"));
    let mut n = 2;
    while candidate.exists() {
        candidate = dir.join(format!("{name} {n}.{FILE_EXTENSION}"));
        n += 1;
    }
    candidate
}

/// True when `path` is a project saved as one file (not a package folder).
pub fn is_single_file(path: &Path) -> bool {
    path.is_file()
}

/// The JSON file of the project at `path`: the file itself, or `project.json` inside the package folder.
pub fn document_file(path: &Path) -> PathBuf {
    if is_single_file(path) { path.to_path_buf() } else { path.join(FILE_NAME) }
}

/// `(appFormat, formatVersion)` from the first bytes of a project file (keys are sorted, so both come first).
fn header(file: &Path) -> Option<(Option<i64>, i64)> {
    let mut head = Vec::new();
    fs::File::open(file).ok()?.take(256).read_to_end(&mut head).ok()?;
    let text = String::from_utf8_lossy(&head);
    let int = |key: &str| -> Option<i64> {
        let pat = format!("\"{key}\"");
        let at = text.find(&pat)? + pat.len();
        let rest = text[at..].trim_start_matches([' ', ':']);
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    int("formatVersion").map(|v| (int("appFormat"), v))
}

/// Before a save by a newer build overwrites a file an older build wrote, copies it to `<package>.v<oldVersion>.bak`
/// beside the package (once, never overwritten) and keeps the 3 highest-version backups. Saves of a file this build wrote
/// make none. A failed backup stops the save.
fn backup_if_older(old: &Path, package: &Path) -> Result<(), ProjectFileError> {
    let Some((app, v0)) = header(old) else { return Ok(()) };
    let newer = app.unwrap_or(0) > CURRENT_VERSION || v0 > CURRENT_VERSION; // a newer build's file: never overwrite unbacked
    let older = app.map_or(v0 < UNKNOWN_AUTHOR_FLOOR, |a| a < CURRENT_VERSION);
    if !(newer || older) {
        return Ok(());
    }
    let v = if newer { app.unwrap_or(0).max(v0) } else { v0 };
    let dir = package.parent().unwrap_or(Path::new("")).to_path_buf();
    let package_name = package.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let prefix = format!("{package_name}.v");
    let bak_name = format!("{prefix}{v}.bak");
    let bak = dir.join(&bak_name);
    if !bak.exists() {
        fs::copy(old, &bak)?;
    }
    let skip = package_name.chars().count() + 2;
    let mut baks: Vec<(PathBuf, i64)> = fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.starts_with(&prefix) || name == bak_name {
                return None;
            }
            let stem = name.strip_suffix(".bak")?;
            let n: i64 = stem.chars().skip(skip).collect::<String>().parse().ok()?;
            Some((entry.path(), n))
        })
        .collect();
    baks.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    for (path, _) in baks.into_iter().skip(2) {
        let _ = fs::remove_file(path);
    }
    Ok(())
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Writes to a temp file next to `file`, then replaces it. The old file survives a failed write. `before_rename` runs after
/// the contents are on disk and before the replace (tests make it fail).
pub(crate) fn atomic_write(
    data: &[u8],
    file: &Path,
    before_rename: Option<&dyn Fn() -> std::io::Result<()>>,
) -> Result<(), ProjectFileError> {
    use std::io::Write;
    let dir = file
        .parent()
        .map(Path::to_path_buf)
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or_else(|| PathBuf::from("."));
    let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = dir.join(format!(".{:08X}-{n:08X}.tmp", std::process::id()));
    let mut out = fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    out.write_all(data)?;
    out.sync_all()?; // contents on disk before the rename can make them visible
    drop(out);
    let replaced = before_rename.map_or(Ok(()), |f| f()).and_then(|()| fs::rename(&tmp, file));
    if let Err(e) = replaced {
        let _ = fs::remove_file(&tmp);
        return Err(e.into());
    }
    flush_dir(&dir); // the rename itself survives a power loss
    Ok(())
}

/// fsync of a directory; best effort (directories cannot be opened for syncing on Windows).
fn flush_dir(dir: &Path) {
    if cfg!(unix)
        && let Ok(d) = fs::File::open(dir)
    {
        let _ = d.sync_all();
    }
}

// Autosave names are UTC `yyyyMMdd-HHmmss-SSS`.

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Milliseconds since 1970 (truncated like the date formatter does).
fn unix_millis(date: Timestamp) -> i64 {
    (date.unix_seconds() * 1000.0).floor() as i64
}

pub(crate) fn timestamp_name(unix_millis: i64) -> String {
    let (days, ms_of_day) = (unix_millis.div_euclid(86_400_000), unix_millis.rem_euclid(86_400_000));
    let (y, mo, d) = civil_from_days(days);
    let (h, mi, s, ms) = (ms_of_day / 3_600_000, ms_of_day / 60_000 % 60, ms_of_day / 1000 % 60, ms_of_day % 1000);
    format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}-{ms:03}")
}

pub(crate) fn parse_timestamp(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 19
        || b[8] != b'-'
        || b[15] != b'-'
        || !s.bytes().enumerate().all(|(i, c)| i == 8 || i == 15 || c.is_ascii_digit())
    {
        return None;
    }
    let n = |a: usize, z: usize| s[a..z].parse::<i64>().ok();
    let (y, mo, d, h, mi, sec, ms) = (n(0, 4)?, n(4, 6)?, n(6, 8)?, n(9, 11)?, n(11, 13)?, n(13, 15)?, n(16, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    Some(days_from_civil(y, mo, d) * 86_400_000 + h * 3_600_000 + mi * 60_000 + sec * 1000 + ms)
}

impl ProjectFile<'_> {
    /// Writes `project` to `path`: a file stays a file, a folder stays a package, a new path is a package (a file on
    /// Windows). Older files are copied to a `.bak` first (`backup_if_older`).
    pub fn write(&self, project: &Project, path: &Path) -> Result<(), ProjectFileError> {
        let data = self.encode(project)?;
        let single = if path.exists() { path.is_file() } else { NEW_PROJECTS_ARE_FILES };
        if single {
            if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                fs::create_dir_all(parent)?;
            }
            backup_if_older(path, path)?;
            return atomic_write(&data, path, None);
        }
        fs::create_dir_all(path)?;
        let file = path.join(FILE_NAME);
        backup_if_older(&file, path)?;
        atomic_write(&data, &file, None)
    }

    /// Reads the project at `path` (a package folder or a single file).
    pub fn read(&self, path: &Path) -> Result<Project, ProjectFileError> {
        self.read_with(path, None)
    }

    /// `read` with a custom migration table.
    pub fn read_with(&self, path: &Path, migrations: Option<&Migrations<'_>>) -> Result<Project, ProjectFileError> {
        self.read_file(&document_file(path), migrations)
    }

    pub(crate) fn read_file(
        &self,
        file: &Path,
        migrations: Option<&Migrations<'_>>,
    ) -> Result<Project, ProjectFileError> {
        if !file.exists() {
            return Err(ProjectFileError::Missing);
        }
        let data = fs::read(file).map_err(|_| ProjectFileError::Corrupt)?;
        self.decode(&data, migrations)
    }

    /// Snapshot folder of a project: `Autosave/` inside a package, `<name>.sqproj.Autosave/` beside a single file.
    pub fn autosave_folder(path: &Path) -> PathBuf {
        if is_single_file(path) {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            path.parent().unwrap_or(Path::new("")).join(format!("{name}.{AUTOSAVE_DIR}"))
        } else {
            path.join(AUTOSAVE_DIR)
        }
    }

    /// Writes `Autosave/<yyyyMMdd-HHmmss-SSS>.json` (UTC) and keeps only the newest `keep` snapshots.
    pub fn autosave(
        &self,
        project: &Project,
        path: &Path,
        keep: usize,
        date: Timestamp,
    ) -> Result<PathBuf, ProjectFileError> {
        let dir = Self::autosave_folder(path);
        fs::create_dir_all(&dir)?;
        // A clock set back must not sort the new snapshot below the older ones (it would be pruned and never "latest"):
        // the name is at least 1 ms after the newest existing snapshot.
        let mut stamp = unix_millis(date);
        if let Some(t) = Self::autosaves(path)
            .last()
            .and_then(|last| last.file_stem().and_then(|s| s.to_str()).and_then(parse_timestamp))
            .filter(|t| *t >= stamp)
        {
            stamp = t + 1;
        }
        let file = dir.join(format!("{}.json", timestamp_name(stamp)));
        atomic_write(&self.encode(project)?, &file, None)?;
        let all = Self::autosaves(path);
        let excess = all.len().saturating_sub(keep.max(1));
        for old in all.into_iter().take(excess).filter(|old| *old != file) {
            let _ = fs::remove_file(old);
        }
        Ok(file)
    }

    /// Snapshots, oldest first (names sort chronologically).
    pub fn autosaves(path: &Path) -> Vec<PathBuf> {
        let mut items: Vec<PathBuf> = fs::read_dir(Self::autosave_folder(path))
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                p.extension().is_some_and(|e| e == "json") && !name.starts_with('.')
            })
            .collect();
        items.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
        items
    }

    /// The newest snapshot that reads.
    pub fn latest_autosave(&self, path: &Path, migrations: Option<&Migrations<'_>>) -> Option<Project> {
        Self::autosaves(path).iter().rev().find_map(|f| self.read_file(f, migrations).ok())
    }
}
