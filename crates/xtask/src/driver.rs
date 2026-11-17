// SPDX-License-Identifier: GPL-3.0-or-later
//! Task driver v0: a TSV queue, dependency order, budget and stop checks. It spends no LLM tokens itself.
//! Queue: `build/driver/queue.tsv` (id, crate, wave, model, state, owner, branch, attempts, cost_usd, notes).
//! States: ready, running, done, failed. Crate order: `docs/rust/crate-order.tsv`.

use crate::json::Json;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const MAX_ATTEMPTS: u32 = 3;
const HEADER: &str = "id\tcrate\twave\tmodel\tstate\towner\tbranch\tattempts\tcost_usd\tnotes";

#[derive(Debug, Clone, PartialEq)]
pub struct Task {
    pub id: String,
    pub krate: String,
    pub wave: u32,
    pub model: String,
    pub state: String,
    pub owner: String,
    pub branch: String,
    pub attempts: u32,
    pub cost: f64,
    pub notes: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CrateInfo {
    pub name: String,
    pub layer: u32,
    pub depends: Vec<String>,
}

fn clean(s: &str) -> String {
    s.replace(['\t', '\n', '\r'], " ")
}

impl Task {
    fn parse(line: &str) -> Result<Task, String> {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() != 10 {
            return Err(format!("queue line has {} fields, expected 10: {line}", f.len()));
        }
        let num = |s: &str| s.parse::<u32>().map_err(|e| format!("bad number `{s}`: {e}"));
        Ok(Task {
            id: f[0].into(),
            krate: f[1].into(),
            wave: num(f[2])?,
            model: f[3].into(),
            state: f[4].into(),
            owner: f[5].into(),
            branch: f[6].into(),
            attempts: num(f[7])?,
            cost: f[8].parse::<f64>().map_err(|e| format!("bad cost `{}`: {e}", f[8]))?,
            notes: f[9].into(),
        })
    }

    fn line(&self) -> String {
        let a = self.attempts.to_string();
        let w = self.wave.to_string();
        let c = format!("{:.4}", self.cost);
        [&self.id, &self.krate, &w, &self.model, &self.state, &self.owner, &self.branch, &a, &c, &self.notes]
            .iter()
            .map(|s| clean(s))
            .collect::<Vec<_>>()
            .join("\t")
    }
}

pub fn parse_queue(text: &str) -> Result<Vec<Task>, String> {
    text.lines().skip(1).filter(|l| !l.trim().is_empty()).map(Task::parse).collect()
}

pub fn format_queue(tasks: &[Task]) -> String {
    let mut out = String::from(HEADER);
    for t in tasks {
        out.push('\n');
        out.push_str(&t.line());
    }
    out.push('\n');
    out
}

pub fn parse_order(text: &str) -> Result<Vec<CrateInfo>, String> {
    text.lines()
        .skip(1)
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 3 {
                return Err(format!("crate-order line too short: {l}"));
            }
            let depends = f[2].split(',').filter(|d| !d.is_empty() && *d != "-").map(str::to_string).collect();
            Ok(CrateInfo {
                name: f[0].into(),
                layer: f[1].parse().map_err(|e| format!("bad layer in {l}: {e}"))?,
                depends,
            })
        })
        .collect()
}

/// The next task to run: state `ready`, every crate it depends on has only `done` tasks. Lowest wave, then layer, then queue order.
pub fn next_ready<'a>(tasks: &'a [Task], order: &[CrateInfo]) -> Option<&'a Task> {
    let info = |c: &str| order.iter().find(|i| i.name == c);
    let blocked = |t: &Task| {
        info(&t.krate)
            .is_some_and(|i| i.depends.iter().any(|d| tasks.iter().any(|o| &o.krate == d && o.state != "done")))
    };
    tasks
        .iter()
        .enumerate()
        .filter(|(_, t)| t.state == "ready" && !blocked(t))
        .min_by_key(|(n, t)| (t.wave, info(&t.krate).map_or(u32::MAX, |i| i.layer), *n))
        .map(|(_, t)| t)
}

// ---- stop checks: pure functions, each returns the reason to stop ----

pub fn check_attempts(attempts: u32) -> Option<String> {
    (attempts >= MAX_ATTEMPTS).then(|| format!("task failed {attempts} times, escalate to a human or Opus"))
}

pub fn check_disk(free_gb: f64, limit_gb: f64) -> Option<String> {
    (free_gb < limit_gb).then(|| format!("free disk {free_gb:.1} GB is below the limit of {limit_gb:.0} GB"))
}

pub fn check_budget(spent_usd: f64, budget_usd: Option<f64>) -> Option<String> {
    budget_usd.filter(|b| spent_usd > *b).map(|b| format!("logged cost ${spent_usd:.2} is above SQ_BUDGET_USD ${b:.2}"))
}

pub fn check_git(porcelain: &str) -> Option<String> {
    let n = porcelain.lines().filter(|l| !l.trim().is_empty()).count();
    (n > 0).then(|| format!("worker worktree is dirty ({n} changed paths)"))
}

pub fn disk_limit_gb() -> f64 {
    if cfg!(windows) { 20.0 } else { 3.0 }
}

/// Free space in GB on the volume holding `path` (`df` on macOS/Linux, PowerShell on Windows).
pub fn free_disk_gb(path: &Path) -> Result<f64, String> {
    if cfg!(windows) {
        let ps = "(Get-PSDrive -Name (Get-Location).Drive.Name).Free";
        let o = Command::new("powershell")
            .args(["-NoProfile", "-Command", ps])
            .current_dir(path)
            .output()
            .map_err(|e| e.to_string())?;
        let bytes: f64 =
            String::from_utf8_lossy(&o.stdout).trim().parse().map_err(|e| format!("PowerShell free space: {e}"))?;
        Ok(bytes / 1e9)
    } else {
        let o = Command::new("df").args(["-k"]).arg(path).output().map_err(|e| e.to_string())?;
        parse_df(&String::from_utf8_lossy(&o.stdout))
    }
}

pub fn parse_df(out: &str) -> Result<f64, String> {
    let line = out.lines().nth(1).ok_or("df printed no data line")?;
    let kb: f64 = line.split_whitespace().nth(3).ok_or("df line too short")?.parse().map_err(|e| format!("df: {e}"))?;
    Ok(kb / 1e6)
}

/// `total_cost_usd` of a `claude -p --output-format json` result.
pub fn cost_from_output(text: &str) -> Option<f64> {
    let j = Json::parse(text.trim()).ok()?;
    match &j {
        Json::Arr(items) => items.iter().rev().find_map(|i| i.get("total_cost_usd").and_then(Json::as_f64)),
        _ => j.get("total_cost_usd").and_then(Json::as_f64),
    }
}

pub fn worktree_for(repo: &Path, krate: &str) -> PathBuf {
    let root = std::env::var("SQ_WORKTREE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo.parent().unwrap_or(repo).to_path_buf());
    root.join(format!("sq-wt-{krate}"))
}

/// The worker command, as argv. The prompt stays short: the worker reads docs/rust/PORTING.md itself.
pub fn claude_command(t: &Task, max_turns: u32) -> Vec<String> {
    let prompt = format!(
        "Task {id}: port crate {c} (wave {w}). Read docs/rust/PORTING.md and docs/rust/AGENT-RULES.md first, then the task card for {c}. \
         Work only in crates/{c}. Commit your own paths, then stop.",
        id = t.id,
        c = t.krate,
        w = t.wave
    );
    ["claude", "-p", "--output-format", "json", "--model", &t.model, "--max-turns", &max_turns.to_string(), &prompt]
        .map(String::from)
        .to_vec()
}

fn shell_quote(a: &str) -> String {
    if a.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:".contains(c)) {
        a.to_string()
    } else {
        format!("'{}'", a.replace('\'', r"'\''"))
    }
}

// ---- command line ----

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2).map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}

fn queue_path(repo: &Path) -> PathBuf {
    repo.join("build/driver/queue.tsv")
}

fn load(repo: &Path) -> Result<Vec<Task>, String> {
    match std::fs::read_to_string(queue_path(repo)) {
        Ok(t) => parse_queue(&t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.to_string()),
    }
}

fn save(repo: &Path, tasks: &[Task]) -> Result<(), String> {
    let p = queue_path(repo);
    std::fs::create_dir_all(p.parent().unwrap_or(repo)).map_err(|e| e.to_string())?;
    std::fs::write(&p, format_queue(tasks)).map_err(|e| e.to_string())
}

fn order(repo: &Path) -> Result<Vec<CrateInfo>, String> {
    parse_order(
        &std::fs::read_to_string(repo.join("docs/rust/crate-order.tsv"))
            .map_err(|e| format!("crate-order.tsv: {e}"))?,
    )
}

fn budget() -> Option<f64> {
    std::env::var("SQ_BUDGET_USD").ok().and_then(|v| v.parse().ok())
}

pub fn run(args: &[String]) -> Result<(), String> {
    let repo = repo_root();
    let mut tasks = load(&repo)?;
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let find = |tasks: &mut Vec<Task>, id: &str| tasks.iter().position(|t| t.id == id).ok_or(format!("no task `{id}`"));
    match a.as_slice() {
        ["add", id, krate, wave, model, notes @ ..] => {
            if tasks.iter().any(|t| t.id == *id) {
                return Err(format!("task `{id}` exists"));
            }
            if !order(&repo)?.iter().any(|c| c.name == *krate) {
                return Err(format!("crate `{krate}` is not in docs/rust/crate-order.tsv"));
            }
            let wave = wave.parse().map_err(|e| format!("wave: {e}"))?;
            tasks.push(Task { id: (*id).into(), krate: (*krate).into(), wave, model: (*model).into(), state: "ready".into(), owner: "-".into(), branch: format!("rs/{krate}"), attempts: 0, cost: 0.0, notes: notes.join(" ") });
        }
        ["list"] => {
            print!("{}", format_queue(&tasks));
            return Ok(());
        }
        ["next"] => {
            match next_ready(&tasks, &order(&repo)?) {
                Some(t) => println!("{}\t{}\t{}\t{}", t.id, t.krate, t.model, t.branch),
                None => println!("nothing ready"),
            }
            return Ok(());
        }
        ["start", id, owner] => {
            let n = find(&mut tasks, id)?;
            tasks[n].state = "running".into();
            tasks[n].owner = (*owner).into();
        }
        ["done", id, rest @ ..] => {
            let n = find(&mut tasks, id)?;
            tasks[n].state = "done".into();
            tasks[n].notes = rest.join(" ");
        }
        ["fail", id, rest @ ..] => {
            let n = find(&mut tasks, id)?;
            tasks[n].attempts += 1;
            tasks[n].state = if tasks[n].attempts >= MAX_ATTEMPTS { "failed" } else { "ready" }.into();
            tasks[n].notes = rest.join(" ");
        }
        ["log-cost", id, file] => {
            let n = find(&mut tasks, id)?;
            let text = if *file == "-" { std::io::read_to_string(std::io::stdin()).map_err(|e| e.to_string())? } else { std::fs::read_to_string(file).map_err(|e| e.to_string())? };
            tasks[n].cost += cost_from_output(&text).ok_or("no total_cost_usd in the output")?;
        }
        ["status"] => return status(&repo, &tasks),
        ["run-one", flags @ ..] => return run_one(&repo, &tasks, flags),
        _ => return Err("usage: driver add <id> <crate> <wave> <model> [notes] | list | next | start <id> <owner> | done <id> [note] | fail <id> [note] | log-cost <id> <json-file|-> | status | run-one --dry-run|--really".into()),
    }
    save(&repo, &tasks)
}

fn status(repo: &Path, tasks: &[Task]) -> Result<(), String> {
    let count = |s: &str| tasks.iter().filter(|t| t.state == s).count();
    let spent: f64 = tasks.iter().map(|t| t.cost).sum();
    println!(
        "tasks: {} ready, {} running, {} done, {} failed",
        count("ready"),
        count("running"),
        count("done"),
        count("failed")
    );
    match budget() {
        Some(b) => println!("cost: ${spent:.2} of ${b:.2} (SQ_BUDGET_USD)"),
        None => println!("cost: ${spent:.2} (SQ_BUDGET_USD not set)"),
    }
    match free_disk_gb(repo) {
        Ok(g) => println!("disk: {g:.1} GB free, limit {:.0} GB", disk_limit_gb()),
        Err(e) => println!("disk: unknown ({e})"),
    }
    Ok(())
}

fn run_one(repo: &Path, tasks: &[Task], flags: &[&str]) -> Result<(), String> {
    let really = flags.contains(&"--really");
    if !really && !flags.contains(&"--dry-run") {
        return Err("run-one needs --dry-run or --really".into());
    }
    let Some(t) = next_ready(tasks, &order(repo)?) else {
        println!("nothing ready (queue empty or blocked by crate order)");
        return Ok(());
    };
    let wt = worktree_for(repo, &t.krate);
    let spent: f64 = tasks.iter().map(|t| t.cost).sum();
    let mut stops: Vec<String> = Vec::new();
    stops.extend(check_attempts(t.attempts));
    stops.extend(free_disk_gb(repo).ok().and_then(|g| check_disk(g, disk_limit_gb())));
    stops.extend(check_budget(spent, budget()));
    if really && budget().is_none() {
        stops.push("SQ_BUDGET_USD is not set".into());
    }
    if wt.exists() {
        let o =
            Command::new("git").args(["status", "--porcelain"]).current_dir(&wt).output().map_err(|e| e.to_string())?;
        stops.extend(check_git(&String::from_utf8_lossy(&o.stdout)));
    }
    let turns = std::env::var("SQ_MAX_TURNS").ok().and_then(|v| v.parse().ok()).unwrap_or(60);
    println!("task:   {} ({}, wave {}, attempt {})", t.id, t.krate, t.wave, t.attempts + 1);
    println!("cwd:    {}", wt.display());
    println!(
        "env:    SQ_WORKER_CRATE={} SQ_WORKER_OWN=crates/{};docs/rust/cards CARGO_TARGET_DIR={}",
        t.krate,
        t.krate,
        wt.join("target").display()
    );
    println!("cmd:    {}", claude_command(t, turns).iter().map(|s| shell_quote(s)).collect::<Vec<_>>().join(" "));
    for s in &stops {
        println!("STOP:   {s}");
    }
    if !stops.is_empty() {
        return Err("stop conditions hit, nothing started".into());
    }
    if really {
        // TODO(--really): create the worktree on branch `rs/<crate>`, export the env above, run the command, read stdout with
        // `cost_from_output`, then `start`/`done`/`fail` the task. Left out of v0 on purpose: nothing here launches Claude.
        return Err("--really is not implemented in v0".into());
    }
    println!("dry run: nothing started");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: &str, krate: &str, state: &str) -> Task {
        Task {
            id: id.into(),
            krate: krate.into(),
            wave: 1,
            model: "sonnet".into(),
            state: state.into(),
            owner: "-".into(),
            branch: format!("rs/{krate}"),
            attempts: 0,
            cost: 0.0,
            notes: String::new(),
        }
    }

    fn order() -> Vec<CrateInfo> {
        let ci = |n: &str, l, d: &[&str]| CrateInfo {
            name: n.into(),
            layer: l,
            depends: d.iter().map(|s| s.to_string()).collect(),
        };
        vec![ci("sq-time", 1, &[]), ci("sq-model", 1, &["sq-time"]), ci("sq-edit", 1, &["sq-model"])]
    }

    #[test]
    fn queue_round_trips_and_sanitizes() {
        let mut t = task("a", "sq-time", "ready");
        t.notes = "tab\there\nnew".into();
        t.cost = 1.5;
        let back = parse_queue(&format_queue(&[t])).unwrap();
        assert_eq!(back[0].notes, "tab here new");
        assert!((back[0].cost - 1.5).abs() < 1e-9);
        assert!(parse_queue("h\nonly\tthree\tfields").is_err());
    }

    #[test]
    fn next_respects_crate_dependencies() {
        let tasks = vec![task("m", "sq-model", "ready"), task("t", "sq-time", "ready")];
        assert_eq!(next_ready(&tasks, &order()).map(|t| t.id.as_str()), Some("t"));
        let tasks = vec![task("m", "sq-model", "ready"), task("t", "sq-time", "running")];
        assert!(next_ready(&tasks, &order()).is_none());
        let tasks = vec![task("m", "sq-model", "ready"), task("t", "sq-time", "done")];
        assert_eq!(next_ready(&tasks, &order()).map(|t| t.id.as_str()), Some("m"));
    }

    #[test]
    fn real_crate_order_file_is_consistent() {
        let o = parse_order(include_str!("../../../docs/rust/crate-order.tsv")).unwrap();
        for c in &o {
            for d in &c.depends {
                assert!(o.iter().any(|x| &x.name == d), "{} depends on unknown {d}", c.name);
            }
        }
    }

    #[test]
    fn stop_checks() {
        assert!(check_attempts(2).is_none());
        assert!(check_attempts(3).is_some());
        assert!(check_disk(2.9, 3.0).is_some());
        assert!(check_disk(3.0, 3.0).is_none());
        assert!(check_disk(19.0, 20.0).is_some());
        assert!(check_budget(10.0, Some(9.99)).is_some());
        assert!(check_budget(10.0, Some(10.0)).is_none());
        assert!(check_budget(1e9, None).is_none());
        assert!(check_git("").is_none());
        assert!(check_git(" M a.rs\n?? b\n").is_some());
    }

    #[test]
    fn df_and_cost_parsing() {
        let df = "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 500000000 1 8000000 50% /\n";
        assert!((parse_df(df).unwrap() - 8.0).abs() < 1e-9);
        assert_eq!(cost_from_output(r#"{"type":"result","total_cost_usd":0.4321,"result":"ok"}"#), Some(0.4321));
        assert_eq!(cost_from_output(r#"[{"type":"system"},{"type":"result","total_cost_usd":2}]"#), Some(2.0));
        assert_eq!(cost_from_output("not json"), None);
    }

    #[test]
    fn worker_command_shape() {
        let c = claude_command(&task("a", "sq-time", "ready"), 40);
        assert_eq!(&c[..8], ["claude", "-p", "--output-format", "json", "--model", "sonnet", "--max-turns", "40"]);
        assert!(c[8].contains("crates/sq-time"));
    }
}
