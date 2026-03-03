use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use clap::{Parser, Subcommand};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::json;
use serde_yaml::{Mapping, Value};

#[derive(Parser, Debug)]
#[command(name = "mt")]
#[command(about = "MuonTickets CLI port (Rust scaffold)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
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
        json: bool,
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
}

const DEFAULT_STATES: &[&str] = &["ready", "claimed", "blocked", "needs_review", "done"];
const DEFAULT_PRIORITIES: &[&str] = &["p0", "p1", "p2"];
const DEFAULT_TYPES: &[&str] = &["spec", "code", "tests", "docs", "refactor", "chore"];
const DEFAULT_EFFORTS: &[&str] = &["xs", "s", "m", "l"];

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
        _ => 0,
    }
}

fn today_str() -> String {
    Utc::now().date_naive().format("%Y-%m-%d").to_string()
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
    repo_root.join("tickets").join("archive")
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
    "---\nid: T-000000\ntitle: Template: replace title\nstatus: ready\npriority: p1\ntype: code\neffort: s\nlabels: []\ntags: []\nowner: null\ncreated: 1970-01-01\nupdated: 1970-01-01\ndepends_on: []\nbranch: null\n---\n\n## Goal\nWrite a single-sentence goal.\n\n## Acceptance Criteria\n- [ ] Define clear, testable checks (2–5 items)\n\n## Notes\n"
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
    let scanned = scan_max_ticket_number(repo_root)?;
    let base = tracked.max(scanned);
    let next = base + 1;
    write_last_ticket_number(repo_root, next)?;
    Ok(format!("T-{next:06}"))
}

fn map_get_string(meta: &Mapping, key: &str) -> Option<String> {
    meta.get(Value::String(key.to_string()))
        .and_then(Value::as_str)
        .map(ToString::to_string)
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

    for (path, meta) in &records {
        let filename = path.file_name().and_then(|f| f.to_str()).unwrap_or("<unknown>");
        let status = map_get_status(meta);
        if !DEFAULT_STATES.contains(&status.as_str()) {
            errors.push(format!("{filename}: status must be one of {:?}, got {status:?}", DEFAULT_STATES));
        }
        let effort = map_get_string(meta, "effort").unwrap_or_else(|| "s".to_string());
        if !DEFAULT_EFFORTS.contains(&effort.as_str()) {
            errors.push(format!("{filename}: effort must be one of {:?}, got {effort:?}", DEFAULT_EFFORTS));
        }
        if status == "claimed" && map_get_string(meta, "owner").unwrap_or_default().is_empty() {
            errors.push(format!("{filename}: claimed ticket must have owner"));
        }
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

fn cmd_pick(
    owner: String,
    label: Vec<String>,
    avoid_label: Vec<String>,
    priority: Option<String>,
    ticket_type: Option<String>,
    branch: String,
    ignore_deps: bool,
    max_claimed_per_owner: i32,
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
        if let Some(ref wanted_type) = ticket_type {
            if map_get_string(meta, "type").unwrap_or_default() != *wanted_type {
                continue;
            }
        }

        let labels = map_get_string_array(meta, "labels");
        let label_set = labels.iter().cloned().collect::<BTreeSet<_>>();
        if !label.is_empty() && !label.iter().all(|item| label_set.contains(item)) {
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
    if rel.starts_with("tickets/archive/") {
        "archive".to_string()
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
        let is_archived = if bucket == "archive" { 1 } else { 0 };

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

fn run() -> Result<i32> {
    let cli = Cli::parse();
    match cli.command {
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
            json,
        ),
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
