use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use clap::{ArgAction, Parser, Subcommand};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::json;
use serde_yaml::{Mapping, Value};

#[derive(Parser, Debug)]
#[command(name = "mt")]
#[command(about = "MuonTickets CLI port (Rust scaffold)")]
#[command(disable_version_flag = true)]
struct Cli {
    #[arg(short = 'v', long = "version", action = ArgAction::SetTrue, global = true)]
    version: bool,
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Init,
    New {
        title: String,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long = "type")]
        ticket_type: Option<String>,
        #[arg(long)]
        effort: Option<String>,
        #[arg(long)]
        label: Vec<String>,
        #[arg(long)]
        tag: Vec<String>,
        #[arg(long = "depends-on")]
        depends_on: Vec<String>,
        #[arg(long, default_value = "")]
        goal: String,
    },
    Ls {
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        label: Vec<String>,
        #[arg(long)]
        owner: Option<String>,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long = "type")]
        ticket_type: Option<String>,
        #[arg(long = "show-invalid")]
        show_invalid: bool,
    },
    Show {
        id: String,
    },
    Pick {
        #[arg(long)]
        owner: String,
        #[arg(long)]
        label: Vec<String>,
        #[arg(long = "avoid-label")]
        avoid_label: Vec<String>,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long = "type")]
        ticket_type: Option<String>,
        #[arg(long, default_value = "")]
        branch: String,
        #[arg(long = "ignore-deps")]
        ignore_deps: bool,
        #[arg(long = "max-claimed-per-owner", default_value_t = 2)]
        max_claimed_per_owner: i32,
        #[arg(long)]
        skill: Option<String>,
        #[arg(long)]
        role: Option<String>,
        #[arg(long)]
        json: bool,
    },
    AllocateTask {
        #[arg(long)]
        owner: String,
        #[arg(long)]
        label: Vec<String>,
        #[arg(long = "avoid-label")]
        avoid_label: Vec<String>,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long = "type")]
        ticket_type: Option<String>,
        #[arg(long, default_value = "")]
        branch: String,
        #[arg(long = "ignore-deps")]
        ignore_deps: bool,
        #[arg(long = "max-claimed-per-owner", default_value_t = 2)]
        max_claimed_per_owner: i32,
        #[arg(long, default_value_t = 5)]
        lease_minutes: i64,
        #[arg(long)]
        skill: Option<String>,
        #[arg(long)]
        role: Option<String>,
        #[arg(long)]
        json: bool,
    },
    FailTask {
        id: String,
        #[arg(long)]
        owner: String,
        #[arg(long)]
        error: String,
        #[arg(long = "retry-limit")]
        retry_limit: Option<i64>,
        #[arg(long)]
        force: bool,
    },
    Claim {
        id: String,
        #[arg(long)]
        owner: String,
        #[arg(long, default_value = "")]
        branch: String,
        #[arg(long = "ignore-deps")]
        ignore_deps: bool,
        #[arg(long)]
        force: bool,
    },
    Comment {
        id: String,
        text: String,
    },
    SetStatus {
        id: String,
        status: String,
        #[arg(long)]
        force: bool,
        #[arg(long = "clear-owner")]
        clear_owner: bool,
    },
    Done {
        id: String,
        #[arg(long)]
        force: bool,
    },
    Archive {
        id: String,
        #[arg(long)]
        force: bool,
    },
    Graph {
        #[arg(long)]
        mermaid: bool,
        #[arg(long = "open-only")]
        open_only: bool,
    },
    Export {
        #[arg(long, default_value = "json")]
        format: String,
    },
    Stats,
    Validate {
        #[arg(long = "max-claimed-per-owner", default_value_t = 2)]
        max_claimed_per_owner: i32,
        #[arg(long = "enforce-done-deps")]
        enforce_done_deps: bool,
    },
    Report {
        #[arg(long, default_value = "tickets/tickets_report.sqlite3")]
        db: String,
        #[arg(long, default_value_t = true)]
        summary: bool,
        #[arg(long, default_value = "")]
        search: String,
        #[arg(long, default_value_t = 30)]
        limit: i32,
    },
    Version {
        #[arg(long)]
        json: bool,
    },
    Maintain {
        #[command(subcommand)]
        subcmd: MaintainCmd,
    },
}

#[derive(Subcommand, Debug)]
enum MaintainCmd {
    InitConfig {
        #[arg(long)]
        force: bool,
        #[arg(long)]
        detect: bool,
    },
    Doctor,
    List {
        #[arg(long, action = ArgAction::Append)]
        category: Vec<String>,
        #[arg(long, action = ArgAction::Append)]
        rule: Vec<i32>,
    },
    Scan {
        #[arg(long, action = ArgAction::Append)]
        category: Vec<String>,
        #[arg(long, action = ArgAction::Append)]
        rule: Vec<i32>,
        #[arg(long)]
        all: bool,
        #[arg(long, default_value = "text")]
        format: String,
        #[arg(long)]
        profile: Option<String>,
        #[arg(long)]
        diff: bool,
        #[arg(long)]
        fix: bool,
    },
    Create {
        #[arg(long, action = ArgAction::Append)]
        category: Vec<String>,
        #[arg(long, action = ArgAction::Append)]
        rule: Vec<i32>,
        #[arg(long)]
        all: bool,
        #[arg(long = "dry-run")]
        dry_run: bool,
        #[arg(long = "skip-scan")]
        skip_scan: bool,
        #[arg(long)]
        priority: Option<String>,
        #[arg(long)]
        owner: Option<String>,
    },
}

const DEFAULT_STATES: &[&str] = &["ready", "claimed", "blocked", "needs_review", "done"];
const DEFAULT_PRIORITIES: &[&str] = &["p0", "p1", "p2"];
const DEFAULT_TYPES: &[&str] = &["spec", "code", "tests", "docs", "refactor", "chore"];
const DEFAULT_EFFORTS: &[&str] = &["xs", "s", "m", "l", "xl", "xxl"];

fn root_version_components() -> Result<(u64, u64, String)> {
    let raw = option_env!("MT_ROOT_VERSION").ok_or_else(|| anyhow!("missing MT_ROOT_VERSION build metadata"))?;
    let trimmed = raw.trim();
    let mut parts = trimmed.split('.');
    let major_raw = parts
        .next()
        .ok_or_else(|| anyhow!("invalid root VERSION format in build metadata: {trimmed}"))?;
    let minor_raw = parts
        .next()
        .ok_or_else(|| anyhow!("invalid root VERSION format in build metadata: {trimmed}"))?;
    let patch_raw = parts.next();
    if parts.next().is_some() {
        return Err(anyhow!("invalid root VERSION format in build metadata: {trimmed}"));
    }
    let major = major_raw
        .parse::<u64>()
        .with_context(|| format!("invalid major version in root VERSION: {major_raw}"))?;
    let minor = minor_raw
        .parse::<u64>()
        .with_context(|| format!("invalid minor version in root VERSION: {minor_raw}"))?;
    if let Some(patch_raw) = patch_raw {
        let _ = patch_raw
            .parse::<u64>()
            .with_context(|| format!("invalid patch version in root VERSION: {patch_raw}"))?;
    }
    Ok((major, minor, trimmed.to_string()))
}

fn priority_weight(priority: &str) -> i32 {
    match priority {
        "p0" => 300,
        "p1" => 200,
        "p2" => 100,
        _ => 0,
    }
}

fn effort_weight(effort: &str) -> i32 {
    match effort {
        "xs" => 40,
        "s" => 30,
        "m" => 20,
        "l" => 10,
        "xl" => 5,
        "xxl" => 2,
        _ => 0,
    }
}

fn today_str() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn id_regex() -> Regex {
    Regex::new(r"^T-\d{6}$").expect("valid id regex")
}

fn ticket_file_regex() -> Regex {
    Regex::new(r"^(T-\d{6})\.md$").expect("valid ticket file regex")
}

fn find_repo_root(start: &Path) -> PathBuf {
    let mut cur = start.to_path_buf();
    loop {
        if cur.join("tickets").is_dir() {
            return cur;
        }
        if !cur.pop() {
            return start.to_path_buf();
        }
    }
}

fn tickets_dir(repo_root: &Path) -> PathBuf {
    repo_root.join("tickets")
}

fn archive_dir(repo_root: &Path) -> PathBuf {
    repo_root.join("tickets").join("archived")
}

fn errors_dir(repo_root: &Path) -> PathBuf {
    repo_root.join("tickets").join("errors")
}

fn incidents_log_path(repo_root: &Path) -> PathBuf {
    tickets_dir(repo_root).join("incidents.log")
}

fn backlogs_dir(repo_root: &Path) -> PathBuf {
    repo_root.join("tickets").join("backlogs")
}

fn ticket_template_path(repo_root: &Path) -> PathBuf {
    tickets_dir(repo_root).join("ticket.template")
}

fn last_ticket_id_path(repo_root: &Path) -> PathBuf {
    tickets_dir(repo_root).join("last_ticket_id")
}

fn split_frontmatter(content: &str) -> Result<(Mapping, String)> {
    let lines: Vec<&str> = content.lines().collect();
    if lines.is_empty() || lines[0].trim() != "---" {
        return Err(anyhow!("Missing YAML frontmatter. Expected first line to be '---'."));
    }
    let end_idx = lines
        .iter()
        .enumerate()
        .skip(1)
        .find_map(|(index, line)| if line.trim() == "---" { Some(index) } else { None })
        .ok_or_else(|| anyhow!("Unterminated YAML frontmatter. Missing closing '---'."))?;

    let frontmatter_text = lines[1..end_idx].join("\n");
    let mut body = String::new();
    if end_idx + 1 < lines.len() {
        body = lines[end_idx + 1..].join("\n");
        while body.starts_with('\n') {
            body.remove(0);
        }
    }
    let map = parse_simple_frontmatter(&frontmatter_text)?;
    Ok((map, body))
}

fn parse_simple_frontmatter(text: &str) -> Result<Mapping> {
    let mut map = Mapping::new();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value_raw)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value_raw = value_raw.trim();
        let value = parse_simple_value(value_raw);
        map.insert(Value::String(key.to_string()), value);
    }
    if map.is_empty() {
        return Err(anyhow!("YAML frontmatter must be a mapping/object."));
    }
    Ok(map)
}

fn parse_simple_value(value_raw: &str) -> Value {
    let lower = value_raw.to_ascii_lowercase();
    if value_raw.is_empty() || lower == "null" || lower == "none" || lower == "~" {
        return Value::Null;
    }

    if value_raw.starts_with('[') && value_raw.ends_with(']') {
        let inner = &value_raw[1..value_raw.len() - 1];
        let items = inner
            .split(',')
            .map(|part| part.trim())
            .filter(|part| !part.is_empty())
            .map(|part| {
                let stripped = part
                    .strip_prefix('"')
                    .and_then(|v| v.strip_suffix('"'))
                    .or_else(|| part.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                    .unwrap_or(part);
                Value::String(stripped.to_string())
            })
            .collect::<Vec<_>>();
        return Value::Sequence(items);
    }

    if (value_raw.starts_with('"') && value_raw.ends_with('"'))
        || (value_raw.starts_with('\'') && value_raw.ends_with('\''))
    {
        return Value::String(value_raw[1..value_raw.len() - 1].to_string());
    }

    Value::String(value_raw.to_string())
}

fn join_frontmatter(meta: &Mapping, body: &str) -> Result<String> {
    let frontmatter = dump_simple_frontmatter(meta);
    let body = body.trim_end();
    Ok(format!("---\n{}---\n\n{}\n", frontmatter, body))
}

fn dump_simple_frontmatter(meta: &Mapping) -> String {
    let mut lines = Vec::new();
    for (key, value) in meta {
        let key = key.as_str().unwrap_or("");
        lines.push(format!("{}: {}", key, dump_simple_value(value)));
    }
    format!("{}\n", lines.join("\n"))
}

fn dump_simple_value(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(v) => {
            if *v {
                "true".to_string()
            } else {
                "false".to_string()
            }
        }
        Value::Number(n) => n.to_string(),
        Value::Sequence(items) => {
            let inner = items
                .iter()
                .map(dump_simple_value)
                .collect::<Vec<_>>()
                .join(", ");
            format!("[{}]", inner)
        }
        Value::String(text) => dump_simple_string(text),
        _ => {
            let rendered = serde_yaml::to_string(value).unwrap_or_else(|_| "".to_string());
            dump_simple_string(rendered.trim())
        }
    }
}

fn dump_simple_string(text: &str) -> String {
    if text.is_empty() {
        return "\"\"".to_string();
    }
    if text.contains(':') || text.trim() != text {
        return format!("\"{}\"", text.replace('"', "\\\""));
    }
    text.to_string()
}

fn read_ticket(path: &Path) -> Result<(Mapping, String)> {
    let content = fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    split_frontmatter(&content)
}

fn write_ticket(path: &Path, meta: &Mapping, body: &str) -> Result<()> {
    let content = join_frontmatter(meta, body)?;
    fs::write(path, content).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn default_ticket_template_text() -> &'static str {
    "---\nid: T-000000\ntitle: Template: replace title\nstatus: ready\npriority: p1\ntype: code\neffort: s\nlabels: []\ntags: []\nowner: null\ncreated: 1970-01-01T00:00:00Z\nupdated: 1970-01-01T00:00:00Z\ndepends_on: []\nbranch: null\nretry_count: 0\nretry_limit: 3\nallocated_to: null\nallocated_at: null\nlease_expires_at: null\nlast_error: null\nlast_attempted_at: null\n---\n\n## Goal\nWrite a single-sentence goal.\n\n## Acceptance Criteria\n- [ ] Define clear, testable checks (2–5 items)\n\n## Notes\n\n## Agent Assignment\n- Suggested owner: agent-name\n- Suggested branch: feature/short-name\n\n## Implementation Plan\n- [ ] Describe 2-4 concrete execution steps\n- [ ] List test/validation commands to run\n- [ ] Note any dependency handoff requirements\n\n## Queue Lifecycle (if allocated)\n- [ ] Add progress with `mt comment <id> \"...\"`\n- [ ] If blocked/failing, run `mt fail-task <id> --error \"...\"`\n- [ ] On completion, move to `needs_review` then `done`\n"
}

fn ensure_ticket_template(repo_root: &Path) -> Result<bool> {
    let path = ticket_template_path(repo_root);
    if path.exists() {
        return Ok(false);
    }
    fs::create_dir_all(tickets_dir(repo_root))?;
    fs::write(path, default_ticket_template_text())?;
    Ok(true)
}

fn iter_ticket_files(tdir: &Path) -> Result<Vec<PathBuf>> {
    if !tdir.is_dir() {
        return Ok(Vec::new());
    }
    let re = ticket_file_regex();
    let mut out = Vec::new();
    for entry in fs::read_dir(tdir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if re.is_match(name) {
                out.push(path);
            }
        }
    }
    out.sort();
    Ok(out)
}

fn iter_ticket_files_recursive(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    if !root.is_dir() {
        return Ok(());
    }
    let re = ticket_file_regex();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            iter_ticket_files_recursive(&path, out)?;
        } else {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if re.is_match(name) {
                out.push(path);
            }
        }
    }
    Ok(())
}

fn all_ticket_paths(repo_root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    iter_ticket_files_recursive(&tickets_dir(repo_root), &mut paths)?;
    iter_ticket_files_recursive(&archive_dir(repo_root), &mut paths)?;
    iter_ticket_files_recursive(&backlogs_dir(repo_root), &mut paths)?;
    iter_ticket_files_recursive(&errors_dir(repo_root), &mut paths)?;
    let mut dedupe = BTreeSet::new();
    for p in paths {
        dedupe.insert(p);
    }
    Ok(dedupe.into_iter().collect())
}

fn ticket_id_from_path(path: &Path) -> Option<String> {
    let re = ticket_file_regex();
    let name = path.file_name()?.to_str()?;
    let captures = re.captures(name)?;
    captures.get(1).map(|m| m.as_str().to_string())
}

fn extract_ticket_number(ticket_id: &str) -> Result<u32> {
    if !id_regex().is_match(ticket_id) {
        return Err(anyhow!("Invalid ticket id: {}", ticket_id));
    }
    let number = ticket_id
        .split('-')
        .nth(1)
        .ok_or_else(|| anyhow!("missing ticket numeric suffix"))?
        .parse::<u32>()
        .context("failed to parse ticket numeric suffix")?;
    Ok(number)
}

fn scan_max_ticket_number(repo_root: &Path) -> Result<u32> {
    let mut max_n = 0u32;
    for p in all_ticket_paths(repo_root)? {
        if let Some(ticket_id) = ticket_id_from_path(&p) {
            let n = extract_ticket_number(&ticket_id)?;
            if n > max_n {
                max_n = n;
            }
        }
    }
    Ok(max_n)
}

fn read_last_ticket_number(repo_root: &Path) -> Option<u32> {
    let state_file = last_ticket_id_path(repo_root);
    if !state_file.exists() {
        return None;
    }
    let raw = fs::read_to_string(state_file).ok()?;
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if id_regex().is_match(raw) {
        return extract_ticket_number(raw).ok();
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return raw.parse::<u32>().ok();
    }
    None
}

fn write_last_ticket_number(repo_root: &Path, number: u32) -> Result<()> {
    fs::create_dir_all(tickets_dir(repo_root))?;
    fs::write(last_ticket_id_path(repo_root), format!("T-{number:06}\n"))?;
    Ok(())
}

fn next_ticket_id_for_repo(repo_root: &Path) -> Result<String> {
    let tracked = read_last_ticket_number(repo_root).unwrap_or(0);
    let base = if tracked > 0 {
        tracked
    } else {
        scan_max_ticket_number(repo_root)?
    };
    let next = base + 1;
    write_last_ticket_number(repo_root, next)?;
    Ok(format!("T-{next:06}"))
}

fn map_get_string(meta: &Mapping, key: &str) -> Option<String> {
    meta.get(Value::String(key.to_string()))
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn map_get_i64(meta: &Mapping, key: &str) -> Option<i64> {
    match meta.get(Value::String(key.to_string())) {
        Some(Value::Number(number)) => number.as_i64(),
        Some(Value::String(text)) => text.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn map_get_string_array(meta: &Mapping, key: &str) -> Vec<String> {
    match meta.get(Value::String(key.to_string())) {
        Some(Value::Sequence(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect(),
        _ => Vec::new(),
    }
}

fn map_get_status(meta: &Mapping) -> String {
    map_get_string(meta, "status").unwrap_or_else(|| "ready".to_string())
}

fn map_set_string(meta: &mut Mapping, key: &str, value: &str) {
    meta.insert(
        Value::String(key.to_string()),
        Value::String(value.to_string()),
    );
}

fn map_set_optional_string(meta: &mut Mapping, key: &str, value: Option<&str>) {
    match value {
        Some(v) => {
            meta.insert(
                Value::String(key.to_string()),
                Value::String(v.to_string()),
            );
        }
        None => {
            meta.insert(Value::String(key.to_string()), Value::Null);
        }
    };
}

fn map_set_string_array(meta: &mut Mapping, key: &str, values: Vec<String>) {
    let sequence = values.into_iter().map(Value::String).collect::<Vec<_>>();
    meta.insert(Value::String(key.to_string()), Value::Sequence(sequence));
}

fn normalize_meta(meta: &mut Mapping) {
    if !meta.contains_key(Value::String("labels".to_string())) {
        map_set_string_array(meta, "labels", Vec::new());
    }
    if !meta.contains_key(Value::String("depends_on".to_string())) {
        map_set_string_array(meta, "depends_on", Vec::new());
    }
    if !meta.contains_key(Value::String("owner".to_string())) {
        map_set_optional_string(meta, "owner", None);
    }
    if !meta.contains_key(Value::String("branch".to_string())) {
        map_set_optional_string(meta, "branch", None);
    }
    if !meta.contains_key(Value::String("effort".to_string())) {
        map_set_string(meta, "effort", "s");
    }
    if !meta.contains_key(Value::String("tags".to_string())) {
        map_set_string_array(meta, "tags", Vec::new());
    }
    if !meta.contains_key(Value::String("retry_count".to_string())) {
        meta.insert(
            Value::String("retry_count".to_string()),
            Value::Number(serde_yaml::Number::from(0)),
        );
    }
    if !meta.contains_key(Value::String("retry_limit".to_string())) {
        meta.insert(
            Value::String("retry_limit".to_string()),
            Value::Number(serde_yaml::Number::from(3)),
        );
    }
    if !meta.contains_key(Value::String("allocated_to".to_string())) {
        map_set_optional_string(meta, "allocated_to", None);
    }
    if !meta.contains_key(Value::String("allocated_at".to_string())) {
        map_set_optional_string(meta, "allocated_at", None);
    }
    if !meta.contains_key(Value::String("lease_expires_at".to_string())) {
        map_set_optional_string(meta, "lease_expires_at", None);
    }
    if !meta.contains_key(Value::String("last_error".to_string())) {
        map_set_optional_string(meta, "last_error", None);
    }
    if !meta.contains_key(Value::String("last_attempted_at".to_string())) {
        map_set_optional_string(meta, "last_attempted_at", None);
    }
}

fn now_utc_iso() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn lease_expired(meta: &Mapping, now: chrono::DateTime<Utc>) -> bool {
    let Some(raw) = map_get_string(meta, "lease_expires_at") else {
        return false;
    };
    if raw.trim().is_empty() {
        return false;
    }
    let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(raw.trim()) else {
        return false;
    };
    now >= parsed.with_timezone(&Utc)
}

fn append_incident(repo_root: &Path, message: &str) -> Result<()> {
    fs::create_dir_all(tickets_dir(repo_root))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(incidents_log_path(repo_root))?;
    use std::io::Write;
    writeln!(file, "{} {}", now_utc_iso(), message)?;
    Ok(())
}

fn ticket_summary(meta: &Mapping) -> String {
    let id = map_get_string(meta, "id").unwrap_or_else(|| "?".to_string());
    let status = map_get_string(meta, "status").unwrap_or_else(|| "?".to_string());
    let priority = map_get_string(meta, "priority").unwrap_or_else(|| "?".to_string());
    let ticket_type = map_get_string(meta, "type").unwrap_or_else(|| "?".to_string());
    let effort = map_get_string(meta, "effort").unwrap_or_else(|| "?".to_string());
    let owner = map_get_string(meta, "owner").unwrap_or_default();
    let title = map_get_string(meta, "title").unwrap_or_default().trim().to_string();
    let labels = map_get_string_array(meta, "labels").join(",");
    format!(
        "{id}  {status:<12} {priority:<2} {ticket_type:<8} {effort:<2} {owner:<12}  {title}  [{labels}]"
    )
}

fn find_ticket_by_id(repo_root: &Path, ticket_id: &str) -> Result<PathBuf> {
    if !id_regex().is_match(ticket_id) {
        return Err(anyhow!("Invalid ticket id: {}", ticket_id));
    }
    let path = tickets_dir(repo_root).join(format!("{ticket_id}.md"));
    if !path.exists() {
        return Err(anyhow!("Ticket not found: {}", path.display()));
    }
    Ok(path)
}

fn _default_branch(meta: &Mapping) -> String {
    let title = map_get_string(meta, "title").unwrap_or_default().to_lowercase();
    let mut slug = String::new();
    let mut last_dash = false;
    for character in title.chars() {
        if character.is_ascii_alphanumeric() {
            slug.push(character);
            last_dash = false;
        } else if !last_dash {
            slug.push('-');
            last_dash = true;
        }
    }
    let slug = slug.trim_matches('-').to_string();
    let slug = if slug.is_empty() { "task".to_string() } else { slug };
    let slug = if slug.len() > 40 {
        slug.chars().take(40).collect::<String>()
    } else {
        slug
    };
    let id = map_get_string(meta, "id").unwrap_or_default().to_lowercase();
    format!("bug/{id}-{slug}")
}

fn load_active_ticket_records(repo_root: &Path) -> Result<Vec<(PathBuf, Mapping)>> {
    let mut records = Vec::new();
    for path in iter_ticket_files(&tickets_dir(repo_root))? {
        let (mut meta, _body) = read_ticket(&path)?;
        normalize_meta(&mut meta);
        records.push((path, meta));
    }
    Ok(records)
}

fn deps_satisfied(meta: &Mapping, id_to_meta: &BTreeMap<String, Mapping>) -> (bool, Vec<String>) {
    let mut missing = Vec::new();
    for dep in map_get_string_array(meta, "depends_on") {
        match id_to_meta.get(&dep) {
            Some(dep_meta) => {
                if map_get_status(dep_meta) != "done" {
                    missing.push(dep);
                }
            }
            None => missing.push(dep),
        }
    }
    (missing.is_empty(), missing)
}

fn validate_transition(old_status: &str, new_status: &str) -> Option<String> {
    let mut allowed: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    allowed.insert("ready", BTreeSet::from(["claimed", "blocked"]));
    allowed.insert("claimed", BTreeSet::from(["needs_review", "blocked", "ready"]));
    allowed.insert("blocked", BTreeSet::from(["ready", "claimed"]));
    allowed.insert("needs_review", BTreeSet::from(["done", "claimed"]));
    allowed.insert("done", BTreeSet::new());

    let Some(next_states) = allowed.get(old_status) else {
        return Some(format!("unknown old status {old_status:?}"));
    };
    if !DEFAULT_STATES.contains(&new_status) {
        return Some(format!("unknown new status {new_status:?}"));
    }
    if !next_states.contains(new_status) {
        return Some(format!("invalid transition {old_status:?} -> {new_status:?}"));
    }
    None
}

fn cmd_claim(id: String, owner: String, branch: String, ignore_deps: bool, force: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);
    let old = map_get_status(&meta);

    if old != "ready" && !force {
        return Err(anyhow!(
            "Refusing to claim: status is {old:?} (expected 'ready'). Use --force to override."
        ));
    }

    let records = load_active_ticket_records(&repo)?;
    let mut id_to_meta = BTreeMap::new();
    for (_path, ticket_meta) in records {
        if let Some(tid) = map_get_string(&ticket_meta, "id") {
            id_to_meta.insert(tid, ticket_meta);
        }
    }
    let (ok, missing) = deps_satisfied(&meta, &id_to_meta);
    if !ok && !ignore_deps {
        return Err(anyhow!(
            "Refusing to claim: dependencies not done: {:?}. Use --ignore-deps to override.",
            missing
        ));
    }

    map_set_string(&mut meta, "status", "claimed");
    map_set_string(&mut meta, "owner", &owner);
    let branch_name = if branch.trim().is_empty() {
        _default_branch(&meta)
    } else {
        branch.trim().to_string()
    };
    map_set_string(&mut meta, "branch", &branch_name);
    map_set_string(&mut meta, "updated", &today_str());
    write_ticket(&path, &meta, &body)?;
    println!("claimed {id} as {owner} (branch: {branch_name})");
    Ok(0)
}

fn cmd_set_status(id: String, status: String, force: bool, clear_owner: bool) -> Result<i32> {
    if !DEFAULT_STATES.contains(&status.as_str()) {
        return Err(anyhow!("Invalid status {status:?}. Allowed: {:?}", DEFAULT_STATES));
    }

    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    let old = map_get_status(&meta);
    if old == status {
        println!("{id} already {status}");
        return Ok(0);
    }

    if !force {
        if let Some(message) = validate_transition(&old, &status) {
            return Err(anyhow!("Refusing: {message}. Use --force to override."));
        }
    }

    if status == "ready" && clear_owner {
        map_set_optional_string(&mut meta, "owner", None);
        map_set_optional_string(&mut meta, "branch", None);
    }
    map_set_string(&mut meta, "status", &status);
    map_set_string(&mut meta, "updated", &today_str());
    write_ticket(&path, &meta, &body)?;
    println!("{id}: {old} -> {status}");
    Ok(0)
}

fn cmd_done(id: String, force: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    let old = map_get_status(&meta);
    if old != "needs_review" && !force {
        return Err(anyhow!(
            "Refusing to mark done: status is {old:?} (expected 'needs_review'). Use set-status first or --force."
        ));
    }

    map_set_string(&mut meta, "status", "done");
    map_set_string(&mut meta, "updated", &today_str());
    write_ticket(&path, &meta, &body)?;
    println!("done {id}");
    Ok(0)
}

fn cmd_archive(id: String, force: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, _body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    let status = map_get_status(&meta);
    if status != "done" && !force {
        return Err(anyhow!(
            "Refusing to archive: status is {status:?} (expected 'done'). Use --force to override."
        ));
    }

    let mut dependents = Vec::new();
    for candidate in load_active_ticket_records(&repo)? {
        let (_candidate_path, candidate_meta) = candidate;
        let candidate_id = map_get_string(&candidate_meta, "id").unwrap_or_default();
        if candidate_id == id {
            continue;
        }
        let deps = map_get_string_array(&candidate_meta, "depends_on");
        if deps.iter().any(|dep| dep == &id) {
            dependents.push(candidate_id);
        }
    }

    if !dependents.is_empty() && !force {
        dependents.sort();
        return Err(anyhow!(
            "Refusing to archive: active tickets depend on this ticket: {}. Resolve/update their depends_on first. Warning: using --force can leave invalid active references to archived tickets.",
            dependents.join(", ")
        ));
    }
    if !dependents.is_empty() && force {
        dependents.sort();
        eprintln!(
            "Warning: force-archiving with active dependents: {}. This can create invalid board state where active tickets depend_on archived tickets.",
            dependents.join(", ")
        );
    }

    let target_dir = archive_dir(&repo);
    fs::create_dir_all(&target_dir)?;
    let destination = target_dir.join(
        path.file_name()
            .ok_or_else(|| anyhow!("missing archive filename"))?,
    );
    if destination.exists() {
        return Err(anyhow!(
            "Refusing to archive: destination already exists: {}",
            destination.display()
        ));
    }
    fs::rename(&path, &destination)?;
    let rel = destination
        .strip_prefix(&repo)
        .unwrap_or(&destination)
        .display()
        .to_string();
    println!("archived {id} -> {rel}");
    Ok(0)
}

fn validate_wip_limit(records: &[(PathBuf, Mapping)], max_claimed_per_owner: i32) -> Vec<String> {
    let mut counts: BTreeMap<String, i32> = BTreeMap::new();
    for (_path, meta) in records {
        if map_get_status(meta) == "claimed" {
            let owner = map_get_string(meta, "owner").unwrap_or_default();
            if !owner.is_empty() {
                let entry = counts.entry(owner).or_insert(0);
                *entry += 1;
            }
        }
    }

    let mut errors = Vec::new();
    for (owner, count) in counts {
        if count > max_claimed_per_owner {
            errors.push(format!(
                "owner {owner:?} has {count} claimed tickets (max {max_claimed_per_owner})"
            ));
        }
    }
    errors
}

fn validate_depends(records: &[(PathBuf, Mapping)], archived_ids: &BTreeSet<String>) -> Vec<String> {
    let mut existing: BTreeSet<String> = BTreeSet::new();
    for (_path, meta) in records {
        if let Some(ticket_id) = map_get_string(meta, "id") {
            existing.insert(ticket_id);
        }
    }

    let mut errors = Vec::new();
    for (_path, meta) in records {
        let ticket_id = map_get_string(meta, "id").unwrap_or_else(|| "<missing-id>".to_string());
        for dep in map_get_string_array(meta, "depends_on") {
            if !existing.contains(&dep) {
                if archived_ids.contains(&dep) {
                    errors.push(format!(
                        "{ticket_id} depends_on archived ticket {dep} (fix by unarchiving {dep} or removing/updating {ticket_id}.depends_on; avoid mt archive --force when active dependents exist)"
                    ));
                } else {
                    errors.push(format!("{ticket_id} depends_on missing ticket {dep}"));
                }
            }
        }
    }
    errors
}

fn cmd_validate(max_claimed_per_owner: i32, enforce_done_deps: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let mut records = Vec::new();
    let mut errors = Vec::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        match read_ticket(&path) {
            Ok((mut meta, _body)) => {
                normalize_meta(&mut meta);
                records.push((path.clone(), meta));
            }
            Err(err) => {
                let name = path.file_name().and_then(|f| f.to_str()).unwrap_or("<unknown>");
                errors.push(format!("{name}: {err}"));
            }
        }
    }

    let mut archived_ids = BTreeSet::new();
    let mut archived_paths = Vec::new();
    iter_ticket_files_recursive(&archive_dir(&repo), &mut archived_paths)?;
    for archived_path in archived_paths {
        if let Ok((mut meta, _body)) = read_ticket(&archived_path) {
            normalize_meta(&mut meta);
            if let Some(ticket_id) = map_get_string(&meta, "id") {
                archived_ids.insert(ticket_id);
            }
        }
    }

    let id_re = id_regex();
    let date_re = Regex::new(r"^(\d{4})-(\d{2})-(\d{2})(?:T\d{2}:\d{2}:\d{2}Z)?$").expect("valid date regex");
    let required_fields = &[
        "id", "title", "status", "priority", "type", "labels",
        "owner", "created", "updated", "depends_on", "branch",
    ];

    for (path, meta) in &records {
        let filename = path.file_name().and_then(|f| f.to_str()).unwrap_or("<unknown>");

        // Required field presence
        for &field in required_fields {
            if meta.get(Value::String(field.to_string())).is_none() {
                errors.push(format!("{filename}: missing required field {field:?}"));
            }
        }

        // id: pattern ^T-\d{6}$
        if let Some(id) = map_get_string(meta, "id") {
            if !id_re.is_match(&id) {
                errors.push(format!("{filename}: id must match T-XXXXXX pattern, got {id:?}"));
            }
        }

        // title: minLength 3
        if let Some(title) = map_get_string(meta, "title") {
            if title.len() < 3 {
                errors.push(format!("{filename}: title must be at least 3 characters, got {title:?}"));
            }
        }

        // status: enum check
        let status = map_get_status(meta);
        if !DEFAULT_STATES.contains(&status.as_str()) {
            errors.push(format!("{filename}: status must be one of {:?}, got {status:?}", DEFAULT_STATES));
        }

        // priority: enum check
        let priority = map_get_string(meta, "priority").unwrap_or_default();
        if !DEFAULT_PRIORITIES.contains(&priority.as_str()) {
            errors.push(format!("{filename}: priority must be one of {:?}, got {priority:?}", DEFAULT_PRIORITIES));
        }

        // type: enum check
        let ticket_type = map_get_string(meta, "type").unwrap_or_default();
        if !DEFAULT_TYPES.contains(&ticket_type.as_str()) {
            errors.push(format!("{filename}: type must be one of {:?}, got {ticket_type:?}", DEFAULT_TYPES));
        }

        // effort: enum check
        let effort = map_get_string(meta, "effort").unwrap_or_else(|| "s".to_string());
        if !DEFAULT_EFFORTS.contains(&effort.as_str()) {
            errors.push(format!("{filename}: effort must be one of {:?}, got {effort:?}", DEFAULT_EFFORTS));
        }

        // labels: must be array
        if let Some(val) = meta.get(Value::String("labels".to_string())) {
            if !val.is_sequence() && !val.is_null() {
                errors.push(format!("{filename}: labels must be an array"));
            }
        }

        // depends_on: must be array
        if let Some(val) = meta.get(Value::String("depends_on".to_string())) {
            if !val.is_sequence() && !val.is_null() {
                errors.push(format!("{filename}: depends_on must be an array"));
            }
        }

        // owner: null or non-empty string
        if let Some(val) = meta.get(Value::String("owner".to_string())) {
            if !val.is_null() {
                if let Some(s) = val.as_str() {
                    if s.is_empty() {
                        errors.push(format!("{filename}: owner must be null or a non-empty string"));
                    }
                }
            }
        }

        // branch: null or non-empty string
        if let Some(val) = meta.get(Value::String("branch".to_string())) {
            if !val.is_null() {
                if let Some(s) = val.as_str() {
                    if s.is_empty() {
                        errors.push(format!("{filename}: branch must be null or a non-empty string"));
                    }
                }
            }
        }

        // created: ISO date pattern
        let created = map_get_string(meta, "created").unwrap_or_default();
        if !created.is_empty() && !date_re.is_match(&created) {
            errors.push(format!("{filename}: created must match YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got {created:?}"));
        }

        // updated: ISO date pattern
        let updated = map_get_string(meta, "updated").unwrap_or_default();
        if !updated.is_empty() && !date_re.is_match(&updated) {
            errors.push(format!("{filename}: updated must match YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ, got {updated:?}"));
        }

        // updated >= created (compare as strings, ISO dates sort lexicographically)
        if !created.is_empty() && !updated.is_empty() && updated < created {
            errors.push(format!("{filename}: updated ({updated}) is earlier than created ({created})"));
        }

        // Business logic: claimed must have owner
        if status == "claimed" && map_get_string(meta, "owner").unwrap_or_default().is_empty() {
            errors.push(format!("{filename}: claimed ticket must have owner"));
        }
        // Business logic: needs_review/done must have branch
        if (status == "needs_review" || status == "done")
            && map_get_string(meta, "branch").unwrap_or_default().is_empty()
        {
            errors.push(format!("{filename}: status {status} should have branch set"));
        }
    }

    errors.extend(validate_wip_limit(&records, max_claimed_per_owner));
    errors.extend(validate_depends(&records, &archived_ids));

    if enforce_done_deps {
        let mut id_to_meta = BTreeMap::new();
        for (_path, meta) in &records {
            if let Some(ticket_id) = map_get_string(meta, "id") {
                id_to_meta.insert(ticket_id, meta.clone());
            }
        }
        for (_path, meta) in &records {
            let status = map_get_status(meta);
            if status == "claimed" || status == "needs_review" || status == "done" {
                let (ok, missing) = deps_satisfied(meta, &id_to_meta);
                if !ok && !map_get_string_array(meta, "depends_on").is_empty() {
                    let ticket_id = map_get_string(meta, "id").unwrap_or_else(|| "<missing-id>".to_string());
                    errors.push(format!("{ticket_id} status {status} but deps not done: {:?}", missing));
                }
            }
        }
    }

    if !errors.is_empty() {
        eprintln!("MuonTickets validation FAILED:");
        for error in errors {
            eprintln!(" - {error}");
        }
        return Ok(1);
    }

    println!("MuonTickets validation OK.");
    Ok(0)
}

fn cmd_init() -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let tdir = tickets_dir(&repo);
    if !tdir.is_dir() {
        fs::create_dir_all(&tdir)?;
        println!("created {}", tdir.display());
    } else {
        println!("tickets dir exists: {}", tdir.display());
    }

    if ensure_ticket_template(&repo)? {
        println!("created {}", ticket_template_path(&repo).display());
    }

    if iter_ticket_files(&tdir)?.is_empty() {
        let tid = next_ticket_id_for_repo(&repo)?;
        let mut meta = Mapping::new();
        map_set_string(&mut meta, "id", &tid);
        map_set_string(&mut meta, "title", "Example: replace this ticket");
        map_set_string(&mut meta, "status", "ready");
        map_set_string(&mut meta, "priority", "p2");
        map_set_string(&mut meta, "type", "chore");
        map_set_string(&mut meta, "effort", "xs");
        map_set_string_array(&mut meta, "labels", vec!["example".to_string()]);
        map_set_string_array(&mut meta, "tags", Vec::new());
        map_set_optional_string(&mut meta, "owner", None);
        let today = today_str();
        map_set_string(&mut meta, "created", &today);
        map_set_string(&mut meta, "updated", &today);
        map_set_string_array(&mut meta, "depends_on", Vec::new());
        map_set_optional_string(&mut meta, "branch", None);
        normalize_meta(&mut meta);

        let body = "## Goal\nReplace this example with a real task.\n\n## Acceptance Criteria\n- [ ] Delete or edit this ticket\n- [ ] Create at least one real ticket with `mt new`\n\n## Notes\nThis repository uses MuonTickets for agent-friendly coordination.\n";
        write_ticket(&tdir.join(format!("{tid}.md")), &meta, body)?;
        println!("created example ticket {tid}");
    } else {
        let tracked = read_last_ticket_number(&repo);
        let scanned = scan_max_ticket_number(&repo)?;
        if tracked.is_none() || tracked.unwrap_or(0) < scanned {
            write_last_ticket_number(&repo, scanned)?;
            println!(
                "updated {} to T-{scanned:06}",
                last_ticket_id_path(&repo).display()
            );
        }
    }
    Ok(0)
}

fn cmd_new(
    title: String,
    priority: Option<String>,
    ticket_type: Option<String>,
    effort: Option<String>,
    label: Vec<String>,
    tag: Vec<String>,
    depends_on: Vec<String>,
    goal: String,
) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let tdir = tickets_dir(&repo);
    fs::create_dir_all(&tdir)?;

    let ticket_id = next_ticket_id_for_repo(&repo)?;
    let title = title.trim().to_string();

    let mut template_meta = Mapping::new();
    let mut template_body = String::new();
    let template_path = ticket_template_path(&repo);
    if template_path.exists() {
        let (mut meta, body) = read_ticket(&template_path).map_err(|err| {
            anyhow!(
                "Invalid ticket template at {}: {}",
                template_path.display(),
                err
            )
        })?;
        normalize_meta(&mut meta);
        template_meta = meta;
        template_body = body;
    }

    let final_priority = priority
        .or_else(|| map_get_string(&template_meta, "priority"))
        .unwrap_or_else(|| "p1".to_string());
    let final_type = ticket_type
        .or_else(|| map_get_string(&template_meta, "type"))
        .unwrap_or_else(|| "code".to_string());
    let final_effort = effort
        .or_else(|| map_get_string(&template_meta, "effort"))
        .unwrap_or_else(|| "s".to_string());

    if !DEFAULT_PRIORITIES.contains(&final_priority.as_str()) {
        return Err(anyhow!(
            "Invalid priority {:?} from CLI/template. Allowed: {:?}",
            final_priority,
            DEFAULT_PRIORITIES
        ));
    }
    if !DEFAULT_TYPES.contains(&final_type.as_str()) {
        return Err(anyhow!(
            "Invalid type {:?} from CLI/template. Allowed: {:?}",
            final_type,
            DEFAULT_TYPES
        ));
    }
    if !DEFAULT_EFFORTS.contains(&final_effort.as_str()) {
        return Err(anyhow!(
            "Invalid effort {:?} from CLI/template. Allowed: {:?}",
            final_effort,
            DEFAULT_EFFORTS
        ));
    }

    let labels = if label.is_empty() {
        map_get_string_array(&template_meta, "labels")
    } else {
        label
    };
    let tags = if tag.is_empty() {
        map_get_string_array(&template_meta, "tags")
    } else {
        tag
    };
    let deps = if depends_on.is_empty() {
        map_get_string_array(&template_meta, "depends_on")
    } else {
        depends_on
    };

    let mut status = map_get_string(&template_meta, "status").unwrap_or_else(|| "ready".to_string());
    if !DEFAULT_STATES.contains(&status.as_str()) {
        status = "ready".to_string();
    }

    let owner = map_get_string(&template_meta, "owner");
    let branch = map_get_string(&template_meta, "branch");

    let mut meta = Mapping::new();
    map_set_string(&mut meta, "id", &ticket_id);
    map_set_string(&mut meta, "title", &title);
    map_set_string(&mut meta, "status", &status);
    map_set_string(&mut meta, "priority", &final_priority);
    map_set_string(&mut meta, "type", &final_type);
    map_set_string(&mut meta, "effort", &final_effort);
    map_set_string_array(&mut meta, "labels", labels);
    map_set_string_array(&mut meta, "tags", tags);
    map_set_optional_string(&mut meta, "owner", owner.as_deref());
    let today = today_str();
    map_set_string(&mut meta, "created", &today);
    map_set_string(&mut meta, "updated", &today);
    map_set_string_array(&mut meta, "depends_on", deps);
    map_set_optional_string(&mut meta, "branch", branch.as_deref());
    normalize_meta(&mut meta);

    let body = if !goal.trim().is_empty() {
        format!(
            "## Goal\n{}\n\n## Acceptance Criteria\n- [ ] Define clear, testable checks (2–5 items)\n\n## Notes\n",
            goal.trim()
        )
    } else if !template_body.trim().is_empty() {
        template_body
    } else {
        "## Goal\nWrite a single-sentence goal.\n\n## Acceptance Criteria\n- [ ] Define clear, testable checks (2–5 items)\n\n## Notes\n".to_string()
    };

    let path = tdir.join(format!("{ticket_id}.md"));
    write_ticket(&path, &meta, &body)?;
    println!("{}", path.display());
    Ok(0)
}

fn cmd_ls(
    status: Option<String>,
    label: Vec<String>,
    owner: Option<String>,
    priority: Option<String>,
    ticket_type: Option<String>,
    show_invalid: bool,
) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let tdir = tickets_dir(&repo);
    let mut rows = Vec::new();
    for path in iter_ticket_files(&tdir)? {
        match read_ticket(&path) {
            Ok((mut meta, _body)) => {
                normalize_meta(&mut meta);
                if let Some(ref wanted) = status {
                    if map_get_string(&meta, "status").unwrap_or_default() != *wanted {
                        continue;
                    }
                }
                if let Some(ref owner_filter) = owner {
                    let meta_owner = map_get_string(&meta, "owner");
                    if owner_filter.is_empty() {
                        if meta_owner.is_some() {
                            continue;
                        }
                    } else if meta_owner.unwrap_or_default() != *owner_filter {
                        continue;
                    }
                }
                if let Some(ref wanted) = priority {
                    if map_get_string(&meta, "priority").unwrap_or_default() != *wanted {
                        continue;
                    }
                }
                if let Some(ref wanted) = ticket_type {
                    if map_get_string(&meta, "type").unwrap_or_default() != *wanted {
                        continue;
                    }
                }
                if !label.is_empty() {
                    let labels = map_get_string_array(&meta, "labels");
                    let label_set = labels.into_iter().collect::<BTreeSet<_>>();
                    if !label.iter().all(|item| label_set.contains(item)) {
                        continue;
                    }
                }
                rows.push(ticket_summary(&meta));
            }
            Err(err) => {
                if show_invalid {
                    let filename = path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("<unknown>");
                    rows.push(format!("{filename}  PARSE_ERROR  {err}"));
                }
            }
        }
    }

    if !rows.is_empty() {
        println!("ID       STATUS        PR TYPE     EF OWNER         TITLE  [LABELS]");
        println!("{}", "-".repeat(110));
        for row in rows {
            println!("{row}");
        }
    }
    Ok(0)
}

fn cmd_show(ticket_id: String) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &ticket_id)?;
    let (meta, body) = read_ticket(&path)?;
    print!("{}", join_frontmatter(&meta, &body)?);
    Ok(0)
}

fn compute_score(meta: &Mapping, id_to_meta: &BTreeMap<String, Mapping>) -> f64 {
    let priority = map_get_string(meta, "priority").unwrap_or_else(|| "p2".to_string());
    let effort = map_get_string(meta, "effort").unwrap_or_else(|| "s".to_string());
    let deps = map_get_string_array(meta, "depends_on");
    let created = map_get_string(meta, "created").unwrap_or_else(|| "1970-01-01".to_string());

    let base = priority_weight(&priority) + effort_weight(&effort);
    let dep_penalty = 5 * (deps.len() as i32);

    let age_days = chrono::NaiveDate::parse_from_str(&created, "%Y-%m-%d")
        .ok()
        .map(|created_date| (Utc::now().date_naive() - created_date).num_days())
        .unwrap_or(0)
        .clamp(0, 365) as i32;

    let (ok, _) = deps_satisfied(meta, id_to_meta);
    if !ok {
        return -1_000_000_000.0;
    }

    (base + age_days - dep_penalty) as f64
}

fn append_progress_log(body: &str, line: &str) -> String {
    let marker = "## Progress Log";
    let mut updated = body.trim_end().to_string();
    if !updated.contains(marker) {
        if !updated.is_empty() {
            updated.push_str("\n\n");
        }
        updated.push_str(marker);
        updated.push('\n');
    }
    format!("{}\n- {}: {}\n", updated.trim_end(), today_str(), line.trim())
}

fn cmd_comment(id: String, text: String) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);
    map_set_string(&mut meta, "updated", &today_str());
    let body = append_progress_log(&body, &text);
    write_ticket(&path, &meta, &body)?;
    println!("commented on {id}");
    Ok(0)
}

fn skill_pick_profiles(skill: &str) -> Option<(Vec<&'static str>, Vec<&'static str>)> {
    match skill {
        "design"   => Some((vec!["design"],   vec!["spec", "docs"])),
        "database" => Some((vec!["database"], vec!["code", "refactor", "tests"])),
        "review"   => Some((vec!["review"],   vec!["tests", "docs"])),
        _ => None,
    }
}

fn role_pick_profiles(role: &str) -> Option<(Vec<&'static str>, Vec<&'static str>)> {
    match role {
        "architect" => Some((vec!["design"],   vec!["spec", "docs", "refactor"])),
        "devops"    => Some((vec!["devops"],   vec!["code", "chore", "docs"])),
        "developer" => Some((vec!["feature"],  vec!["code", "tests", "refactor"])),
        "reviewer"  => Some((vec!["review"],   vec!["tests", "docs"])),
        _ => None,
    }
}

fn cmd_pick(
    owner: String,
    label: Vec<String>,
    avoid_label: Vec<String>,
    priority: Option<String>,
    ticket_type: Option<String>,
    branch: String,
    ignore_deps: bool,
    max_claimed_per_owner: i32,
    skill: Option<String>,
    role: Option<String>,
    as_json: bool,
) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let mut tickets = Vec::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        let (mut meta, _body) = match read_ticket(&path) {
            Ok(value) => value,
            Err(_) => continue,
        };
        normalize_meta(&mut meta);
        tickets.push((path, meta));
    }

    let mut id_to_meta = BTreeMap::new();
    for (_path, meta) in &tickets {
        if let Some(ticket_id) = map_get_string(meta, "id") {
            id_to_meta.insert(ticket_id, meta.clone());
        }
    }

    let claimed_count = id_to_meta
        .values()
        .filter(|meta| map_get_status(meta) == "claimed" && map_get_string(meta, "owner").unwrap_or_default() == owner)
        .count() as i32;
    if claimed_count >= max_claimed_per_owner {
        return Err(anyhow!(
            "owner {owner:?} already has {claimed_count} claimed tickets (max {max_claimed_per_owner})."
        ));
    }

    // Resolve --skill / --role profiles
    let mut extra_labels: Vec<String> = Vec::new();
    let mut type_filter: Option<BTreeSet<String>> = ticket_type
        .as_ref()
        .map(|t| std::iter::once(t.clone()).collect::<BTreeSet<_>>());

    if let Some(ref sk) = skill {
        match skill_pick_profiles(sk) {
            None => return Err(anyhow!("unknown --skill value {:?}", sk)),
            Some((lbs, types)) => {
                extra_labels.extend(lbs.iter().map(|l| l.to_string()));
                let type_set: BTreeSet<String> = types.iter().map(|t| t.to_string()).collect();
                type_filter = Some(match type_filter.take() {
                    None => type_set,
                    Some(existing) => {
                        let intersected: BTreeSet<_> = existing.intersection(&type_set).cloned().collect();
                        if intersected.is_empty() {
                            return Err(anyhow!("no compatible type filter remains after combining --type/--skill/--role"));
                        }
                        intersected
                    }
                });
            }
        }
    }

    if let Some(ref ro) = role {
        match role_pick_profiles(ro) {
            None => return Err(anyhow!("unknown --role value {:?}", ro)),
            Some((lbs, types)) => {
                extra_labels.extend(lbs.iter().map(|l| l.to_string()));
                let type_set: BTreeSet<String> = types.iter().map(|t| t.to_string()).collect();
                type_filter = Some(match type_filter.take() {
                    None => type_set,
                    Some(existing) => {
                        let intersected: BTreeSet<_> = existing.intersection(&type_set).cloned().collect();
                        if intersected.is_empty() {
                            return Err(anyhow!("no compatible type filter remains after combining --type/--skill/--role"));
                        }
                        intersected
                    }
                });
            }
        }
    }

    let combined_label: Vec<String> = label.iter().chain(extra_labels.iter()).cloned().collect();

    let mut candidates: Vec<(f64, String, String, PathBuf)> = Vec::new();
    for (path, meta) in &tickets {
        if map_get_status(meta) != "ready" {
            continue;
        }
        if let Some(ref wanted_priority) = priority {
            if map_get_string(meta, "priority").unwrap_or_default() != *wanted_priority {
                continue;
            }
        }
        if let Some(ref type_set) = type_filter {
            if !type_set.contains(&map_get_string(meta, "type").unwrap_or_default()) {
                continue;
            }
        }

        let labels = map_get_string_array(meta, "labels");
        let label_set = labels.iter().cloned().collect::<BTreeSet<_>>();
        if !combined_label.is_empty() && !combined_label.iter().all(|item| label_set.contains(item)) {
            continue;
        }
        if !avoid_label.is_empty() && avoid_label.iter().any(|item| label_set.contains(item)) {
            continue;
        }

        let (deps_ok, _) = deps_satisfied(meta, &id_to_meta);
        if !deps_ok && !ignore_deps {
            continue;
        }

        let score = compute_score(meta, &id_to_meta);
        let updated = map_get_string(meta, "updated").unwrap_or_default();
        let ticket_id = map_get_string(meta, "id").unwrap_or_default();
        candidates.push((score, updated, ticket_id, path.clone()));
    }

    if candidates.is_empty() {
        return Err(anyhow!("no claimable tickets found (ready + deps satisfied + filters)."));
    }

    candidates.sort_by(|left, right| {
        right
            .0
            .partial_cmp(&left.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| left.2.cmp(&right.2))
    });

    let (score, _updated, ticket_id, path) = candidates[0].clone();
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    map_set_string(&mut meta, "status", "claimed");
    map_set_string(&mut meta, "owner", &owner);
    let chosen_branch = if branch.trim().is_empty() {
        _default_branch(&meta)
    } else {
        branch.trim().to_string()
    };
    map_set_string(&mut meta, "branch", &chosen_branch);
    map_set_string(&mut meta, "updated", &today_str());
    meta.insert(
        Value::String("score".to_string()),
        Value::Number(serde_yaml::Number::from(score as i64)),
    );

    write_ticket(&path, &meta, &body)?;

    if as_json {
        println!(
            "{}",
            json!({
                "picked": ticket_id,
                "owner": owner,
                "branch": chosen_branch,
                "score": score,
            })
        );
    } else {
        println!(
            "picked {} (score {:.1}) -> claimed as {} (branch: {})",
            ticket_id, score, owner, chosen_branch
        );
    }

    Ok(0)
}

fn cmd_allocate_task(
    owner: String,
    label: Vec<String>,
    avoid_label: Vec<String>,
    priority: Option<String>,
    ticket_type: Option<String>,
    branch: String,
    ignore_deps: bool,
    max_claimed_per_owner: i32,
    lease_minutes: i64,
    skill: Option<String>,
    role: Option<String>,
    as_json: bool,
) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let mut tickets = Vec::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        let (mut meta, _body) = match read_ticket(&path) {
            Ok(value) => value,
            Err(_) => continue,
        };
        normalize_meta(&mut meta);
        tickets.push((path, meta));
    }

    let mut id_to_meta = BTreeMap::new();
    for (_path, meta) in &tickets {
        if let Some(ticket_id) = map_get_string(meta, "id") {
            id_to_meta.insert(ticket_id, meta.clone());
        }
    }

    let now = Utc::now();
    let claimed_count = id_to_meta
        .values()
        .filter(|meta| {
            map_get_status(meta) == "claimed"
                && map_get_string(meta, "owner").unwrap_or_default() == owner
                && !lease_expired(meta, now)
        })
        .count() as i32;
    if claimed_count >= max_claimed_per_owner {
        eprintln!(
            "owner {owner:?} already has {claimed_count} active leases (max {max_claimed_per_owner})."
        );
        return Ok(2);
    }

    // Resolve --skill / --role profiles
    let mut extra_labels: Vec<String> = Vec::new();
    let mut type_filter: Option<BTreeSet<String>> = ticket_type
        .as_ref()
        .map(|t| std::iter::once(t.clone()).collect::<BTreeSet<_>>());

    if let Some(ref sk) = skill {
        match skill_pick_profiles(sk) {
            None => {
                eprintln!("unknown --skill value {:?}", sk);
                return Ok(1);
            }
            Some((lbs, types)) => {
                extra_labels.extend(lbs.iter().map(|l| l.to_string()));
                let type_set: BTreeSet<String> = types.iter().map(|t| t.to_string()).collect();
                type_filter = Some(match type_filter.take() {
                    None => type_set,
                    Some(existing) => {
                        let intersected: BTreeSet<_> = existing.intersection(&type_set).cloned().collect();
                        if intersected.is_empty() {
                            eprintln!("no compatible type filter remains after combining --type/--skill/--role");
                            return Ok(2);
                        }
                        intersected
                    }
                });
            }
        }
    }

    if let Some(ref ro) = role {
        match role_pick_profiles(ro) {
            None => {
                eprintln!("unknown --role value {:?}", ro);
                return Ok(1);
            }
            Some((lbs, types)) => {
                extra_labels.extend(lbs.iter().map(|l| l.to_string()));
                let type_set: BTreeSet<String> = types.iter().map(|t| t.to_string()).collect();
                type_filter = Some(match type_filter.take() {
                    None => type_set,
                    Some(existing) => {
                        let intersected: BTreeSet<_> = existing.intersection(&type_set).cloned().collect();
                        if intersected.is_empty() {
                            eprintln!("no compatible type filter remains after combining --type/--skill/--role");
                            return Ok(2);
                        }
                        intersected
                    }
                });
            }
        }
    }

    let combined_label: Vec<String> = label.iter().chain(extra_labels.iter()).cloned().collect();

    let mut candidates: Vec<(f64, String, String, PathBuf)> = Vec::new();
    for (path, meta) in &tickets {
        let status = map_get_status(meta);
        if status == "ready" {
        } else if status == "claimed" {
            if !lease_expired(meta, now) {
                continue;
            }
        } else {
            continue;
        }

        if let Some(ref wanted_priority) = priority {
            if map_get_string(meta, "priority").unwrap_or_default() != *wanted_priority {
                continue;
            }
        }
        if let Some(ref type_set) = type_filter {
            if !type_set.contains(&map_get_string(meta, "type").unwrap_or_default()) {
                continue;
            }
        }

        let labels = map_get_string_array(meta, "labels");
        let label_set = labels.iter().cloned().collect::<BTreeSet<_>>();
        if !combined_label.is_empty() && !combined_label.iter().all(|item| label_set.contains(item)) {
            continue;
        }
        if !avoid_label.is_empty() && avoid_label.iter().any(|item| label_set.contains(item)) {
            continue;
        }

        let (deps_ok, _) = deps_satisfied(meta, &id_to_meta);
        if !deps_ok && !ignore_deps {
            continue;
        }

        let score = compute_score(meta, &id_to_meta);
        let updated = map_get_string(meta, "updated").unwrap_or_default();
        let ticket_id = map_get_string(meta, "id").unwrap_or_default();
        candidates.push((score, updated, ticket_id, path.clone()));
    }

    if candidates.is_empty() {
        eprintln!("no allocatable tickets found (ready or lease-expired claimed + deps satisfied + filters).");
        return Ok(3);
    }

    candidates.sort_by(|left, right| {
        right
            .0
            .partial_cmp(&left.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| left.2.cmp(&right.2))
    });

    let (score, _updated, ticket_id, path) = candidates[0].clone();
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    let previous_owner = map_get_string(&meta, "owner").unwrap_or_default();
    let previous_lease = map_get_string(&meta, "lease_expires_at").unwrap_or_default();
    let stale_reallocation = map_get_status(&meta) == "claimed" && lease_expired(&meta, now);

    let effective_lease_minutes = lease_minutes.max(1);
    let lease_until = now + chrono::Duration::minutes(effective_lease_minutes);

    map_set_string(&mut meta, "status", "claimed");
    map_set_string(&mut meta, "owner", &owner);
    map_set_string(&mut meta, "allocated_to", &owner);
    map_set_string(&mut meta, "allocated_at", &now_utc_iso());
    map_set_string(
        &mut meta,
        "lease_expires_at",
        &lease_until.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
    );
    map_set_string(&mut meta, "last_attempted_at", &now_utc_iso());
    map_set_string(&mut meta, "updated", &today_str());
    let chosen_branch = if branch.trim().is_empty() {
        _default_branch(&meta)
    } else {
        branch.trim().to_string()
    };
    map_set_string(&mut meta, "branch", &chosen_branch);
    meta.insert(
        Value::String("score".to_string()),
        Value::Number(serde_yaml::Number::from(score as i64)),
    );

    write_ticket(&path, &meta, &body)?;

    if stale_reallocation {
        append_incident(
            &repo,
            &format!(
                "stale-lease-reallocation id={} from_owner={} to_owner={} prior_lease_expires_at={}",
                ticket_id, previous_owner, owner, previous_lease
            ),
        )?;
    }

    if as_json {
        println!(
            "{}",
            json!({
                "ticket_id": ticket_id,
                "owner": owner,
                "branch": chosen_branch,
                "lease_expires_at": map_get_string(&meta, "lease_expires_at").unwrap_or_default(),
                "score": score,
            })
        );
    } else {
        println!("{}", ticket_id);
    }

    Ok(0)
}

fn cmd_fail_task(id: String, owner: String, error: String, retry_limit: Option<i64>, force: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let path = find_ticket_by_id(&repo, &id)?;
    let (mut meta, body) = read_ticket(&path)?;
    normalize_meta(&mut meta);

    let status = map_get_status(&meta);
    if status != "claimed" && !force {
        return Err(anyhow!(
            "Refusing to fail task: status is {:?} (expected 'claimed'). Use --force to override.",
            status
        ));
    }

    if !force {
        let current_owner = map_get_string(&meta, "allocated_to")
            .or_else(|| map_get_string(&meta, "owner"));
        if let Some(ref co) = current_owner {
            if co != &owner {
                return Err(anyhow!(
                    "Refusing to fail task: caller {:?} does not match current owner/allocated_to {:?}. Use --force to override.",
                    owner, co
                ));
            }
        }
    }

    let next_retry_count = map_get_i64(&meta, "retry_count").unwrap_or(0) + 1;
    let configured_retry_limit = retry_limit
        .or_else(|| map_get_i64(&meta, "retry_limit"))
        .unwrap_or(3)
        .max(1);

    meta.insert(
        Value::String("retry_count".to_string()),
        Value::Number(serde_yaml::Number::from(next_retry_count)),
    );
    meta.insert(
        Value::String("retry_limit".to_string()),
        Value::Number(serde_yaml::Number::from(configured_retry_limit)),
    );
    map_set_string(&mut meta, "last_error", error.trim());
    map_set_string(&mut meta, "last_attempted_at", &now_utc_iso());
    map_set_string(&mut meta, "updated", &today_str());

    if next_retry_count >= configured_retry_limit {
        map_set_string(&mut meta, "status", "blocked");
        map_set_optional_string(&mut meta, "owner", None);
        map_set_optional_string(&mut meta, "branch", None);
        map_set_optional_string(&mut meta, "allocated_to", None);
        map_set_optional_string(&mut meta, "allocated_at", None);
        map_set_optional_string(&mut meta, "lease_expires_at", None);

        write_ticket(&path, &meta, &body)?;

        let target_dir = errors_dir(&repo);
        fs::create_dir_all(&target_dir)?;
        let destination = target_dir.join(
            path.file_name()
                .ok_or_else(|| anyhow!("missing error-bucket filename"))?,
        );
        if destination.exists() {
            return Err(anyhow!(
                "Refusing to move to errors: destination already exists: {}",
                destination.display()
            ));
        }
        fs::rename(&path, &destination)?;
        append_incident(
            &repo,
            &format!(
                "retry-limit-exhausted id={} retries={} moved_to=tickets/errors",
                id, next_retry_count
            ),
        )?;
        println!(
            "{} exceeded retry_limit ({}) -> moved to tickets/errors/{}.md",
            id, configured_retry_limit, id
        );
        return Ok(0);
    }

    map_set_string(&mut meta, "status", "ready");
    map_set_optional_string(&mut meta, "owner", None);
    map_set_optional_string(&mut meta, "branch", None);
    map_set_optional_string(&mut meta, "allocated_to", None);
    map_set_optional_string(&mut meta, "allocated_at", None);
    map_set_optional_string(&mut meta, "lease_expires_at", None);

    let updated_body = append_progress_log(
        &body,
        &format!(
            "attempt failed (retry {}/{}): {}",
            next_retry_count,
            configured_retry_limit,
            error.trim()
        ),
    );
    write_ticket(&path, &meta, &updated_body)?;
    println!(
        "{} re-queued for retry ({}/{})",
        id, next_retry_count, configured_retry_limit
    );
    Ok(0)
}

fn cmd_graph(mermaid: bool, open_only: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let mut tickets = Vec::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        let (mut meta, _body) = match read_ticket(&path) {
            Ok(v) => v,
            Err(_) => continue,
        };
        normalize_meta(&mut meta);
        tickets.push(meta);
    }

    let mut edges: Vec<(String, String)> = Vec::new();
    for meta in tickets {
        if open_only && map_get_status(&meta) == "done" {
            continue;
        }
        let tid = map_get_string(&meta, "id").unwrap_or_default();
        for dep in map_get_string_array(&meta, "depends_on") {
            edges.push((dep, tid.clone()));
        }
    }

    if mermaid {
        println!("```mermaid");
        println!("graph TD");
        for (dep, tid) in edges {
            println!("  {dep} --> {tid}");
        }
        println!("```");
    } else {
        for (dep, tid) in edges {
            println!("{dep} -> {tid}");
        }
    }
    Ok(0)
}

fn cmd_export(format: String) -> Result<i32> {
    let format = format.to_lowercase();
    if format != "json" && format != "jsonl" {
        return Err(anyhow!("Unsupported format: {}", format));
    }

    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let mut rows = Vec::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        let (mut meta, body) = match read_ticket(&path) {
            Ok(v) => v,
            Err(_) => continue,
        };
        normalize_meta(&mut meta);
        let excerpt = body.lines().take(20).collect::<Vec<_>>().join("\n").trim().to_string();
        rows.push(json!({
            "id": map_get_string(&meta, "id"),
            "title": map_get_string(&meta, "title"),
            "status": map_get_string(&meta, "status"),
            "priority": map_get_string(&meta, "priority"),
            "type": map_get_string(&meta, "type"),
            "effort": map_get_string(&meta, "effort"),
            "labels": map_get_string_array(&meta, "labels"),
            "tags": map_get_string_array(&meta, "tags"),
            "owner": map_get_string(&meta, "owner"),
            "created": map_get_string(&meta, "created"),
            "updated": map_get_string(&meta, "updated"),
            "depends_on": map_get_string_array(&meta, "depends_on"),
            "branch": map_get_string(&meta, "branch"),
            "excerpt": excerpt,
            "path": path.strip_prefix(&repo).unwrap_or(&path).display().to_string(),
        }));
    }

    if format == "json" {
        println!("{}", serde_json::to_string_pretty(&rows)?);
    } else {
        for row in rows {
            println!("{}", serde_json::to_string(&row)?);
        }
    }
    Ok(0)
}

fn cmd_stats() -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);

    let mut by_status: BTreeMap<String, i32> = BTreeMap::new();
    let mut by_owner: BTreeMap<String, i32> = BTreeMap::new();

    for path in iter_ticket_files(&tickets_dir(&repo))? {
        let (mut meta, _body) = match read_ticket(&path) {
            Ok(v) => v,
            Err(_) => continue,
        };
        normalize_meta(&mut meta);
        let status = map_get_status(&meta);
        *by_status.entry(status.clone()).or_insert(0) += 1;
        if status == "claimed" {
            let owner = map_get_string(&meta, "owner").unwrap_or_else(|| "<unowned>".to_string());
            *by_owner.entry(owner).or_insert(0) += 1;
        }
    }

    println!("Status counts:");
    for status in DEFAULT_STATES {
        println!("  {:<12} {}", status, by_status.get(*status).copied().unwrap_or(0));
    }

    if !by_owner.is_empty() {
        println!("\nClaimed by owner:");
        let mut owners = by_owner.into_iter().collect::<Vec<_>>();
        owners.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
        for (owner, count) in owners {
            println!("  {:<20} {}", owner, count);
        }
    }

    Ok(0)
}

fn ticket_bucket(repo: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(repo).unwrap_or(path).display().to_string();
    if rel.starts_with("tickets/archived/") {
        "archived".to_string()
    } else if rel.starts_with("tickets/errors/") {
        "errors".to_string()
    } else if rel.starts_with("tickets/backlogs/") {
        "backlogs".to_string()
    } else if rel.starts_with("tickets/") {
        "tickets".to_string()
    } else {
        "other".to_string()
    }
}

fn cmd_report(db: String, summary: bool, search: String, limit: i32) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);

    let db_path = {
        let raw = PathBuf::from(&db);
        if raw.is_absolute() { raw } else { repo.join(raw) }
    };
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut rows: Vec<(Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, String, String, String, String, String, i32, String)> = Vec::new();
    let mut parse_errors: Vec<(String, String)> = Vec::new();

    for path in all_ticket_paths(&repo)? {
        let rel = path.strip_prefix(&repo).unwrap_or(&path).display().to_string();
        let ticket = read_ticket(&path);
        let (mut meta, body) = match ticket {
            Ok(v) => v,
            Err(err) => {
                parse_errors.push((rel, err.to_string()));
                continue;
            }
        };
        normalize_meta(&mut meta);
        let bucket = ticket_bucket(&repo, &path);
        let is_archived = if bucket == "archived" { 1 } else { 0 };

        rows.push((
            map_get_string(&meta, "id"),
            map_get_string(&meta, "title"),
            map_get_string(&meta, "status"),
            map_get_string(&meta, "priority"),
            map_get_string(&meta, "type"),
            map_get_string(&meta, "effort"),
            map_get_string(&meta, "owner"),
            map_get_string(&meta, "created"),
            map_get_string(&meta, "updated"),
            map_get_string(&meta, "branch"),
            serde_json::to_string(&map_get_string_array(&meta, "labels"))?,
            serde_json::to_string(&map_get_string_array(&meta, "tags"))?,
            serde_json::to_string(&map_get_string_array(&meta, "depends_on"))?,
            rel,
            bucket,
            is_archived,
            body,
        ));
    }

    let conn = Connection::open(&db_path)?;
    conn.execute("DROP TABLE IF EXISTS tickets", [])?;
    conn.execute("DROP TABLE IF EXISTS parse_errors", [])?;
    conn.execute(
        "CREATE TABLE tickets (
          id TEXT,
          title TEXT,
          status TEXT,
          priority TEXT,
          type TEXT,
          effort TEXT,
          owner TEXT,
          created TEXT,
          updated TEXT,
          branch TEXT,
          labels_json TEXT,
          tags_json TEXT,
          depends_on_json TEXT,
          path TEXT PRIMARY KEY,
          bucket TEXT,
          is_archived INTEGER,
          body TEXT
        )",
        [],
    )?;
    conn.execute(
        "CREATE TABLE parse_errors (
          path TEXT PRIMARY KEY,
          error TEXT
        )",
        [],
    )?;

    {
        let mut stmt = conn.prepare(
            "INSERT INTO tickets (
              id, title, status, priority, type, effort, owner, created, updated, branch,
              labels_json, tags_json, depends_on_json, path, bucket, is_archived, body
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
        )?;
        for row in rows {
            stmt.execute(params![
                row.0, row.1, row.2, row.3, row.4, row.5, row.6, row.7, row.8, row.9,
                row.10, row.11, row.12, row.13, row.14, row.15, row.16
            ])?;
        }
    }

    {
        let mut stmt = conn.prepare("INSERT INTO parse_errors (path, error) VALUES (?1, ?2)")?;
        for (path, error) in parse_errors.clone() {
            stmt.execute(params![path, error])?;
        }
    }

    conn.execute("CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tickets_priority ON tickets(priority)", [])?;
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tickets_owner ON tickets(owner)", [])?;

    println!("report db: {}", db_path.display());
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM tickets", [], |row| row.get(0))?;
    println!("indexed tickets: {}", count);
    if !parse_errors.is_empty() {
        println!("parse errors: {}", parse_errors.len());
    }

    if summary {
        println!("\nBy status:");
        {
            let mut stmt = conn.prepare(
                "SELECT COALESCE(status, '<none>'), COUNT(*) FROM tickets GROUP BY status ORDER BY COUNT(*) DESC",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let status: String = row.get(0)?;
                let c: i64 = row.get(1)?;
                println!("  {:<12} {}", status, c);
            }
        }

        println!("\nBy priority:");
        {
            let mut stmt = conn.prepare(
                "SELECT COALESCE(priority, '<none>'), COUNT(*) FROM tickets GROUP BY priority ORDER BY COUNT(*) DESC",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let priority: String = row.get(0)?;
                let c: i64 = row.get(1)?;
                println!("  {:<8} {}", priority, c);
            }
        }

        println!("\nCompleted by owner:");
        {
            let mut stmt = conn.prepare(
                "SELECT COALESCE(NULLIF(owner, ''), '<unowned>'), COUNT(*)
                 FROM tickets
                 WHERE status = 'done'
                 GROUP BY owner
                 ORDER BY COUNT(*) DESC",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let owner: String = row.get(0)?;
                let c: i64 = row.get(1)?;
                println!("  {:<20} {}", owner, c);
            }
        }
    }

    if !search.is_empty() {
        println!("\nSearch results for: '{}'", search);
        let q = format!("%{}%", search);
        let mut stmt = conn.prepare(
            "SELECT COALESCE(id, '<no-id>'), COALESCE(title, ''), COALESCE(status, ''),
                    COALESCE(owner, ''), path
             FROM tickets
             WHERE id LIKE ?1 OR title LIKE ?2 OR body LIKE ?3 OR labels_json LIKE ?4 OR tags_json LIKE ?5
             ORDER BY updated DESC, id ASC
             LIMIT ?6",
        )?;
        let mut rows = stmt.query(params![q, q, q, q, q, limit])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let title: String = row.get(1)?;
            let status: String = row.get(2)?;
            let owner: String = row.get(3)?;
            let path: String = row.get(4)?;
            println!("  {}  {:<12} {:<12} {}  ({})", id, status, owner, title, path);
        }
    }

    Ok(0)
}

fn cmd_version(as_json: bool) -> Result<i32> {
    let (major, minor, version) = root_version_components()?;
    let rustc_version = option_env!("MT_RUSTC_VERSION").unwrap_or("unknown");
    let cargo_version = option_env!("MT_CARGO_VERSION").unwrap_or("unknown");

    if as_json {
        println!(
            "{}",
            json!({
                "implementation": "rust-mt",
                "version": version,
                "version_major": major,
                "version_minor": minor,
                "build_tools": {
                    "rustc": rustc_version,
                    "cargo": cargo_version,
                }
            })
        );
    } else {
        println!("rust-mt {}", version);
        println!("rustc={}", rustc_version);
        println!("cargo={}", cargo_version);
    }

    Ok(0)
}

// ---------------------------------------------------------------------------
// Maintenance rules taxonomy and scanners
// ---------------------------------------------------------------------------

const MAINTENANCE_CATEGORIES: &[&str] = &[
    "security", "deps", "code-health", "performance", "database",
    "infrastructure", "observability", "testing", "docs",
];

struct MaintenanceRule {
    id: i32,
    title: &'static str,
    category: &'static str,
    detection: &'static str,
    action: &'static str,
    default_priority: &'static str,
    default_type: &'static str,
    default_effort: &'static str,
    labels: &'static [&'static str],
    external_tool: &'static str,
}

fn maintenance_rules() -> Vec<MaintenanceRule> {
    vec![
        // Category 1: Security (1-20)
        MaintenanceRule { id: 1, title: "CVE Dependency Vulnerability", category: "security", detection: "dependency version < secure version from CVE DB", action: "upgrade dependency and run tests", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "npm audit | pip-audit | cargo audit | osv-scanner | trivy | grype" },
        MaintenanceRule { id: 2, title: "Exposed Secrets in Repo", category: "security", detection: "regex patterns (AKIA..., private_key)", action: "remove secret and move to vault", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "" },
        MaintenanceRule { id: 3, title: "Expired SSL Certificate", category: "security", detection: "ssl_expiry_date < now + 14 days", action: "renew certificate", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "openssl s_client -connect host:443 | openssl x509 -noout -dates" },
        MaintenanceRule { id: 4, title: "Missing Security Headers", category: "security", detection: "missing CSP, X-Frame-Options, X-XSS-Protection", action: "add headers", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "curl -I <url> (check response headers for CSP, X-Frame-Options, X-XSS-Protection)" },
        MaintenanceRule { id: 5, title: "Insecure Hashing Algorithm", category: "security", detection: "md5 or sha1 usage", action: "migrate to argon2/bcrypt", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "grep -rn 'md5\\|sha1\\|MD5\\|SHA1' --include='*.py' --include='*.js' --include='*.go'" },
        MaintenanceRule { id: 6, title: "Hardcoded Password", category: "security", detection: "password=\"...\" pattern", action: "move to environment variable", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "" },
        MaintenanceRule { id: 7, title: "Open Debug Ports", category: "security", detection: "container exposing debug ports (9229, 3000)", action: "disable in production", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "docker inspect <container> | grep -i port; kubectl get svc -o json" },
        MaintenanceRule { id: 8, title: "Unauthenticated Admin Endpoint", category: "security", detection: "/admin route without auth middleware", action: "enforce auth guard", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "review route definitions for /admin paths without auth middleware" },
        MaintenanceRule { id: 9, title: "Excessive IAM Privileges", category: "security", detection: "policy contains \"*\"", action: "restrict permissions", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "aws iam list-policies --only-attached | grep '\"*\"'; gcloud iam policies" },
        MaintenanceRule { id: 10, title: "Unencrypted DB Connection", category: "security", detection: "connection string missing TLS flag", action: "enforce encrypted connections", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "grep -rn 'sslmode=disable\\|ssl=false\\|useSSL=false' (connection strings)" },
        MaintenanceRule { id: 11, title: "Weak JWT Secret", category: "security", detection: "JWT secret length < 32 characters or common value", action: "rotate to strong secret", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "grep -rn 'jwt.sign\\|JWT_SECRET\\|jwt_secret' and check secret length/entropy" },
        MaintenanceRule { id: 12, title: "Missing Rate Limiting", category: "security", detection: "API endpoints without rate limit middleware", action: "add rate limiting", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "review API framework middleware config for rate-limit setup" },
        MaintenanceRule { id: 13, title: "Disabled CSRF Protection", category: "security", detection: "CSRF middleware disabled or missing", action: "enable CSRF protection", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "review framework config for CSRF middleware (csrf_exempt, disable_csrf)" },
        MaintenanceRule { id: 14, title: "Dependency Signature Mismatch", category: "security", detection: "package checksum does not match registry", action: "verify and re-fetch dependency", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "npm audit signatures | pip hash --verify | cargo verify-project" },
        MaintenanceRule { id: 15, title: "Container Running as Root", category: "security", detection: "Dockerfile missing USER directive", action: "add non-root user", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "" },
        MaintenanceRule { id: 16, title: "Outdated OpenSSL", category: "security", detection: "OpenSSL version < latest stable", action: "upgrade OpenSSL", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "openssl version; dpkg -l openssl; brew info openssl" },
        MaintenanceRule { id: 17, title: "Public Cloud Bucket", category: "security", detection: "storage bucket with public access enabled", action: "restrict bucket access", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "aws s3api get-bucket-acl --bucket <name>; gsutil iam get gs://<bucket>" },
        MaintenanceRule { id: 18, title: "Exposed .env File", category: "security", detection: ".env file tracked in git or publicly accessible", action: "remove from tracking and add to .gitignore", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "" },
        MaintenanceRule { id: 19, title: "Missing MFA for Admin", category: "security", detection: "admin accounts without MFA enabled", action: "enforce MFA", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","security"], external_tool: "aws iam get-login-profile; review admin user MFA status in cloud console" },
        MaintenanceRule { id: 20, title: "Suspicious Login Activity", category: "security", detection: "unusual login patterns or locations", action: "investigate and rotate credentials", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","security"], external_tool: "review auth/access logs for unusual IPs, times, or geolocations" },
        // Category 2: Dependencies (21-40)
        MaintenanceRule { id: 21, title: "Outdated Dependency", category: "deps", detection: "npm/pip/cargo outdated", action: "upgrade version", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm outdated | pip list --outdated | cargo outdated | uv pip list --outdated" },
        MaintenanceRule { id: 22, title: "Deprecated Library", category: "deps", detection: "upstream marked deprecated", action: "migrate to replacement", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "npm info <pkg> deprecated; check PyPI/crates.io status page" },
        MaintenanceRule { id: 23, title: "Unmaintained Dependency", category: "deps", detection: "last commit > 3 years", action: "replace library", default_priority: "p1", default_type: "chore", default_effort: "l", labels: &["maintenance","deps"], external_tool: "check GitHub last commit date via API; npm info <pkg> time.modified" },
        MaintenanceRule { id: 24, title: "Duplicate Libraries", category: "deps", detection: "multiple versions installed", action: "consolidate version", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm ls --all | grep deduped; pip list | sort | uniq -d" },
        MaintenanceRule { id: 25, title: "Vulnerable Transitive Dependency", category: "deps", detection: "nested CVE scan", action: "update dependency tree", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "npm audit | pip-audit | cargo audit | osv-scanner (transitive deps)" },
        MaintenanceRule { id: 26, title: "Lockfile Drift", category: "deps", detection: "mismatch with installed packages", action: "rebuild lockfile", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm ci --dry-run; pip freeze > /tmp/freeze.txt && diff requirements.txt /tmp/freeze.txt" },
        MaintenanceRule { id: 27, title: "Outdated Build Toolchain", category: "deps", detection: "compiler older than LTS", action: "upgrade toolchain", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "rustc --version; python3 --version; node --version; go version; zig version" },
        MaintenanceRule { id: 28, title: "Runtime EOL", category: "deps", detection: "runtime end-of-life version", action: "upgrade runtime", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "check endoflife.date API for runtime EOL dates (python, node, ruby, etc.)" },
        MaintenanceRule { id: 29, title: "Dependency Size Explosion", category: "deps", detection: "bundle size threshold exceeded", action: "audit dependency", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "npm pack --dry-run; du -sh node_modules; cargo bloat" },
        MaintenanceRule { id: 30, title: "Unused Dependency", category: "deps", detection: "static import analysis", action: "remove package", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "depcheck (npm) | vulture (python) | cargo-udeps (rust)" },
        MaintenanceRule { id: 31, title: "License Change Detection", category: "deps", detection: "dependency license changed in new version", action: "review license compatibility", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "license-checker (npm) | pip-licenses | cargo-license; diff against previous" },
        MaintenanceRule { id: 32, title: "Conflicting Version Ranges", category: "deps", detection: "dependency resolution conflicts", action: "resolve version conflicts", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "npm ls --all 2>&1 | grep 'ERESOLVE\\|peer dep'; pip check" },
        MaintenanceRule { id: 33, title: "Unused Peer Dependencies", category: "deps", detection: "peer dependency declared but unused", action: "remove peer dependency", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm ls --all | grep 'peer dep'" },
        MaintenanceRule { id: 34, title: "Broken Registry References", category: "deps", detection: "package registry URL unreachable", action: "fix registry reference", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm ping; pip config list (check index-url reachability)" },
        MaintenanceRule { id: 35, title: "Checksum Mismatch", category: "deps", detection: "package checksum mismatch on install", action: "re-fetch and verify package", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm cache verify; pip hash --verify; cargo verify-project" },
        MaintenanceRule { id: 36, title: "Incompatible Binary Architecture", category: "deps", detection: "native module built for wrong arch", action: "rebuild for target architecture", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "file node_modules/**/*.node; check platform/arch in native bindings" },
        MaintenanceRule { id: 37, title: "Outdated WASM Runtime", category: "deps", detection: "WASM runtime version behind stable", action: "upgrade WASM runtime", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "check wasmtime/wasmer version against latest stable release" },
        MaintenanceRule { id: 38, title: "Outdated GPU Drivers", category: "deps", detection: "GPU driver version behind stable", action: "upgrade GPU drivers", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","deps"], external_tool: "nvidia-smi; check driver version against CUDA compatibility matrix" },
        MaintenanceRule { id: 39, title: "Mirror Outage Fallback", category: "deps", detection: "primary package mirror unreachable", action: "configure fallback mirror", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm ping --registry <mirror>; pip install --dry-run -i <mirror>" },
        MaintenanceRule { id: 40, title: "Corrupted Dependency Cache", category: "deps", detection: "dependency cache integrity check fails", action: "clear and rebuild cache", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","deps"], external_tool: "npm cache clean --force; pip cache purge; cargo clean" },
        // Category 3: Code Health (41-60)
        MaintenanceRule { id: 41, title: "High Cyclomatic Complexity", category: "code-health", detection: "cyclomatic complexity > 15", action: "refactor into smaller functions", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "radon cc -a (python) | eslint --rule complexity (js) | gocyclo (go)" },
        MaintenanceRule { id: 42, title: "File Too Large", category: "code-health", detection: "file > 1000 lines", action: "split into modules", default_priority: "p2", default_type: "refactor", default_effort: "l", labels: &["maintenance","code-health"], external_tool: "" },
        MaintenanceRule { id: 43, title: "Duplicate Code Blocks", category: "code-health", detection: "repeated code blocks detected", action: "extract shared function", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "jscpd | flay (ruby) | PMD CPD (java); semgrep --config=p/duplicate-code" },
        MaintenanceRule { id: 44, title: "Dead Code Detection", category: "code-health", detection: "unreachable or unused code paths", action: "remove dead code", default_priority: "p2", default_type: "refactor", default_effort: "s", labels: &["maintenance","code-health"], external_tool: "vulture (python) | ts-prune (typescript) | deadcode (go)" },
        MaintenanceRule { id: 45, title: "Deprecated API Usage", category: "code-health", detection: "calls to deprecated functions/methods", action: "migrate to replacement API", default_priority: "p1", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "grep -rn '@deprecated\\|DeprecationWarning\\|DEPRECATED'" },
        MaintenanceRule { id: 46, title: "Missing Error Handling", category: "code-health", detection: "unhandled exceptions or missing error checks", action: "add error handling", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "pylint --disable=all --enable=W0702,W0703 | eslint no-empty-catch" },
        MaintenanceRule { id: 47, title: "Logging Inconsistency", category: "code-health", detection: "inconsistent log levels or formats", action: "standardize logging", default_priority: "p2", default_type: "refactor", default_effort: "s", labels: &["maintenance","code-health"], external_tool: "grep -rn 'console.log\\|print(\\|log.Debug' and review log level consistency" },
        MaintenanceRule { id: 48, title: "Excessive TODO Comments", category: "code-health", detection: "TODO/FIXME/HACK count exceeds threshold", action: "address or create tickets for TODOs", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "" },
        MaintenanceRule { id: 49, title: "Long Parameter Lists", category: "code-health", detection: "function parameters > 6", action: "refactor to use parameter objects", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "pylint --disable=all --enable=R0913 | eslint max-params" },
        MaintenanceRule { id: 50, title: "Circular Imports", category: "code-health", detection: "circular import dependency detected", action: "restructure module dependencies", default_priority: "p1", default_type: "refactor", default_effort: "l", labels: &["maintenance","code-health"], external_tool: "python -c 'import importlib; importlib.import_module(\"pkg\")' | madge --circular (js)" },
        MaintenanceRule { id: 51, title: "Missing Type Hints", category: "code-health", detection: "functions without type annotations", action: "add type hints", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "mypy --strict | pyright; check function signatures for missing annotations" },
        MaintenanceRule { id: 52, title: "Unused Imports", category: "code-health", detection: "imported modules never referenced", action: "remove unused imports", default_priority: "p2", default_type: "refactor", default_effort: "xs", labels: &["maintenance","code-health"], external_tool: "autoflake --check (python) | eslint no-unused-vars (js)" },
        MaintenanceRule { id: 53, title: "Inconsistent Formatting", category: "code-health", detection: "code style deviates from project standard", action: "run formatter", default_priority: "p2", default_type: "chore", default_effort: "xs", labels: &["maintenance","code-health"], external_tool: "black --check (python) | prettier --check (js) | rustfmt --check (rust)" },
        MaintenanceRule { id: 54, title: "Poor Naming Patterns", category: "code-health", detection: "variable/function names unclear or inconsistent", action: "rename for clarity", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "pylint naming-convention | eslint camelcase/naming-convention" },
        MaintenanceRule { id: 55, title: "Missing Docstrings", category: "code-health", detection: "public functions without documentation", action: "add docstrings", default_priority: "p2", default_type: "docs", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "pydocstyle | darglint | interrogate (python)" },
        MaintenanceRule { id: 56, title: "Nested Loops", category: "code-health", detection: "deeply nested loops (> 3 levels)", action: "refactor to reduce nesting", default_priority: "p2", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "review code for nested for/while loops > 3 levels deep" },
        MaintenanceRule { id: 57, title: "Unsafe Pointer Operations", category: "code-health", detection: "raw pointer usage without safety checks", action: "add bounds checking or use safe alternatives", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "clippy (rust) | cppcheck (c/c++) | review unsafe blocks" },
        MaintenanceRule { id: 58, title: "Unbounded Recursion", category: "code-health", detection: "recursive function without base case limit", action: "add recursion depth limit", default_priority: "p1", default_type: "code", default_effort: "s", labels: &["maintenance","code-health"], external_tool: "review recursive functions for missing base case or depth limit" },
        MaintenanceRule { id: 59, title: "Magic Numbers", category: "code-health", detection: "unexplained numeric literals in code", action: "extract to named constants", default_priority: "p2", default_type: "refactor", default_effort: "s", labels: &["maintenance","code-health"], external_tool: "pylint --disable=all --enable=W0612 | eslint no-magic-numbers" },
        MaintenanceRule { id: 60, title: "Mutable Global State", category: "code-health", detection: "global variables modified at runtime", action: "refactor to local/injected state", default_priority: "p1", default_type: "refactor", default_effort: "m", labels: &["maintenance","code-health"], external_tool: "grep -rn 'global ' (python) | review mutable module-level state" },
        // Category 4: Performance (61-80)
        MaintenanceRule { id: 61, title: "Slow Database Query", category: "performance", detection: "query execution > 500ms", action: "optimize query or add index", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "EXPLAIN ANALYZE <query>; pg_stat_statements; slow query log" },
        MaintenanceRule { id: 62, title: "N+1 Query Pattern", category: "performance", detection: "repeated queries in loop", action: "batch or join queries", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "django-debug-toolbar | bullet gem (rails) | review ORM queries in loops" },
        MaintenanceRule { id: 63, title: "Memory Leak Detection", category: "performance", detection: "heap growth without release", action: "fix memory leak", default_priority: "p0", default_type: "code", default_effort: "l", labels: &["maintenance","performance"], external_tool: "valgrind --leak-check=full | heaptrack | node --inspect + Chrome DevTools" },
        MaintenanceRule { id: 64, title: "High API Latency", category: "performance", detection: "p95 latency exceeds threshold", action: "profile and optimize endpoint", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "check APM dashboards (Datadog, New Relic, Grafana) for p95 latency" },
        MaintenanceRule { id: 65, title: "Cache Miss Ratio", category: "performance", detection: "cache miss ratio > 0.6", action: "tune cache strategy", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "redis-cli INFO stats | memcached stats; check cache hit/miss metrics" },
        MaintenanceRule { id: 66, title: "Large Response Payloads", category: "performance", detection: "API response size exceeds threshold", action: "add pagination or compression", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "curl -s <api> | wc -c; check API response sizes in APM" },
        MaintenanceRule { id: 67, title: "O(n^2) Algorithms", category: "performance", detection: "quadratic complexity in hot paths", action: "replace with efficient algorithm", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "review hot-path code for nested loops; profile with py-spy/perf/flamegraph" },
        MaintenanceRule { id: 68, title: "Unbounded Job Queue", category: "performance", detection: "job queue grows without limit", action: "add backpressure or queue limits", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "check job queue metrics (Sidekiq, Celery, Bull) for queue depth trends" },
        MaintenanceRule { id: 69, title: "Excessive Logging Overhead", category: "performance", detection: "high-frequency logging in hot paths", action: "reduce log verbosity or sample", default_priority: "p2", default_type: "code", default_effort: "s", labels: &["maintenance","performance"], external_tool: "review logging in hot paths; check log volume metrics" },
        MaintenanceRule { id: 70, title: "Slow Cold Start", category: "performance", detection: "service startup > threshold", action: "optimize initialization", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "time service startup; profile with py-spy/perf during init" },
        MaintenanceRule { id: 71, title: "Thread Starvation", category: "performance", detection: "thread pool exhaustion detected", action: "increase pool size or reduce blocking", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "jstack (java) | py-spy dump | review thread pool configs" },
        MaintenanceRule { id: 72, title: "Lock Contention", category: "performance", detection: "high lock wait times", action: "reduce critical section scope", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "lock contention profiling; review mutex/lock usage in hot paths" },
        MaintenanceRule { id: 73, title: "Blocking IO in Async Code", category: "performance", detection: "synchronous IO in async context", action: "convert to async IO", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "review async code for sync IO calls (requests, open, subprocess)" },
        MaintenanceRule { id: 74, title: "Oversized Images", category: "performance", detection: "image assets exceed size threshold", action: "compress or resize images", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","performance"], external_tool: "find . -name '*.png' -o -name '*.jpg' | xargs identify -format '%f %wx%h %b\\n'" },
        MaintenanceRule { id: 75, title: "Redundant Network Calls", category: "performance", detection: "duplicate API calls for same data", action: "deduplicate or cache results", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "review network calls in code; check for duplicate HTTP requests in APM" },
        MaintenanceRule { id: 76, title: "Inefficient Serialization", category: "performance", detection: "slow serialization format in hot path", action: "switch to efficient format", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "benchmark serialization (json vs msgpack vs protobuf) in hot paths" },
        MaintenanceRule { id: 77, title: "Slow WASM Execution Path", category: "performance", detection: "WASM module performance below threshold", action: "profile and optimize WASM code", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "wasm profiling tools; review WASM module execution times" },
        MaintenanceRule { id: 78, title: "GPU Underutilization", category: "performance", detection: "GPU compute usage below capacity", action: "optimize GPU workload distribution", default_priority: "p2", default_type: "code", default_effort: "l", labels: &["maintenance","performance"], external_tool: "nvidia-smi dmon; review GPU utilization metrics" },
        MaintenanceRule { id: 79, title: "Excessive Disk Writes", category: "performance", detection: "write IOPS exceeds threshold", action: "batch or buffer writes", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "iostat; check write IOPS metrics; review fsync/flush patterns" },
        MaintenanceRule { id: 80, title: "Poor Pagination", category: "performance", detection: "unbounded result sets returned", action: "implement cursor-based pagination", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","performance"], external_tool: "review API endpoints for unbounded SELECT/find queries without LIMIT" },
        // Category 5: Database (81-100)
        MaintenanceRule { id: 81, title: "Missing Index", category: "database", detection: "frequent query without supporting index", action: "add database index", default_priority: "p1", default_type: "code", default_effort: "s", labels: &["maintenance","database"], external_tool: "EXPLAIN ANALYZE <query>; pg_stat_user_tables (seq_scan count); slow query log" },
        MaintenanceRule { id: 82, title: "Unused Index", category: "database", detection: "index with zero reads", action: "drop unused index", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","database"], external_tool: "pg_stat_user_indexes (idx_scan = 0); MySQL sys.schema_unused_indexes" },
        MaintenanceRule { id: 83, title: "Table Bloat", category: "database", detection: "dead tuple ratio exceeds threshold", action: "vacuum or repack table", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","database"], external_tool: "pg_stat_user_tables (n_dead_tup); VACUUM VERBOSE" },
        MaintenanceRule { id: 84, title: "Fragmented Index", category: "database", detection: "index fragmentation > threshold", action: "rebuild index", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","database"], external_tool: "pg_stat_user_indexes; DBCC SHOWCONTIG (SQL Server); OPTIMIZE TABLE (MySQL)" },
        MaintenanceRule { id: 85, title: "Orphan Records", category: "database", detection: "records referencing deleted parents", action: "clean up orphan records", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "SELECT orphans with LEFT JOIN ... WHERE parent.id IS NULL" },
        MaintenanceRule { id: 86, title: "Duplicate Rows", category: "database", detection: "duplicate records detected", action: "deduplicate data", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "SELECT columns, COUNT(*) GROUP BY columns HAVING COUNT(*) > 1" },
        MaintenanceRule { id: 87, title: "Data Format Drift", category: "database", detection: "column data deviates from expected format", action: "normalize data format", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "sample column data and check format consistency; pg_typeof()" },
        MaintenanceRule { id: 88, title: "Backup Failure", category: "database", detection: "last backup older than policy threshold", action: "investigate and fix backup", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "pg_stat_archiver; check backup tool logs (pg_dump, mysqldump, mongodump)" },
        MaintenanceRule { id: 89, title: "Failed Migration", category: "database", detection: "migration in failed/partial state", action: "fix and rerun migration", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "check migration status table; rails db:migrate:status | alembic current" },
        MaintenanceRule { id: 90, title: "Slow Join Queries", category: "database", detection: "join query exceeding time threshold", action: "optimize join or denormalize", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","database"], external_tool: "EXPLAIN ANALYZE for JOIN queries; check pg_stat_statements for slow joins" },
        MaintenanceRule { id: 91, title: "Oversized JSON Columns", category: "database", detection: "JSON column average size exceeds threshold", action: "normalize into relational columns", default_priority: "p2", default_type: "refactor", default_effort: "l", labels: &["maintenance","database"], external_tool: "SELECT avg(pg_column_size(json_col)) FROM table; check JSON column sizes" },
        MaintenanceRule { id: 92, title: "Unused Tables", category: "database", detection: "tables with no recent reads or writes", action: "archive or drop unused tables", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","database"], external_tool: "pg_stat_user_tables (last_autovacuum, seq_scan, idx_scan for zero-activity tables)" },
        MaintenanceRule { id: 93, title: "Table Scan Alerts", category: "database", detection: "full table scan on large table", action: "add index or optimize query", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","database"], external_tool: "pg_stat_user_tables (seq_scan on large tables); MySQL slow query log" },
        MaintenanceRule { id: 94, title: "Encoding Mismatch", category: "database", detection: "mixed character encodings across tables", action: "standardize encoding", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "SELECT table_name, character_set_name FROM information_schema.columns" },
        MaintenanceRule { id: 95, title: "Unbounded Table Growth", category: "database", detection: "table row count growing without retention policy", action: "implement retention or archival", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC" },
        MaintenanceRule { id: 96, title: "Missing Partitioning", category: "database", detection: "large table without partitioning scheme", action: "add table partitioning", default_priority: "p2", default_type: "chore", default_effort: "l", labels: &["maintenance","database"], external_tool: "check table sizes; review partitioning strategy for tables > 10M rows" },
        MaintenanceRule { id: 97, title: "Outdated Statistics", category: "database", detection: "query planner statistics stale", action: "analyze/update statistics", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","database"], external_tool: "pg_stat_user_tables (last_analyze); ANALYZE VERBOSE" },
        MaintenanceRule { id: 98, title: "Corrupted Index Pages", category: "database", detection: "index corruption detected", action: "rebuild corrupted index", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "pg_catalog.pg_index (indisvalid = false); REINDEX" },
        MaintenanceRule { id: 99, title: "Replication Lag", category: "database", detection: "replica behind primary by threshold", action: "investigate replication lag", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "SELECT * FROM pg_stat_replication; check replica lag metrics" },
        MaintenanceRule { id: 100, title: "Foreign Key Inconsistencies", category: "database", detection: "orphaned foreign key references", action: "fix referential integrity", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","database"], external_tool: "check foreign key constraints; SELECT with LEFT JOIN for orphaned references" },
        // Category 6: Infrastructure (101-120)
        MaintenanceRule { id: 101, title: "Container Image Outdated", category: "infrastructure", detection: "base image version behind latest", action: "update container base image", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "docker pull <image>:latest --dry-run; compare Dockerfile FROM tag to latest" },
        MaintenanceRule { id: 102, title: "Missing OS Security Patches", category: "infrastructure", detection: "OS packages with available security updates", action: "apply security patches", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "apt list --upgradable | yum check-update | apk version -l '<'" },
        MaintenanceRule { id: 103, title: "Low Disk Space", category: "infrastructure", detection: "disk usage > 85%", action: "clean up or expand storage", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "df -h; kubectl top nodes; cloud console storage metrics" },
        MaintenanceRule { id: 104, title: "CPU Saturation", category: "infrastructure", detection: "sustained CPU usage > 90%", action: "scale or optimize workload", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "top; kubectl top pods; cloud monitoring CPU metrics" },
        MaintenanceRule { id: 105, title: "Memory Pressure", category: "infrastructure", detection: "memory usage > 90% or OOM events", action: "investigate memory usage and scale", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "free -h; kubectl top pods; check OOM events in dmesg/journal" },
        MaintenanceRule { id: 106, title: "CrashLoop Pods", category: "infrastructure", detection: "pod in CrashLoopBackOff state", action: "diagnose and fix crash loop", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "kubectl get pods --field-selector=status.phase!=Running; kubectl describe pod" },
        MaintenanceRule { id: 107, title: "Orphan Containers", category: "infrastructure", detection: "stopped containers consuming resources", action: "remove orphan containers", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "docker ps -a --filter status=exited; docker system df" },
        MaintenanceRule { id: 108, title: "Stale Storage Volumes", category: "infrastructure", detection: "unattached volumes with no recent access", action: "clean up stale volumes", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "kubectl get pv --no-headers | grep Available; aws ec2 describe-volumes --filters Name=status,Values=available" },
        MaintenanceRule { id: 109, title: "Expired DNS Records", category: "infrastructure", detection: "DNS records pointing to decommissioned resources", action: "update DNS records", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "dig <hostname>; nslookup; check DNS records against active infrastructure" },
        MaintenanceRule { id: 110, title: "Misconfigured Load Balancer", category: "infrastructure", detection: "health check failures or routing errors", action: "fix load balancer configuration", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "kubectl describe ingress; aws elb describe-target-health; health check logs" },
        MaintenanceRule { id: 111, title: "High Network Latency", category: "infrastructure", detection: "inter-service latency exceeds threshold", action: "investigate network path", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "ping; traceroute; mtr; check network latency metrics in monitoring" },
        MaintenanceRule { id: 112, title: "Unused Cloud Resources", category: "infrastructure", detection: "idle VMs, IPs, or load balancers", action: "decommission unused resources", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped; cloud cost reports" },
        MaintenanceRule { id: 113, title: "Broken CI Runners", category: "infrastructure", detection: "CI runner offline or failing jobs", action: "repair or replace CI runner", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "check CI dashboard for offline runners; gitlab-runner verify; gh api /repos/{owner}/{repo}/actions/runners" },
        MaintenanceRule { id: 114, title: "Container Restart Loops", category: "infrastructure", detection: "container restart count exceeds threshold", action: "diagnose restart cause", default_priority: "p0", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "docker inspect --format='{{.RestartCount}}'; kubectl describe pod (restart count)" },
        MaintenanceRule { id: 115, title: "Unused Security Groups", category: "infrastructure", detection: "security groups not attached to resources", action: "remove unused security groups", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "aws ec2 describe-security-groups; check for unattached security groups" },
        MaintenanceRule { id: 116, title: "Expired API Gateway Cert", category: "infrastructure", detection: "API gateway certificate expiring soon", action: "renew API gateway certificate", default_priority: "p0", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "aws apigateway get-domain-names; check certificate expiry dates" },
        MaintenanceRule { id: 117, title: "Infrastructure Drift", category: "infrastructure", detection: "live config differs from IaC definitions", action: "reconcile infrastructure state", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "terraform plan | pulumi preview | compare live state vs IaC definitions" },
        MaintenanceRule { id: 118, title: "Registry Cleanup Required", category: "infrastructure", detection: "container registry storage exceeds threshold", action: "prune old images from registry", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "docker system df; cloud registry storage metrics; skopeo list-tags" },
        MaintenanceRule { id: 119, title: "Log Storage Overflow", category: "infrastructure", detection: "log volume approaching storage limit", action: "rotate or archive logs", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","infrastructure"], external_tool: "du -sh /var/log; check log rotation config; cloud logging storage metrics" },
        MaintenanceRule { id: 120, title: "Node Version Drift", category: "infrastructure", detection: "cluster nodes running different versions", action: "align node versions", default_priority: "p1", default_type: "chore", default_effort: "m", labels: &["maintenance","infrastructure"], external_tool: "kubectl get nodes -o wide; compare node versions across cluster" },
        // Category 7: Observability (121-130)
        MaintenanceRule { id: 121, title: "Missing Metrics", category: "observability", detection: "service endpoints without metrics instrumentation", action: "add metrics collection", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","observability"], external_tool: "review service endpoints for metrics instrumentation; check Prometheus targets" },
        MaintenanceRule { id: 122, title: "Broken Alerts", category: "observability", detection: "alert rules referencing missing metrics", action: "fix alert configuration", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","observability"], external_tool: "promtool check rules; review alert rule YAML for missing metric references" },
        MaintenanceRule { id: 123, title: "Missing Distributed Tracing", category: "observability", detection: "services without trace propagation", action: "add trace instrumentation", default_priority: "p1", default_type: "code", default_effort: "m", labels: &["maintenance","observability"], external_tool: "review code for trace context propagation (OpenTelemetry, Jaeger, Zipkin)" },
        MaintenanceRule { id: 124, title: "Log Retention Overflow", category: "observability", detection: "log retention exceeding storage policy", action: "adjust retention policy", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","observability"], external_tool: "check log retention policies; du -sh log storage; cloud logging config" },
        MaintenanceRule { id: 125, title: "Missing Uptime Checks", category: "observability", detection: "production endpoints without health monitoring", action: "add uptime checks", default_priority: "p1", default_type: "chore", default_effort: "s", labels: &["maintenance","observability"], external_tool: "review uptime monitoring config (Pingdom, UptimeRobot, cloud health checks)" },
        MaintenanceRule { id: 126, title: "Alert Fatigue Detection", category: "observability", detection: "high volume of non-actionable alerts", action: "tune alert thresholds", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","observability"], external_tool: "review alert history for frequency; check PagerDuty/Opsgenie alert volume" },
        MaintenanceRule { id: 127, title: "Missing Error Classification", category: "observability", detection: "errors logged without categorization", action: "add error classification", default_priority: "p2", default_type: "code", default_effort: "m", labels: &["maintenance","observability"], external_tool: "review error logging for categorization (error codes, error types)" },
        MaintenanceRule { id: 128, title: "Inconsistent Log Schema", category: "observability", detection: "log format varies across services", action: "standardize log schema", default_priority: "p2", default_type: "chore", default_effort: "m", labels: &["maintenance","observability"], external_tool: "compare log formats across services; check structured logging config" },
        MaintenanceRule { id: 129, title: "Missing Service Map", category: "observability", detection: "no service dependency map available", action: "generate service map", default_priority: "p2", default_type: "docs", default_effort: "m", labels: &["maintenance","observability"], external_tool: "review service dependencies; generate from traces or config (Kiali, Jaeger)" },
        MaintenanceRule { id: 130, title: "Outdated Dashboards", category: "observability", detection: "dashboards referencing deprecated metrics", action: "update dashboards", default_priority: "p2", default_type: "chore", default_effort: "s", labels: &["maintenance","observability"], external_tool: "review Grafana/Datadog dashboards for deprecated metric references" },
        // Category 8: Testing (131-140)
        MaintenanceRule { id: 131, title: "Failing Tests", category: "testing", detection: "test suite has persistent failures", action: "fix failing tests", default_priority: "p0", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "run test suite and check exit code; review CI pipeline history for failures" },
        MaintenanceRule { id: 132, title: "Flaky Tests", category: "testing", detection: "tests with intermittent pass/fail", action: "stabilize flaky tests", default_priority: "p1", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "run tests multiple times; check CI history for intermittent failures" },
        MaintenanceRule { id: 133, title: "Missing Regression Tests", category: "testing", detection: "recent bug fixes without regression tests", action: "add regression tests", default_priority: "p1", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "review recent bug-fix commits for associated test additions" },
        MaintenanceRule { id: 134, title: "Low Coverage Modules", category: "testing", detection: "modules below coverage threshold", action: "add tests for low coverage areas", default_priority: "p2", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "coverage run -m pytest; nyc; go test -cover; review coverage report" },
        MaintenanceRule { id: 135, title: "Outdated Snapshot Tests", category: "testing", detection: "snapshot tests not updated after code changes", action: "update snapshot tests", default_priority: "p2", default_type: "tests", default_effort: "s", labels: &["maintenance","testing"], external_tool: "jest --updateSnapshot --dry-run; check snapshot diff against code changes" },
        MaintenanceRule { id: 136, title: "Slow Test Suite", category: "testing", detection: "test suite execution exceeds threshold", action: "optimize slow tests", default_priority: "p2", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "time test suite execution; pytest --durations=10; jest --verbose" },
        MaintenanceRule { id: 137, title: "Missing Integration Tests", category: "testing", detection: "critical paths without integration test coverage", action: "add integration tests", default_priority: "p1", default_type: "tests", default_effort: "l", labels: &["maintenance","testing"], external_tool: "review critical user paths for integration test coverage" },
        MaintenanceRule { id: 138, title: "Broken CI Pipeline", category: "testing", detection: "CI pipeline failing on main branch", action: "fix CI pipeline", default_priority: "p0", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "check CI pipeline status on main branch; review recent CI logs" },
        MaintenanceRule { id: 139, title: "Missing Edge Case Tests", category: "testing", detection: "boundary conditions untested", action: "add edge case tests", default_priority: "p2", default_type: "tests", default_effort: "m", labels: &["maintenance","testing"], external_tool: "review test cases for boundary values, null inputs, empty collections" },
        MaintenanceRule { id: 140, title: "Inconsistent Test Data", category: "testing", detection: "test fixtures with hardcoded or stale data", action: "standardize test data", default_priority: "p2", default_type: "tests", default_effort: "s", labels: &["maintenance","testing"], external_tool: "review test fixtures for hardcoded dates, IDs, or stale data" },
        // Category 9: Documentation (141-150)
        MaintenanceRule { id: 141, title: "Outdated API Docs", category: "docs", detection: "API documentation does not match implementation", action: "update API documentation", default_priority: "p1", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "diff API implementation against API docs; check OpenAPI spec freshness" },
        MaintenanceRule { id: 142, title: "Broken Documentation Links", category: "docs", detection: "dead links in documentation", action: "fix broken links", default_priority: "p2", default_type: "docs", default_effort: "s", labels: &["maintenance","docs"], external_tool: "" },
        MaintenanceRule { id: 143, title: "Outdated Onboarding Docs", category: "docs", detection: "onboarding guide references removed features", action: "update onboarding documentation", default_priority: "p1", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "review onboarding docs against current setup/install process" },
        MaintenanceRule { id: 144, title: "Missing Architecture Diagram", category: "docs", detection: "no architecture diagram or diagram is outdated", action: "create or update architecture diagram", default_priority: "p2", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "check for architecture diagrams in docs/; compare against current system" },
        MaintenanceRule { id: 145, title: "Missing CLI Examples", category: "docs", detection: "CLI commands without usage examples", action: "add CLI usage examples", default_priority: "p2", default_type: "docs", default_effort: "s", labels: &["maintenance","docs"], external_tool: "review CLI --help output against documentation examples" },
        MaintenanceRule { id: 146, title: "Outdated Deployment Guide", category: "docs", detection: "deployment guide does not match current process", action: "update deployment guide", default_priority: "p1", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "compare deployment docs against current deploy scripts/CI config" },
        MaintenanceRule { id: 147, title: "Undocumented Endpoints", category: "docs", detection: "API endpoints without documentation", action: "document undocumented endpoints", default_priority: "p1", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "list API routes and compare against documented endpoints" },
        MaintenanceRule { id: 148, title: "Stale README", category: "docs", detection: "README last updated significantly before repo activity", action: "update README", default_priority: "p2", default_type: "docs", default_effort: "s", labels: &["maintenance","docs"], external_tool: "" },
        MaintenanceRule { id: 149, title: "Outdated SDK Docs", category: "docs", detection: "SDK documentation does not match current API", action: "update SDK documentation", default_priority: "p1", default_type: "docs", default_effort: "m", labels: &["maintenance","docs"], external_tool: "diff SDK methods against API documentation; check SDK version alignment" },
        MaintenanceRule { id: 150, title: "Missing Changelog", category: "docs", detection: "no changelog or changelog not updated for recent releases", action: "update changelog", default_priority: "p2", default_type: "docs", default_effort: "s", labels: &["maintenance","docs"], external_tool: "check CHANGELOG.md last entry date vs latest release tag" },
    ]
}

// Scanner IDs that have built-in scanners
fn has_builtin_scanner(rule_id: i32) -> bool {
    matches!(rule_id, 2 | 6 | 15 | 18 | 42 | 48 | 142 | 148)
}

const SOURCE_EXTENSIONS: &[&str] = &[
    ".py", ".js", ".ts", ".jsx", ".tsx", ".go", ".rs", ".c", ".h",
    ".cpp", ".java", ".rb", ".sh", ".bash", ".zsh", ".yaml", ".yml",
    ".toml", ".cfg", ".ini", ".json", ".xml", ".zig",
];

const BINARY_DIRS: &[&str] = &[
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    "target", "zig-out", "zig-cache", "build", "dist", ".tox",
];

const SKIP_SCAN_DIRS: &[&str] = &[
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    "target", "zig-out", "zig-cache", "build", "dist", ".tox",
    "tests", "test", "spec", "fixtures", "testdata",
];

fn source_files(repo: &Path, skip_dirs: &[&str]) -> Vec<String> {
    let skip_set: HashSet<&str> = skip_dirs.iter().copied().collect();
    let mut results = Vec::new();
    _walk_source_files(repo, repo, &skip_set, &mut results);
    results
}

fn _walk_source_files(base: &Path, dir: &Path, skip: &HashSet<&str>, out: &mut Vec<String>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    let mut dirs_to_visit = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if !skip.contains(name.as_str()) {
                dirs_to_visit.push(path);
            }
        } else if path.is_file() {
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                let dot_ext = format!(".{}", ext);
                if SOURCE_EXTENSIONS.contains(&dot_ext.as_str()) {
                    if let Ok(rel) = path.strip_prefix(base) {
                        out.push(rel.display().to_string());
                    }
                }
            }
        }
    }
    for d in dirs_to_visit {
        _walk_source_files(base, &d, skip, out);
    }
}

#[derive(Clone, serde::Serialize)]
struct Finding {
    file: String,
    line: i64,
    detail: String,
}

#[derive(Clone, serde::Serialize)]
struct ScanResult {
    rule_id: i32,
    status: String,
    title: String,
    category: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    findings: Vec<Finding>,
}

fn scan_exposed_secrets(repo: &Path) -> Vec<Finding> {
    let patterns: Vec<(Regex, &str)> = vec![
        (Regex::new(r"AKIA[0-9A-Z]{16}").unwrap(), "AWS access key pattern"),
        (Regex::new(r#"password\s*=\s*['"][^'"]{3,}['"]"#).unwrap(), "hardcoded password"),
        (Regex::new(r"-----BEGIN\s+(RSA|DSA|EC|OPENSSH)?\s*PRIVATE KEY-----").unwrap(), "private key"),
        (Regex::new(r#"secret_key\s*=\s*['"][^'"]{3,}['"]"#).unwrap(), "hardcoded secret_key"),
    ];
    let mut findings = Vec::new();
    for fpath in source_files(repo, SKIP_SCAN_DIRS) {
        let full = repo.join(&fpath);
        let content = match fs::read_to_string(&full) {
            Ok(c) => c,
            Err(_) => continue,
        };
        for (lineno, line) in content.lines().enumerate() {
            for (pat, desc) in &patterns {
                if pat.is_match(line) {
                    findings.push(Finding { file: fpath.clone(), line: (lineno + 1) as i64, detail: format!("{} detected", desc) });
                    break;
                }
            }
        }
    }
    findings
}

fn scan_container_root(repo: &Path) -> Vec<Finding> {
    let mut findings = Vec::new();
    fn walk_dockerfiles(dir: &Path, repo: &Path, findings: &mut Vec<Finding>) {
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if name != ".git" && name != "node_modules" && name != "target" {
                    walk_dockerfiles(&path, repo, findings);
                }
            } else if name.starts_with("Dockerfile") {
                if let Ok(content) = fs::read_to_string(&path) {
                    if content.contains("FROM ") && !Regex::new(r"(?m)^\s*USER\s+\S+").unwrap().is_match(&content) {
                        let rel = path.strip_prefix(repo).unwrap_or(&path).display().to_string();
                        findings.push(Finding { file: rel, line: 0, detail: "Dockerfile missing USER directive (runs as root)".to_string() });
                    }
                }
            }
        }
    }
    walk_dockerfiles(repo, repo, &mut findings);
    findings
}

fn scan_exposed_env(repo: &Path) -> Vec<Finding> {
    let result = std::process::Command::new("git")
        .args(["ls-files", "--error-unmatch", ".env"])
        .current_dir(repo)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    match result {
        Ok(status) if status.success() => {
            vec![Finding { file: ".env".to_string(), line: 0, detail: ".env file is tracked in git".to_string() }]
        }
        _ => Vec::new(),
    }
}

fn scan_large_files(repo: &Path) -> Vec<Finding> {
    let threshold = 1000;
    let mut findings = Vec::new();
    for fpath in source_files(repo, BINARY_DIRS) {
        let full = repo.join(&fpath);
        let count = match fs::read_to_string(&full) {
            Ok(c) => c.lines().count(),
            Err(_) => continue,
        };
        if count > threshold {
            findings.push(Finding { file: fpath, line: 0, detail: format!("{} lines (threshold: {})", count, threshold) });
        }
    }
    findings
}

fn scan_todo_density(repo: &Path) -> Vec<Finding> {
    let todo_re = Regex::new(r"(?i)\b(TODO|FIXME|HACK|XXX)\b").unwrap();
    let threshold = 10;
    let mut findings = Vec::new();
    for fpath in source_files(repo, BINARY_DIRS) {
        let full = repo.join(&fpath);
        let content = match fs::read_to_string(&full) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let count = content.lines().filter(|line| todo_re.is_match(line)).count();
        if count >= threshold {
            findings.push(Finding { file: fpath, line: 0, detail: format!("{} TODO/FIXME/HACK comments", count) });
        }
    }
    findings
}

fn scan_broken_doc_links(repo: &Path) -> Vec<Finding> {
    let link_re = Regex::new(r"\[([^\]]+)\]\(([^)]+)\)").unwrap();
    let mut findings = Vec::new();
    fn walk_md(dir: &Path, repo: &Path, link_re: &Regex, findings: &mut Vec<Finding>) {
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if name != ".git" && name != "node_modules" {
                    walk_md(&path, repo, link_re, findings);
                }
            } else if name.ends_with(".md") {
                let rel = path.strip_prefix(repo).unwrap_or(&path).display().to_string();
                let fdir = path.parent().unwrap_or(repo);
                let content = match fs::read_to_string(&path) {
                    Ok(c) => c,
                    Err(_) => continue,
                };
                for (lineno, line) in content.lines().enumerate() {
                    for cap in link_re.captures_iter(line) {
                        let target = &cap[2];
                        if target.starts_with("http://") || target.starts_with("https://") || target.starts_with('#') || target.starts_with("mailto:") {
                            continue;
                        }
                        let target_clean = target.split('#').next().unwrap_or("").split('?').next().unwrap_or("");
                        if target_clean.is_empty() {
                            continue;
                        }
                        let full_target = fdir.join(target_clean);
                        let normalized = full_target.canonicalize().unwrap_or(full_target.clone());
                        if !normalized.exists() && !full_target.exists() {
                            findings.push(Finding { file: rel.clone(), line: (lineno + 1) as i64, detail: format!("broken link to {}", target_clean) });
                        }
                    }
                }
            }
        }
    }
    walk_md(repo, repo, &link_re, &mut findings);
    findings
}

fn scan_stale_readme(repo: &Path) -> Vec<Finding> {
    let readme = repo.join("README.md");
    if !readme.exists() {
        return vec![Finding { file: "README.md".to_string(), line: 0, detail: "README.md does not exist".to_string() }];
    }
    let readme_mtime = match fs::metadata(&readme).and_then(|m| m.modified()) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    let mut latest_source = std::time::SystemTime::UNIX_EPOCH;
    for fpath in source_files(repo, BINARY_DIRS) {
        let full = repo.join(&fpath);
        if let Ok(m) = fs::metadata(&full).and_then(|m| m.modified()) {
            if m > latest_source {
                latest_source = m;
            }
        }
    }
    if latest_source == std::time::SystemTime::UNIX_EPOCH {
        return Vec::new();
    }
    let days_stale = match latest_source.duration_since(readme_mtime) {
        Ok(d) => d.as_secs() as f64 / 86400.0,
        Err(_) => return Vec::new(),
    };
    if days_stale > 90.0 {
        return vec![Finding { file: "README.md".to_string(), line: 0, detail: format!("README.md is {} days behind latest source change", days_stale as i64) }];
    }
    Vec::new()
}

fn run_builtin_scanner(rule_id: i32, repo: &Path) -> Option<Vec<Finding>> {
    match rule_id {
        2 | 6 => Some(scan_exposed_secrets(repo)),
        15 => Some(scan_container_root(repo)),
        18 => Some(scan_exposed_env(repo)),
        42 => Some(scan_large_files(repo)),
        48 => Some(scan_todo_density(repo)),
        142 => Some(scan_broken_doc_links(repo)),
        148 => Some(scan_stale_readme(repo)),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Config and external tools
// ---------------------------------------------------------------------------

const DEFAULT_MAINTAIN_CONFIG: &str = r#"# tickets/maintain.yaml
# Enable/disable categories and configure external tools for mt maintain scan.

# Global settings
settings:
  log_file: tickets/maintain.log
  timeout: 60
  enabled: true

# Per-category tool configuration
# Set enabled: true and provide the command for your stack.
# Use {repo} as placeholder for the repository root path.
# Optional per-tool fields:
#   timeout: 120          # per-tool timeout in seconds (overrides global)
#   fix_command: ...      # auto-fix command (used with mt maintain scan --fix)

security:
  cve_scanner:
    enabled: false
    # command: pip-audit --format=json
    # command: npm audit --json
    # command: cargo audit --json
    # command: osv-scanner --format=json -r {repo}
  secret_scanner:
    enabled: false
    # command: gitleaks detect --source={repo} --report-format=json --no-git
  ssl_check:
    enabled: false
    # command: openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -enddate

deps:
  outdated_check:
    enabled: false
    # command: pip list --outdated --format=json
    # command: npm outdated --json
    # command: cargo outdated --format=json
  license_check:
    enabled: false
    # command: pip-licenses --format=json
    # command: license-checker --json
  unused_deps:
    enabled: false
    # command: depcheck --json
    # command: vulture {repo}

code_health:
  complexity:
    enabled: false
    # command: radon cc {repo} -a -j
  linter:
    enabled: false
    # command: pylint {repo} --output-format=json
    # command: eslint {repo}/src --format=json
    # command: cargo clippy --message-format=json
    # fix_command: cargo clippy --fix --allow-dirty
  formatter_check:
    enabled: false
    # command: black --check {repo} --quiet
    # fix_command: black {repo}
    # command: cargo fmt --check
    # fix_command: cargo fmt
  type_check:
    enabled: false
    # command: mypy {repo} --no-error-summary

performance:
  profiler:
    enabled: false
  bundle_size:
    enabled: false

database:
  migration_check:
    enabled: false
  query_analyzer:
    enabled: false

infrastructure:
  container_scan:
    enabled: false
  k8s_health:
    enabled: false
  terraform_drift:
    enabled: false

observability:
  prometheus_check:
    enabled: false
  alert_check:
    enabled: false

testing:
  coverage:
    enabled: false
    # command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout
    # command: nyc --reporter=json npm test
  test_runner:
    enabled: false
    # command: pytest {repo} --tb=short -q

documentation:
  link_checker:
    enabled: false
    # command: markdown-link-check {repo}/docs/**/*.md --json
  openapi_diff:
    enabled: false
"#;

fn config_category_map() -> HashMap<&'static str, &'static str> {
    let mut m = HashMap::new();
    m.insert("security", "security");
    m.insert("deps", "deps");
    m.insert("code_health", "code-health");
    m.insert("performance", "performance");
    m.insert("database", "database");
    m.insert("infrastructure", "infrastructure");
    m.insert("observability", "observability");
    m.insert("testing", "testing");
    m.insert("documentation", "docs");
    m
}

fn config_tool_rule_map() -> HashMap<&'static str, Vec<i32>> {
    let mut m: HashMap<&str, Vec<i32>> = HashMap::new();
    m.insert("cve_scanner", vec![1, 25]);
    m.insert("secret_scanner", vec![2, 6]);
    m.insert("ssl_check", vec![3]);
    m.insert("outdated_check", vec![21]);
    m.insert("license_check", vec![31]);
    m.insert("unused_deps", vec![30]);
    m.insert("complexity", vec![41]);
    m.insert("linter", vec![44, 45, 47]);
    m.insert("formatter_check", vec![53]);
    m.insert("type_check", vec![55]);
    m.insert("profiler", vec![63]);
    m.insert("bundle_size", vec![29]);
    m.insert("migration_check", vec![89]);
    m.insert("query_analyzer", vec![61]);
    m.insert("container_scan", vec![101]);
    m.insert("k8s_health", vec![106]);
    m.insert("terraform_drift", vec![117]);
    m.insert("prometheus_check", vec![121]);
    m.insert("alert_check", vec![122]);
    m.insert("coverage", vec![134]);
    m.insert("test_runner", vec![131]);
    m.insert("link_checker", vec![142]);
    m.insert("openapi_diff", vec![141]);
    m
}

fn load_maintain_config(repo: &Path) -> serde_json::Value {
    let config_path = repo.join("tickets").join("maintain.yaml");
    if !config_path.exists() {
        return serde_json::Value::Null;
    }
    let text = match fs::read_to_string(&config_path) {
        Ok(t) => t,
        Err(_) => return serde_json::Value::Null,
    };
    // Parse YAML into serde_json::Value via serde_yaml
    let yaml_val: serde_yaml::Value = match serde_yaml::from_str(&text) {
        Ok(v) => v,
        Err(_) => return serde_json::Value::Null,
    };
    // Convert to serde_json::Value
    yaml_to_json(&yaml_val)
}

fn yaml_to_json(v: &serde_yaml::Value) -> serde_json::Value {
    match v {
        serde_yaml::Value::Null => serde_json::Value::Null,
        serde_yaml::Value::Bool(b) => serde_json::Value::Bool(*b),
        serde_yaml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                serde_json::Value::Number(serde_json::Number::from(i))
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f)
                    .map(serde_json::Value::Number)
                    .unwrap_or(serde_json::Value::Null)
            } else {
                serde_json::Value::Null
            }
        }
        serde_yaml::Value::String(s) => serde_json::Value::String(s.clone()),
        serde_yaml::Value::Sequence(seq) => {
            serde_json::Value::Array(seq.iter().map(yaml_to_json).collect())
        }
        serde_yaml::Value::Mapping(map) => {
            let mut obj = serde_json::Map::new();
            for (k, val) in map {
                let key = match k {
                    serde_yaml::Value::String(s) => s.clone(),
                    _ => format!("{:?}", k),
                };
                obj.insert(key, yaml_to_json(val));
            }
            serde_json::Value::Object(obj)
        }
        _ => serde_json::Value::Null,
    }
}

struct ExternalTool {
    command: String,
    #[allow(dead_code)]
    category: String,
    rule_ids: Vec<i32>,
}

fn get_enabled_external_tools(config: &serde_json::Value) -> HashMap<String, ExternalTool> {
    let cat_map = config_category_map();
    let tool_rule_map = config_tool_rule_map();
    let mut tools = HashMap::new();
    for (cat_key, _cat_slug) in &cat_map {
        let cat_config = match config.get(cat_key) {
            Some(v) if v.is_object() => v,
            _ => continue,
        };
        if let Some(obj) = cat_config.as_object() {
            for (tool_name, tool_conf) in obj {
                if let Some(tc) = tool_conf.as_object() {
                    let enabled = tc.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false);
                    let command = tc.get("command").and_then(|v| v.as_str()).unwrap_or("");
                    if enabled && !command.is_empty() {
                        tools.insert(tool_name.clone(), ExternalTool {
                            command: command.to_string(),
                            category: _cat_slug.to_string(),
                            rule_ids: tool_rule_map.get(tool_name.as_str()).cloned().unwrap_or_default(),
                        });
                    }
                }
            }
        }
    }
    tools
}

fn get_config_log_path(repo: &Path, config: &serde_json::Value) -> Option<PathBuf> {
    let settings = config.get("settings")?;
    let log_file = settings.get("log_file")?.as_str()?;
    Some(repo.join(log_file))
}

fn get_config_timeout(config: &serde_json::Value) -> u64 {
    config.get("settings")
        .and_then(|s| s.get("timeout"))
        .and_then(|t| t.as_u64())
        .unwrap_or(60)
}

fn log_tool_run(log_path: &Path, rule_id: i32, tool_name: &str, status: &str, duration: f64, findings: usize, reason: &str) {
    let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let mut parts = vec![format!("{}  SCAN  rule={:<4} tool={:<16} status={:<5} duration={:.1}s", ts, rule_id, tool_name, status, duration)];
    if status == "fail" {
        parts.push(format!("findings={}", findings));
    }
    if status == "skip" && !reason.is_empty() {
        parts.push(format!("reason={}", reason));
    }
    let line = parts.join("  ");
    if let Some(parent) = log_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = OpenOptions::new().create(true).append(true).open(log_path)
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "{}", line)
        });
}

fn run_external_tool(command: &str, repo: &Path, timeout: u64) -> (i32, String, String) {
    let cmd = command.replace("{repo}", &repo.display().to_string());
    let result = std::process::Command::new("sh")
        .arg("-c")
        .arg(&cmd)
        .current_dir(repo)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn();
    match result {
        Ok(child) => {
            let output = match child.wait_with_output() {
                Ok(o) => o,
                Err(e) => return (-1, String::new(), e.to_string()),
            };
            let rc = output.status.code().unwrap_or(-1);
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            (rc, stdout, stderr)
        }
        Err(e) => (-1, String::new(), e.to_string()),
    }
}

fn scan_rule_with_config(repo: &Path, rule: &MaintenanceRule, config: &serde_json::Value, log_path: Option<&Path>) -> ScanResult {
    // Try built-in scanner first
    if let Some(findings) = run_builtin_scanner(rule.id, repo) {
        let start = Instant::now();
        // Scanner already ran, measure time approximately
        let duration = start.elapsed().as_secs_f64();
        let status = if findings.is_empty() { "pass" } else { "fail" };
        if let Some(lp) = log_path {
            log_tool_run(lp, rule.id, "built-in", status, duration, findings.len(), "");
        }
        return ScanResult {
            rule_id: rule.id,
            status: status.to_string(),
            title: rule.title.to_string(),
            category: rule.category.to_string(),
            reason: None,
            findings,
        };
    }

    // Try external tool from config
    let ext_tools = get_enabled_external_tools(config);
    for (tool_name, tool_info) in &ext_tools {
        if tool_info.rule_ids.contains(&rule.id) {
            let timeout = get_config_timeout(config);
            let start = Instant::now();
            let (rc, stdout, stderr) = run_external_tool(&tool_info.command, repo, timeout);
            let duration = start.elapsed().as_secs_f64();
            if rc == 0 {
                if let Some(lp) = log_path {
                    log_tool_run(lp, rule.id, tool_name, "pass", duration, 0, "");
                }
                return ScanResult {
                    rule_id: rule.id,
                    status: "pass".to_string(),
                    title: rule.title.to_string(),
                    category: rule.category.to_string(),
                    reason: None,
                    findings: Vec::new(),
                };
            } else {
                let detail = if !stdout.is_empty() { &stdout[..stdout.len().min(200)] } else { &stderr[..stderr.len().min(200)] };
                let findings = vec![Finding {
                    file: String::new(),
                    line: 0,
                    detail: format!("external tool '{}' reported issue: {}", tool_name, detail.trim()),
                }];
                if let Some(lp) = log_path {
                    log_tool_run(lp, rule.id, tool_name, "fail", duration, 1, "");
                }
                return ScanResult {
                    rule_id: rule.id,
                    status: "fail".to_string(),
                    title: rule.title.to_string(),
                    category: rule.category.to_string(),
                    reason: None,
                    findings,
                };
            }
        }
    }

    // No scanner available
    let mut reason = "no built-in scanner".to_string();
    if !rule.external_tool.is_empty() {
        reason = format!("{}; try: {}", reason, rule.external_tool);
    }
    if let Some(lp) = log_path {
        log_tool_run(lp, rule.id, "none", "skip", 0.0, 0, "no_config");
    }
    ScanResult {
        rule_id: rule.id,
        status: "skip".to_string(),
        title: rule.title.to_string(),
        category: rule.category.to_string(),
        reason: Some(reason),
        findings: Vec::new(),
    }
}

fn filter_maintenance_rules(categories: &[String], rule_ids: &[i32]) -> Vec<MaintenanceRule> {
    let all_rules = maintenance_rules();
    let mut rules = all_rules;
    if !categories.is_empty() {
        let cat_set: HashSet<&str> = categories.iter().map(|s| s.as_str()).collect();
        rules = rules.into_iter().filter(|r| cat_set.contains(r.category)).collect();
    }
    if !rule_ids.is_empty() {
        let id_set: HashSet<i32> = rule_ids.iter().copied().collect();
        rules = rules.into_iter().filter(|r| id_set.contains(&r.id)).collect();
    }
    rules
}

fn detect_project_stack(repo: &Path) -> HashMap<String, bool> {
    let checks: Vec<(&str, Vec<&str>)> = vec![
        ("python", vec!["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"]),
        ("node", vec!["package.json"]),
        ("rust", vec!["Cargo.toml"]),
        ("go", vec!["go.mod"]),
        ("docker", vec!["Dockerfile"]),
        ("terraform", vec!["main.tf"]),
        ("k8s", vec!["k8s", "kubernetes"]),
    ];
    let mut detected = HashMap::new();
    for (stack, markers) in &checks {
        for marker in markers {
            if repo.join(marker).exists() {
                detected.insert(stack.to_string(), true);
                break;
            }
        }
    }
    detected
}

fn generate_detected_config(repo: &Path) -> String {
    let stacks = detect_project_stack(repo);
    let stack_names: Vec<&String> = stacks.keys().collect::<Vec<_>>();
    let mut sorted_names: Vec<&str> = stack_names.iter().map(|s| s.as_str()).collect();
    sorted_names.sort();
    let stack_list = sorted_names.join(", ");

    let mut lines = vec![
        "# tickets/maintain.yaml".to_string(),
        "# Auto-generated by mt maintain init-config --detect".to_string(),
        format!("# Detected stacks: {}", if stack_list.is_empty() { "none" } else { &stack_list }),
        String::new(),
        "settings:".to_string(),
        "  log_file: tickets/maintain.log".to_string(),
        "  timeout: 60".to_string(),
        "  enabled: true".to_string(),
        String::new(),
    ];

    if stacks.contains_key("python") {
        lines.extend(vec![
            "security:".into(), "  cve_scanner:".into(), "    enabled: true".into(), "    command: pip-audit --format=json".into(),
            "  secret_scanner:".into(), "    enabled: true".into(), "    command: gitleaks detect --source={repo} --report-format=json --no-git".into(), "".into(),
            "deps:".into(), "  outdated_check:".into(), "    enabled: true".into(), "    command: pip list --outdated --format=json".into(),
            "  license_check:".into(), "    enabled: true".into(), "    command: pip-licenses --format=json".into(), "".into(),
            "code_health:".into(), "  linter:".into(), "    enabled: true".into(), "    command: pylint {repo} --output-format=json --exit-zero".into(),
            "  formatter_check:".into(), "    enabled: true".into(), "    command: black --check {repo} --quiet".into(),
            "  type_check:".into(), "    enabled: true".into(), "    command: mypy {repo} --no-error-summary".into(), "".into(),
            "testing:".into(), "  coverage:".into(), "    enabled: true".into(), "    command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout".into(),
            "  test_runner:".into(), "    enabled: true".into(), "    command: pytest {repo} --tb=short -q".into(), "".into(),
        ]);
    } else if stacks.contains_key("node") {
        lines.extend(vec![
            "security:".into(), "  cve_scanner:".into(), "    enabled: true".into(), "    command: npm audit --json".into(),
            "  secret_scanner:".into(), "    enabled: true".into(), "    command: gitleaks detect --source={repo} --report-format=json --no-git".into(), "".into(),
            "deps:".into(), "  outdated_check:".into(), "    enabled: true".into(), "    command: npm outdated --json".into(),
            "  license_check:".into(), "    enabled: true".into(), "    command: license-checker --json".into(),
            "  unused_deps:".into(), "    enabled: true".into(), "    command: depcheck --json".into(), "".into(),
            "code_health:".into(), "  linter:".into(), "    enabled: true".into(), "    command: eslint src --format=json".into(),
            "  formatter_check:".into(), "    enabled: true".into(), "    command: \"prettier --check 'src/**/*.{ts,tsx,js}'\"".into(), "".into(),
            "testing:".into(), "  test_runner:".into(), "    enabled: true".into(), "    command: npm test -- --json".into(),
            "  coverage:".into(), "    enabled: true".into(), "    command: nyc --reporter=json npm test".into(), "".into(),
        ]);
    } else if stacks.contains_key("rust") {
        lines.extend(vec![
            "security:".into(), "  cve_scanner:".into(), "    enabled: true".into(), "    command: cargo audit --json".into(),
            "  secret_scanner:".into(), "    enabled: true".into(), "    command: gitleaks detect --source={repo} --report-format=json --no-git".into(), "".into(),
            "deps:".into(), "  outdated_check:".into(), "    enabled: true".into(), "    command: cargo outdated --format=json".into(),
            "  unused_deps:".into(), "    enabled: true".into(), "    command: cargo-udeps --output json".into(), "".into(),
            "code_health:".into(), "  formatter_check:".into(), "    enabled: true".into(), "    command: cargo fmt --check".into(), "".into(),
            "testing:".into(), "  test_runner:".into(), "    enabled: true".into(), "    command: cargo test --message-format=json".into(), "".into(),
        ]);
    } else if stacks.contains_key("go") {
        lines.extend(vec![
            "security:".into(), "  cve_scanner:".into(), "    enabled: true".into(), "    command: govulncheck ./...".into(),
            "  secret_scanner:".into(), "    enabled: true".into(), "    command: gitleaks detect --source={repo} --report-format=json --no-git".into(), "".into(),
            "testing:".into(), "  test_runner:".into(), "    enabled: true".into(), "    command: go test ./...".into(),
            "  coverage:".into(), "    enabled: true".into(), "    command: go test -coverprofile=coverage.out ./...".into(), "".into(),
        ]);
    } else {
        lines.extend(vec![
            "security:".into(), "  secret_scanner:".into(), "    enabled: false".into(),
            "    # command: gitleaks detect --source={repo} --report-format=json --no-git".into(), "".into(),
        ]);
    }

    if stacks.contains_key("docker") {
        lines.extend(vec![
            "infrastructure:".into(), "  container_scan:".into(), "    enabled: true".into(), "    command: trivy image --format=json".into(), "".into(),
        ]);
    }
    if stacks.contains_key("terraform") {
        lines.extend(vec![
            "infrastructure:".into(), "  terraform_drift:".into(), "    enabled: true".into(), "    command: terraform plan -detailed-exitcode -json".into(), "".into(),
        ]);
    }

    lines.extend(vec![
        "documentation:".into(), "  link_checker:".into(), "    enabled: false".into(),
        "    # command: markdown-link-check {repo}/docs/**/*.md --json".into(), "".into(),
    ]);

    lines.join("\n") + "\n"
}

// Ticket body formatters for maintain create
fn format_suggestion_body(rule: &MaintenanceRule) -> String {
    let mut tool_section = String::new();
    if !rule.external_tool.is_empty() {
        tool_section = format!("\n## External Tool\n```\n{}\n```\n", rule.external_tool);
    }
    format!(
        "## Goal\nInvestigate and remediate: {title}\n\n## Detection Heuristic\n{detection}\n{tool}\n## Recommended Action\n{action}\n\n## Acceptance Criteria\n- [ ] Run detection heuristic against codebase\n- [ ] Fix any issues found, or close ticket if none exist\n- [ ] Verify fix passes CI\n\n## Notes\nAuto-generated by `mt maintain create` (rule {id}, category: {cat})\n",
        title = rule.title, detection = rule.detection, tool = tool_section, action = rule.action, id = rule.id, cat = rule.category,
    )
}

fn format_finding_body(rule: &MaintenanceRule, findings: &[Finding]) -> String {
    let findings_text: Vec<String> = findings.iter().map(|f| {
        let loc = if f.line > 0 { format!("line {}", f.line) } else { "file".to_string() };
        format!("- `{}` ({}): {}", f.file, loc, f.detail)
    }).collect();
    format!(
        "## Goal\nFix detected issue: {title}\n\n## Findings\n{findings}\n\n## Recommended Action\n{action}\n\n## Acceptance Criteria\n- [ ] Address all findings listed above\n- [ ] Verify fix passes CI\n\n## Notes\nAuto-detected by `mt maintain scan` (rule {id}, category: {cat})\n",
        title = rule.title, findings = findings_text.join("\n"), action = rule.action, id = rule.id, cat = rule.category,
    )
}

// ---------------------------------------------------------------------------
// Maintain subcommands
// ---------------------------------------------------------------------------

fn cmd_maintain_init_config(force: bool, detect: bool) -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let tdir = tickets_dir(&repo);
    fs::create_dir_all(&tdir)?;
    let config_path = tdir.join("maintain.yaml");
    if config_path.exists() && !force {
        eprintln!("config already exists: {}", config_path.display());
        eprintln!("use --force to overwrite");
        return Ok(1);
    }
    let content = if detect {
        let stacks = detect_project_stack(&repo);
        let mut names: Vec<&String> = stacks.keys().collect();
        names.sort();
        let stack_str: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
        eprintln!("detected stacks: {}", if stack_str.is_empty() { "none".to_string() } else { stack_str.join(", ") });
        generate_detected_config(&repo)
    } else {
        DEFAULT_MAINTAIN_CONFIG.to_string()
    };
    fs::write(&config_path, &content)?;
    println!("{}", config_path.display());
    Ok(0)
}

fn cmd_maintain_doctor() -> Result<i32> {
    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let config = load_maintain_config(&repo);
    if config.is_null() {
        eprintln!("no tickets/maintain.yaml found. run: mt maintain init-config");
        return Ok(2);
    }
    let ext_tools = get_enabled_external_tools(&config);
    if ext_tools.is_empty() {
        eprintln!("no external tools enabled in maintain.yaml");
        return Ok(0);
    }
    let mut ok_count = 0;
    let mut fail_count = 0;
    for (tool_name, tool_info) in &ext_tools {
        let binary = tool_info.command.split_whitespace().next().unwrap_or("").replace("{repo}", "");
        let binary = if binary.is_empty() { tool_info.command.split_whitespace().next().unwrap_or("").to_string() } else { binary };
        let found = which_binary(&binary);
        if let Some(path) = found {
            println!("[OK]    {:<20} {} -> {}", tool_name, binary, path);
            ok_count += 1;
        } else {
            println!("[MISS]  {:<20} {} -- not found on PATH", tool_name, binary);
            fail_count += 1;
        }
    }
    eprintln!("\n{} tool(s) checked: {} available, {} missing", ok_count + fail_count, ok_count, fail_count);
    Ok(if fail_count > 0 { 1 } else { 0 })
}

fn which_binary(name: &str) -> Option<String> {
    let output = std::process::Command::new("which")
        .arg(name)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if output.status.success() {
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        None
    }
}

fn cmd_maintain_list(categories: Vec<String>, rule_ids: Vec<i32>) -> Result<i32> {
    let rules = filter_maintenance_rules(&categories, &rule_ids);
    if rules.is_empty() {
        eprintln!("no rules match the given filters.");
        return Ok(1);
    }
    for rule in &rules {
        let scanner_tag = if has_builtin_scanner(rule.id) { "built-in" } else { "external" };
        println!("  {:3}  [{:<16}] {}  ({})", rule.id, rule.category, rule.title, scanner_tag);
        println!("        detection: {}", rule.detection);
        if !rule.external_tool.is_empty() {
            println!("        tool: {}", rule.external_tool);
        }
    }
    Ok(0)
}

fn cmd_maintain_scan(
    mut categories: Vec<String>,
    rule_ids: Vec<i32>,
    all: bool,
    format: String,
    profile: Option<String>,
    diff: bool,
    _fix: bool,
) -> Result<i32> {
    // Resolve --profile into categories
    if let Some(ref prof) = profile {
        let profile_cats = match prof.as_str() {
            "ci" => vec!["security", "code-health", "testing"],
            "nightly" => MAINTENANCE_CATEGORIES.to_vec(),
            _ => Vec::new(),
        };
        for cat in profile_cats {
            if !categories.contains(&cat.to_string()) {
                categories.push(cat.to_string());
            }
        }
    }

    if categories.is_empty() && rule_ids.is_empty() && !all {
        eprintln!("error: --category, --rule, --all, or --profile required for scanning.");
        eprintln!("hint: mt maintain list  (to browse rules first)");
        return Ok(2);
    }

    let mut effective_categories = categories;
    if all {
        effective_categories = MAINTENANCE_CATEGORIES.iter().map(|s| s.to_string()).collect();
    }

    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let rules = filter_maintenance_rules(&effective_categories, &rule_ids);
    if rules.is_empty() {
        eprintln!("no rules match the given filters.");
        return Ok(1);
    }

    let config = load_maintain_config(&repo);
    let log_path = get_config_log_path(&repo, &config);

    let mut results: Vec<ScanResult> = rules.iter()
        .map(|rule| scan_rule_with_config(&repo, rule, &config, log_path.as_deref()))
        .collect();

    // --diff: compare against last scan
    let last_scan_path = repo.join("tickets").join("maintain.last.json");
    if diff {
        if let Ok(prev_text) = fs::read_to_string(&last_scan_path) {
            if let Ok(prev_results) = serde_json::from_str::<Vec<serde_json::Value>>(&prev_text) {
                let prev_by_rule: HashMap<i64, &serde_json::Value> = prev_results.iter()
                    .filter_map(|r| r.get("rule_id").and_then(|v| v.as_i64()).map(|id| (id, r)))
                    .collect();
                let mut new_results = Vec::new();
                for r in &results {
                    let prev = prev_by_rule.get(&(r.rule_id as i64));
                    match prev {
                        None => new_results.push(r.clone()),
                        Some(prev_r) => {
                            let prev_status = prev_r.get("status").and_then(|v| v.as_str()).unwrap_or("");
                            if prev_status != r.status {
                                new_results.push(r.clone());
                            } else if r.status == "fail" && prev_status == "fail" {
                                // Show only new findings
                                let prev_findings: HashSet<(String, i64, String)> = prev_r.get("findings")
                                    .and_then(|v| v.as_array())
                                    .map(|arr| arr.iter().map(|f| {
                                        (f.get("file").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                                         f.get("line").and_then(|v| v.as_i64()).unwrap_or(0),
                                         f.get("detail").and_then(|v| v.as_str()).unwrap_or("").to_string())
                                    }).collect())
                                    .unwrap_or_default();
                                let new_findings: Vec<Finding> = r.findings.iter()
                                    .filter(|f| !prev_findings.contains(&(f.file.clone(), f.line, f.detail.clone())))
                                    .cloned()
                                    .collect();
                                if !new_findings.is_empty() {
                                    let mut r_copy = r.clone();
                                    r_copy.findings = new_findings;
                                    new_results.push(r_copy);
                                }
                            }
                        }
                    }
                }
                if new_results.is_empty() {
                    eprintln!("no new findings since last scan.");
                }
                // Save full results for future --diff, then use filtered for display
                let full_results: Vec<ScanResult> = rules.iter()
                    .map(|rule| scan_rule_with_config(&repo, rule, &config, None))
                    .collect();
                let _ = save_scan_results(&last_scan_path, &full_results);
                results = new_results;
            }
        }
    }

    // Save current scan for future --diff (if not diff mode, save all results)
    if !diff {
        let _ = save_scan_results(&last_scan_path, &results);
    }

    if format == "json" {
        println!("{}", serde_json::to_string_pretty(&results)?);
    } else {
        for r in &results {
            let status_upper = r.status.to_uppercase();
            match status_upper.as_str() {
                "FAIL" => {
                    let count = r.findings.len();
                    println!("[FAIL]  rule {:3}: {} -- {} finding(s)", r.rule_id, r.title, count);
                    for f in &r.findings {
                        let loc = if f.line > 0 { format!(":{}", f.line) } else { String::new() };
                        println!("        {}{}: {}", f.file, loc, f.detail);
                    }
                }
                "PASS" => {
                    println!("[PASS]  rule {:3}: {} -- ok", r.rule_id, r.title);
                }
                _ => {
                    let reason = r.reason.as_deref().unwrap_or("no built-in scanner");
                    println!("[SKIP]  rule {:3}: {} -- {}", r.rule_id, r.title, reason);
                }
            }
        }
    }

    let fail_count = results.iter().filter(|r| r.status == "fail").count();
    let pass_count = results.iter().filter(|r| r.status == "pass").count();
    let skip_count = results.iter().filter(|r| r.status == "skip").count();
    eprintln!("\n{} rule(s) scanned: {} failed, {} passed, {} skipped", results.len(), fail_count, pass_count, skip_count);
    Ok(if fail_count > 0 { 1 } else { 0 })
}

fn save_scan_results(path: &Path, results: &[ScanResult]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(results)?;
    fs::write(path, json)?;
    Ok(())
}

fn cmd_maintain_create(
    mut categories: Vec<String>,
    rule_ids: Vec<i32>,
    all: bool,
    dry_run: bool,
    skip_scan: bool,
    priority_override: Option<String>,
    owner: Option<String>,
) -> Result<i32> {
    if categories.is_empty() && rule_ids.is_empty() && !all {
        eprintln!("error: --category, --rule, or --all required.");
        eprintln!("hint: mt maintain scan --category <cat>  (to scan first)");
        return Ok(2);
    }

    if all {
        categories = MAINTENANCE_CATEGORIES.iter().map(|s| s.to_string()).collect();
    }

    let cwd = std::env::current_dir().context("failed to get current directory")?;
    let repo = find_repo_root(&cwd);
    let tdir = tickets_dir(&repo);
    fs::create_dir_all(&tdir)?;

    let rules = filter_maintenance_rules(&categories, &rule_ids);
    if rules.is_empty() {
        eprintln!("no rules match the given filters.");
        return Ok(1);
    }

    // Scan unless --skip-scan
    let config = load_maintain_config(&repo);
    let log_path = get_config_log_path(&repo, &config);
    let mut scan_results: HashMap<i32, ScanResult> = HashMap::new();
    if !skip_scan {
        for rule in &rules {
            let result = scan_rule_with_config(&repo, rule, &config, log_path.as_deref());
            scan_results.insert(rule.id, result);
        }
    }

    // Collect existing maint tags (deduplication)
    let existing_tags = collect_existing_maint_tags(&repo)?;

    let mut created = 0;
    let mut skipped_dedup = 0;
    let mut skipped_pass = 0;

    for rule in &rules {
        let tag = format!("maint-rule-{}", rule.id);
        if existing_tags.contains(&tag) {
            skipped_dedup += 1;
            continue;
        }

        // Check scan result
        if let Some(scan) = scan_results.get(&rule.id) {
            if scan.status == "pass" {
                skipped_pass += 1;
                continue;
            }
        }

        // Determine ticket body
        let scan = scan_results.get(&rule.id);
        let body = if scan.map(|s| s.status == "fail" && !s.findings.is_empty()).unwrap_or(false) {
            format_finding_body(rule, &scan.unwrap().findings)
        } else {
            format_suggestion_body(rule)
        };

        if dry_run {
            let label = if scan.map(|s| s.status == "fail").unwrap_or(false) { "findings" } else { "suggestion" };
            println!("[dry-run] [{}] [MAINT-{:03}] {}", label, rule.id, rule.title);
            created += 1;
            continue;
        }

        let tid = next_ticket_id_for_repo(&repo)?;
        let mut meta = Mapping::new();
        map_set_string(&mut meta, "id", &tid);
        map_set_string(&mut meta, "title", &format!("[MAINT-{:03}] {}", rule.id, rule.title));
        map_set_string(&mut meta, "status", "ready");
        let prio = priority_override.as_deref().unwrap_or(rule.default_priority);
        map_set_string(&mut meta, "priority", prio);
        map_set_string(&mut meta, "type", rule.default_type);
        map_set_string(&mut meta, "effort", rule.default_effort);
        let mut labels: Vec<String> = rule.labels.iter().map(|s| s.to_string()).collect();
        labels.push("auto-maintenance".to_string());
        map_set_string_array(&mut meta, "labels", labels);
        map_set_string_array(&mut meta, "tags", vec![
            format!("maint-rule-{}", rule.id),
            format!("maint-cat-{}", rule.category),
        ]);
        map_set_optional_string(&mut meta, "owner", owner.as_deref());
        let now = now_utc_iso();
        map_set_string(&mut meta, "created", &now);
        map_set_string(&mut meta, "updated", &now);
        map_set_string_array(&mut meta, "depends_on", Vec::new());
        map_set_optional_string(&mut meta, "branch", None);
        normalize_meta(&mut meta);

        let path = tdir.join(format!("{}.md", tid));
        write_ticket(&path, &meta, &body)?;
        println!("{}", path.display());
        created += 1;
    }

    let verb = if dry_run { "would be " } else { "" };
    eprintln!("{} ticket(s) {}created, {} skipped (duplicates), {} skipped (scan passed)", created, verb, skipped_dedup, skipped_pass);
    Ok(0)
}

fn collect_existing_maint_tags(repo: &Path) -> Result<HashSet<String>> {
    let mut tags = HashSet::new();
    for path in iter_ticket_files(&tickets_dir(repo))? {
        if let Ok((mut meta, _body)) = read_ticket(&path) {
            normalize_meta(&mut meta);
            let status = map_get_status(&meta);
            if status != "done" {
                for tag in map_get_string_array(&meta, "tags") {
                    if tag.starts_with("maint-rule-") {
                        tags.insert(tag);
                    }
                }
            }
        }
    }
    Ok(tags)
}

fn run() -> Result<i32> {
    let cli = Cli::parse();
    if cli.version || cli.command.is_none() {
        return cmd_version(false);
    }

    match cli.command.expect("checked for Some above") {
        Commands::Init => cmd_init(),
        Commands::New {
            title,
            priority,
            ticket_type,
            effort,
            label,
            tag,
            depends_on,
            goal,
        } => cmd_new(title, priority, ticket_type, effort, label, tag, depends_on, goal),
        Commands::Ls {
            status,
            label,
            owner,
            priority,
            ticket_type,
            show_invalid,
        } => cmd_ls(status, label, owner, priority, ticket_type, show_invalid),
        Commands::Show { id } => cmd_show(id),
        Commands::Pick {
            owner,
            label,
            avoid_label,
            priority,
            ticket_type,
            branch,
            ignore_deps,
            max_claimed_per_owner,
            skill,
            role,
            json,
        } => cmd_pick(
            owner,
            label,
            avoid_label,
            priority,
            ticket_type,
            branch,
            ignore_deps,
            max_claimed_per_owner,
            skill,
            role,
            json,
        ),
        Commands::AllocateTask {
            owner,
            label,
            avoid_label,
            priority,
            ticket_type,
            branch,
            ignore_deps,
            max_claimed_per_owner,
            lease_minutes,
            skill,
            role,
            json,
        } => cmd_allocate_task(
            owner,
            label,
            avoid_label,
            priority,
            ticket_type,
            branch,
            ignore_deps,
            max_claimed_per_owner,
            lease_minutes,
            skill,
            role,
            json,
        ),
        Commands::FailTask {
            id,
            owner,
            error,
            retry_limit,
            force,
        } => cmd_fail_task(id, owner, error, retry_limit, force),
        Commands::Claim {
            id,
            owner,
            branch,
            ignore_deps,
            force,
        } => cmd_claim(id, owner, branch, ignore_deps, force),
        Commands::Comment { id, text } => cmd_comment(id, text),
        Commands::SetStatus {
            id,
            status,
            force,
            clear_owner,
        } => cmd_set_status(id, status, force, clear_owner),
        Commands::Done { id, force } => cmd_done(id, force),
        Commands::Archive { id, force } => cmd_archive(id, force),
        Commands::Graph { mermaid, open_only } => cmd_graph(mermaid, open_only),
        Commands::Export { format } => cmd_export(format),
        Commands::Stats => cmd_stats(),
        Commands::Validate {
            max_claimed_per_owner,
            enforce_done_deps,
        } => cmd_validate(max_claimed_per_owner, enforce_done_deps),
        Commands::Report {
            db,
            summary,
            search,
            limit,
        } => cmd_report(db, summary, search, limit),
        Commands::Version { json } => cmd_version(json),
        Commands::Maintain { subcmd } => match subcmd {
            MaintainCmd::InitConfig { force, detect } => cmd_maintain_init_config(force, detect),
            MaintainCmd::Doctor => cmd_maintain_doctor(),
            MaintainCmd::List { category, rule } => cmd_maintain_list(category, rule),
            MaintainCmd::Scan { category, rule, all, format, profile, diff, fix } => {
                cmd_maintain_scan(category, rule, all, format, profile, diff, fix)
            }
            MaintainCmd::Create { category, rule, all, dry_run, skip_scan, priority, owner } => {
                cmd_maintain_create(category, rule, all, dry_run, skip_scan, priority, owner)
            }
        },
    }
}

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(err) => {
            eprintln!("{}", err);
            std::process::exit(2);
        }
    }
}
