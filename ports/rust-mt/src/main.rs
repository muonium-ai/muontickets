use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use clap::{Parser, Subcommand};
use regex::Regex;
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
    },
    Claim {
        id: String,
        #[arg(long)]
        owner: String,
    },
    Comment {
        id: String,
        text: String,
    },
    SetStatus {
        id: String,
        status: String,
    },
    Done {
        id: String,
    },
    Archive {
        id: String,
    },
    Graph,
    Export,
    Stats,
    Validate,
    Report,
}

const DEFAULT_STATES: &[&str] = &["ready", "claimed", "blocked", "needs_review", "done"];
const DEFAULT_PRIORITIES: &[&str] = &["p0", "p1", "p2"];
const DEFAULT_TYPES: &[&str] = &["spec", "code", "tests", "docs", "refactor", "chore"];
const DEFAULT_EFFORTS: &[&str] = &["xs", "s", "m", "l"];

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
        Commands::Pick { owner } => {
            println!("TODO: pick (Rust port): owner={owner}");
            Ok(0)
        }
        Commands::Claim { id, owner } => {
            println!("TODO: claim (Rust port): {id} owner={owner}");
            Ok(0)
        }
        Commands::Comment { id, text } => {
            println!("TODO: comment (Rust port): {id} text={text}");
            Ok(0)
        }
        Commands::SetStatus { id, status } => {
            println!("TODO: set-status (Rust port): {id} -> {status}");
            Ok(0)
        }
        Commands::Done { id } => {
            println!("TODO: done (Rust port): {id}");
            Ok(0)
        }
        Commands::Archive { id } => {
            println!("TODO: archive (Rust port): {id}");
            Ok(0)
        }
        Commands::Graph => {
            println!("TODO: graph (Rust port)");
            Ok(0)
        }
        Commands::Export => {
            println!("TODO: export (Rust port)");
            Ok(0)
        }
        Commands::Stats => {
            println!("TODO: stats (Rust port)");
            Ok(0)
        }
        Commands::Validate => {
            println!("TODO: validate (Rust port)");
            Ok(0)
        }
        Commands::Report => {
            println!("TODO: report (Rust port)");
            Ok(0)
        }
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
