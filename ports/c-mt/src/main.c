#include <errno.h>
#include <limits.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <direct.h>
#include <process.h>
#include <sys/stat.h>
#define PATH_SEP '\\'
#define getcwd _getcwd
#else
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#define PATH_SEP '/'
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

struct StringList;

static int path_is_file(const char *path);
static int path_is_dir(const char *path);
static int path_exists(const char *path);
static void join_path(char *dst, size_t dst_size, const char *a, const char *b);
static int find_in_path(const char *cmd, char *out, size_t out_size);
static int find_repo_root(char *out, size_t out_size);
static int dirname_from_path(const char *path, char *out, size_t out_size);
static int find_repo_root_from_dir(const char *start_dir, char *out, size_t out_size);
static int find_mt_entry_from_dir(const char *start_dir, char *out, size_t out_size);
static int is_valid_ticket_id(const char *id);
static char *xstrdup(const char *s);
static void trim_inplace(char *s);
static void parse_bracket_list(const char *raw, struct StringList *out);
static int read_all_text(const char *path, char **out_text);

static const char *DEFAULT_TEMPLATE_TEXT =
    "---\n"
    "id: T-000000\n"
    "title: Template: replace title\n"
    "status: ready\n"
    "priority: p1\n"
    "type: code\n"
    "effort: s\n"
    "labels: []\n"
    "tags: []\n"
    "owner: null\n"
    "created: 1970-01-01T00:00:00Z\n"
    "updated: 1970-01-01T00:00:00Z\n"
    "depends_on: []\n"
    "branch: null\n"
    "retry_count: 0\n"
    "retry_limit: 3\n"
    "allocated_to: null\n"
    "allocated_at: null\n"
    "lease_expires_at: null\n"
    "last_error: null\n"
    "last_attempted_at: null\n"
    "---\n"
    "\n"
    "## Goal\n"
    "Write a single-sentence goal.\n"
    "\n"
    "## Acceptance Criteria\n"
    "- [ ] Define clear, testable checks (2–5 items)\n"
    "\n"
    "## Notes\n"
    "\n"
    "## Agent Assignment\n"
    "- Suggested owner: agent-name\n"
    "- Suggested branch: feature/short-name\n"
    "\n"
    "## Implementation Plan\n"
    "- [ ] Describe 2-4 concrete execution steps\n"
    "- [ ] List test/validation commands to run\n"
    "- [ ] Note any dependency handoff requirements\n"
    "\n"
    "## Queue Lifecycle (if allocated)\n"
    "- [ ] Add progress with `mt comment <id> \"...\"`\n"
    "- [ ] If blocked/failing, run `mt fail-task <id> --error \"...\"`\n"
    "- [ ] On completion, move to `needs_review` then `done`\n";

static const char *EXAMPLE_BODY =
    "## Goal\n"
    "Replace this example with a real task.\n"
    "\n"
    "## Acceptance Criteria\n"
    "- [ ] Delete or edit this ticket\n"
    "- [ ] Create at least one real ticket with `mt new`\n"
    "\n"
    "## Notes\n"
    "This repository uses MuonTickets for agent-friendly coordination.\n";

#define MAX_ITEMS 64
#define MAX_ITEM_LEN 128

struct StringList {
    int count;
    char items[MAX_ITEMS][MAX_ITEM_LEN];
};

struct TemplateDefaults {
    int has_template;
    char status[32];
    char priority[32];
    char type[32];
    char effort[32];
    int owner_is_null;
    char owner[128];
    int branch_is_null;
    char branch[128];
    struct StringList labels;
    struct StringList tags;
    struct StringList depends_on;
    char *body;
};

struct NewArgs {
    const char *title;
    const char *priority;
    const char *type;
    const char *effort;
    const char *goal;
    struct StringList labels;
    struct StringList tags;
    struct StringList depends_on;
};

static const char *DEFAULT_NEW_BODY =
    "## Goal\n"
    "Write a single-sentence goal.\n"
    "\n"
    "## Acceptance Criteria\n"
    "- [ ] Define clear, testable checks (2-5 items)\n"
    "\n"
    "## Notes\n";

static const char *runtime_platform(void) {
#if defined(_WIN32)
    return "win32";
#elif defined(__APPLE__)
    return "darwin";
#elif defined(__linux__)
    return "linux";
#else
    return "unknown";
#endif
}

static void print_json_escaped(const char *s) {
    const unsigned char *p = (const unsigned char *)(s != NULL ? s : "");
    while (*p) {
        if (*p == '\\' || *p == '"') {
            putchar('\\');
            putchar((char)*p);
        } else if (*p == '\n') {
            fputs("\\n", stdout);
        } else if (*p == '\r') {
            fputs("\\r", stdout);
        } else if (*p == '\t') {
            fputs("\\t", stdout);
        } else {
            putchar((char)*p);
        }
        p++;
    }
}

static int read_version_file(const char *repo_root, int *major, int *minor, char *version_text, size_t version_text_size) {
    char version_path[PATH_MAX];
    char buf[128];
    FILE *f;
    int maj, min;
    char extra;

    join_path(version_path, sizeof(version_path), repo_root, "VERSION");
    f = fopen(version_path, "r");
    if (f == NULL) {
        fprintf(stderr, "Missing VERSION file at project root: %s\n", version_path);
        return 2;
    }
    if (fgets(buf, sizeof(buf), f) == NULL) {
        fclose(f);
        fprintf(stderr, "VERSION must match '<major>.<minor>' (example: 0.1)\n");
        return 2;
    }
    fclose(f);

    if (sscanf(buf, "%d.%d %c", &maj, &min, &extra) != 2) {
        fprintf(stderr, "VERSION must match '<major>.<minor>' (example: 0.1)\n");
        return 2;
    }

    if (major != NULL) {
        *major = maj;
    }
    if (minor != NULL) {
        *minor = min;
    }
    if (version_text != NULL && version_text_size > 0) {
        snprintf(version_text, version_text_size, "%d.%d", maj, min);
    }
    return 0;
}

static int resolve_repo_root(char *out, size_t out_size, int argc, char **argv) {
    char exe_dir[PATH_MAX];
    char exe_abs[PATH_MAX];

    if (find_repo_root(out, out_size)) {
        return 1;
    }
    if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0' && dirname_from_path(argv[0], exe_dir, sizeof(exe_dir)) && find_repo_root_from_dir(exe_dir, out, out_size)) {
        return 1;
    }
    if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0' && find_in_path(argv[0], exe_abs, sizeof(exe_abs)) && dirname_from_path(exe_abs, exe_dir, sizeof(exe_dir)) && find_repo_root_from_dir(exe_dir, out, out_size)) {
        return 1;
    }
    return 0;
}

static int cmd_version_native(int as_json, int argc, char **argv) {
    char repo_root[PATH_MAX];
    char version_text[64];
    int major = 0;
    int minor = 0;
    int rc;

    (void)argc;
    (void)argv;

    if (!find_repo_root(repo_root, sizeof(repo_root))) {
        if (getcwd(repo_root, sizeof(repo_root)) == NULL) {
            fprintf(stderr, "could not determine working directory\n");
            return 2;
        }
    }

    rc = read_version_file(repo_root, &major, &minor, version_text, sizeof(version_text));
    if (rc != 0) {
        return rc;
    }

    if (as_json) {
        fputs("{\"implementation\":\"c-mt\",\"version\":\"", stdout);
        print_json_escaped(version_text);
        fputs("\",\"version_major\":", stdout);
        printf("%d", major);
        fputs(",\"version_minor\":", stdout);
        printf("%d", minor);
        fputs(",\"build_tools\":{\"c_compiler\":\"", stdout);
        print_json_escaped(__VERSION__);
        fputs("\"},\"runtime\":{\"platform\":\"", stdout);
        print_json_escaped(runtime_platform());
        fputs("\"}}\n", stdout);
    } else {
        printf("c-mt %s\n", version_text);
        printf("c_compiler=%s\n", __VERSION__);
        printf("platform=%s\n", runtime_platform());
    }
    return 0;
}

static int should_handle_native_version(int argc, char **argv, int *as_json) {
    char repo_root[PATH_MAX];

    if (as_json != NULL) {
        *as_json = 0;
    }
    if (argc <= 1) {
        return find_repo_root(repo_root, sizeof(repo_root));
    }
    if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0) {
        return argc == 2;
    }
    if (strcmp(argv[1], "version") == 0) {
        if (argc == 2) {
            return 1;
        }
        if (argc == 3 && strcmp(argv[2], "--json") == 0) {
            if (as_json != NULL) {
                *as_json = 1;
            }
            return 1;
        }
    }
    return 0;
}

static int make_dir_if_missing(const char *path) {
    if (path_is_dir(path)) {
        return 0;
    }
#if defined(_WIN32)
    if (_mkdir(path) == 0 || errno == EEXIST) {
        return 0;
    }
#else
    if (mkdir(path, 0777) == 0 || errno == EEXIST) {
        return 0;
    }
#endif
    fprintf(stderr, "failed to create directory '%s': %s\n", path, strerror(errno));
    return 1;
}

static int write_text_file(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "failed to write '%s': %s\n", path, strerror(errno));
        return 1;
    }
    if (fputs(text, f) == EOF) {
        fprintf(stderr, "failed to write '%s': %s\n", path, strerror(errno));
        fclose(f);
        return 1;
    }
    if (fclose(f) != 0) {
        fprintf(stderr, "failed to close '%s': %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static int write_last_ticket_number_file(const char *tickets_dir, int n) {
    char p[PATH_MAX];
    char text[64];
    join_path(p, sizeof(p), tickets_dir, "last_ticket_id");
    snprintf(text, sizeof(text), "T-%06d\n", n);
    return write_text_file(p, text);
}

static int read_last_ticket_number_file(const char *tickets_dir, int *out) {
    char p[PATH_MAX];
    char line[128];
    FILE *f;
    int n = 0;
    char c = '\0';
    join_path(p, sizeof(p), tickets_dir, "last_ticket_id");
    f = fopen(p, "r");
    if (f == NULL) {
        return 0;
    }
    if (fgets(line, sizeof(line), f) == NULL) {
        fclose(f);
        return 0;
    }
    fclose(f);
    if (sscanf(line, "T-%d %c", &n, &c) == 1) {
        *out = n;
        return 1;
    }
    c = '\0';
    if (sscanf(line, "%d %c", &n, &c) == 1) {
        *out = n;
        return 1;
    }
    return 0;
}

static int parse_ticket_filename_number(const char *name, int *out) {
    int n = 0;
    char extra = '\0';
    if (sscanf(name, "T-%6d.md%c", &n, &extra) == 1) {
        *out = n;
        return 1;
    }
    return 0;
}

static int scan_ticket_dir_max(const char *dir_path) {
    DIR *d;
    struct dirent *ent;
    int max_n = 0;
    if (!path_is_dir(dir_path)) {
        return 0;
    }
    d = opendir(dir_path);
    if (d == NULL) {
        return 0;
    }
    while ((ent = readdir(d)) != NULL) {
        int n = 0;
        if (parse_ticket_filename_number(ent->d_name, &n) && n > max_n) {
            max_n = n;
        }
    }
    closedir(d);
    return max_n;
}

static int scan_ticket_max_all_buckets(const char *tickets_dir) {
    char archive_p[PATH_MAX];
    char errors_p[PATH_MAX];
    char backlogs_p[PATH_MAX];
    int max_n = 0;
    int n;

    n = scan_ticket_dir_max(tickets_dir);
    if (n > max_n) {
        max_n = n;
    }

    join_path(archive_p, sizeof(archive_p), tickets_dir, "archive");
    n = scan_ticket_dir_max(archive_p);
    if (n > max_n) {
        max_n = n;
    }

    join_path(errors_p, sizeof(errors_p), tickets_dir, "errors");
    n = scan_ticket_dir_max(errors_p);
    if (n > max_n) {
        max_n = n;
    }

    join_path(backlogs_p, sizeof(backlogs_p), tickets_dir, "backlogs");
    n = scan_ticket_dir_max(backlogs_p);
    if (n > max_n) {
        max_n = n;
    }

    return max_n;
}

static int has_active_ticket_files(const char *tickets_dir) {
    DIR *d;
    struct dirent *ent;
    if (!path_is_dir(tickets_dir)) {
        return 0;
    }
    d = opendir(tickets_dir);
    if (d == NULL) {
        return 0;
    }
    while ((ent = readdir(d)) != NULL) {
        int n = 0;
        if (parse_ticket_filename_number(ent->d_name, &n)) {
            closedir(d);
            return 1;
        }
    }
    closedir(d);
    return 0;
}

static void now_utc_iso(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
#if defined(_WIN32)
    gmtime_s(&tm_utc, &t);
#else
    gmtime_r(&t, &tm_utc);
#endif
    strftime(buf, buf_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

static int write_example_ticket(const char *tickets_dir, int ticket_n) {
    char ticket_path[PATH_MAX];
    char created[32];
    char updated[32];
    FILE *f;

    now_utc_iso(created, sizeof(created));
    now_utc_iso(updated, sizeof(updated));

    snprintf(ticket_path, sizeof(ticket_path), "%s%cT-%06d.md", tickets_dir, PATH_SEP, ticket_n);
    f = fopen(ticket_path, "w");
    if (f == NULL) {
        fprintf(stderr, "failed to write '%s': %s\n", ticket_path, strerror(errno));
        return 1;
    }

    fprintf(f,
            "---\n"
            "id: T-%06d\n"
            "title: Example: replace this ticket\n"
            "status: ready\n"
            "priority: p2\n"
            "type: chore\n"
            "effort: xs\n"
            "labels: [example]\n"
            "tags: []\n"
            "owner: null\n"
            "created: \"%s\"\n"
            "updated: \"%s\"\n"
            "depends_on: []\n"
            "branch: null\n"
            "retry_count: 0\n"
            "retry_limit: 3\n"
            "allocated_to: null\n"
            "allocated_at: null\n"
            "lease_expires_at: null\n"
            "last_error: null\n"
            "last_attempted_at: null\n"
            "---\n\n"
            "%s",
            ticket_n,
            created,
            updated,
            EXAMPLE_BODY);

    if (fclose(f) != 0) {
        fprintf(stderr, "failed to close '%s': %s\n", ticket_path, strerror(errno));
        return 1;
    }
    return 0;
}

static int should_handle_native_init(int argc, char **argv) {
    return argc == 2 && strcmp(argv[1], "init") == 0;
}

static int should_handle_native_new(int argc, char **argv) {
    return argc >= 3 && strcmp(argv[1], "new") == 0;
}

static int should_handle_native_show(int argc, char **argv) {
    return argc == 3 && strcmp(argv[1], "show") == 0;
}

static int should_handle_native_comment(int argc, char **argv) {
    return argc >= 4 && strcmp(argv[1], "comment") == 0;
}

static int should_handle_native_done_force(int argc, char **argv) {
    return argc == 4 && strcmp(argv[1], "done") == 0 && strcmp(argv[3], "--force") == 0;
}

static int should_handle_native_archive_force(int argc, char **argv) {
    return argc == 4 && strcmp(argv[1], "archive") == 0 && strcmp(argv[3], "--force") == 0;
}

static int today_utc(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
#if defined(_WIN32)
    if (gmtime_s(&tm_utc, &t) != 0) {
        return 1;
    }
#else
    if (gmtime_r(&t, &tm_utc) == NULL) {
        return 1;
    }
#endif
    if (strftime(buf, buf_size, "%Y-%m-%d", &tm_utc) == 0) {
        return 1;
    }
    return 0;
}

static int resolve_repo_or_cwd(char *repo_root, size_t repo_root_size) {
    if (find_repo_root(repo_root, repo_root_size)) {
        return 1;
    }
    return getcwd(repo_root, repo_root_size) != NULL;
}

static int resolve_ticket_path(const char *repo_root, const char *id, char *ticket_path, size_t ticket_path_size) {
    char tickets_path[PATH_MAX];
    if (!is_valid_ticket_id(id)) {
        fprintf(stderr, "Invalid ticket id: %s\n", id != NULL ? id : "<null>");
        return 2;
    }
    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    snprintf(ticket_path, ticket_path_size, "%s%c%s.md", tickets_path, PATH_SEP, id);
    return 0;
}

static char *substring_dup(const char *start, size_t n) {
    char *p = (char *)malloc(n + 1);
    if (p == NULL) {
        return NULL;
    }
    memcpy(p, start, n);
    p[n] = '\0';
    return p;
}

static int split_ticket_sections(const char *text, char **fm, char **body) {
    const char *fm_start;
    const char *fm_end;
    const char *body_start;

    if (text == NULL || strncmp(text, "---", 3) != 0) {
        return 1;
    }
    fm_start = text + 3;
    if (*fm_start == '\r') {
        fm_start++;
    }
    if (*fm_start == '\n') {
        fm_start++;
    }
    fm_end = strstr(fm_start, "\n---");
    if (fm_end == NULL) {
        return 1;
    }
    body_start = fm_end + 4;
    while (*body_start == '\r' || *body_start == '\n') {
        body_start++;
    }

    *fm = substring_dup(fm_start, (size_t)(fm_end - fm_start));
    *body = xstrdup(body_start);
    if (*fm == NULL || *body == NULL) {
        free(*fm);
        free(*body);
        *fm = NULL;
        *body = NULL;
        return 1;
    }
    return 0;
}

static int frontmatter_depends_on_id(const char *fm, const char *target_id) {
    char *copy;
    char *line;
    struct StringList deps;
    int i;

    memset(&deps, 0, sizeof(deps));
    copy = xstrdup(fm != NULL ? fm : "");
    if (copy == NULL) {
        return 0;
    }

    line = strtok(copy, "\n");
    while (line != NULL) {
        if (strncmp(line, "depends_on:", 11) == 0) {
            char val[1024];
            strncpy(val, line + 11, sizeof(val) - 1);
            val[sizeof(val) - 1] = '\0';
            trim_inplace(val);
            parse_bracket_list(val, &deps);
            break;
        }
        line = strtok(NULL, "\n");
    }

    free(copy);
    for (i = 0; i < deps.count; i++) {
        if (strcmp(deps.items[i], target_id) == 0) {
            return 1;
        }
    }
    return 0;
}

static char *build_updated_frontmatter(const char *fm, const char *updated_iso, const char *status_override) {
    char *copy;
    char *line;
    size_t cap = (fm != NULL ? strlen(fm) : 0) + 512;
    size_t len = 0;
    int saw_updated = 0;
    int saw_status = 0;
    char *out = (char *)malloc(cap);
    if (out == NULL) {
        return NULL;
    }
    out[0] = '\0';

    copy = xstrdup(fm != NULL ? fm : "");
    if (copy == NULL) {
        free(out);
        return NULL;
    }

    line = strtok(copy, "\n");
    while (line != NULL) {
        char row[1024];
        if (strncmp(line, "updated:", 8) == 0) {
            snprintf(row, sizeof(row), "updated: \"%s\"", updated_iso);
            saw_updated = 1;
        } else if (status_override != NULL && strncmp(line, "status:", 7) == 0) {
            snprintf(row, sizeof(row), "status: %s", status_override);
            saw_status = 1;
        } else {
            snprintf(row, sizeof(row), "%s", line);
        }

        {
            size_t need = strlen(row) + 2;
            if (len + need + 64 >= cap) {
                cap = (cap * 2) + need + 128;
                out = (char *)realloc(out, cap);
                if (out == NULL) {
                    free(copy);
                    return NULL;
                }
            }
            memcpy(out + len, row, strlen(row));
            len += strlen(row);
            out[len++] = '\n';
            out[len] = '\0';
        }

        line = strtok(NULL, "\n");
    }

    if (!saw_status && status_override != NULL) {
        char row[128];
        snprintf(row, sizeof(row), "status: %s\n", status_override);
        if (len + strlen(row) + 1 >= cap) {
            cap = cap + strlen(row) + 128;
            out = (char *)realloc(out, cap);
            if (out == NULL) {
                free(copy);
                return NULL;
            }
        }
        memcpy(out + len, row, strlen(row));
        len += strlen(row);
        out[len] = '\0';
    }

    if (!saw_updated) {
        char row[128];
        snprintf(row, sizeof(row), "updated: \"%s\"\n", updated_iso);
        if (len + strlen(row) + 1 >= cap) {
            cap = cap + strlen(row) + 128;
            out = (char *)realloc(out, cap);
            if (out == NULL) {
                free(copy);
                return NULL;
            }
        }
        memcpy(out + len, row, strlen(row));
        len += strlen(row);
        out[len] = '\0';
    }

    free(copy);
    return out;
}

static char *append_progress_log_line(const char *body, const char *text) {
    const char *src = body != NULL ? body : "";
    const char *marker = "## Progress Log";
    char date[32];
    size_t cap;
    char *out;

    if (today_utc(date, sizeof(date)) != 0) {
        strcpy(date, "1970-01-01");
    }

    cap = strlen(src) + strlen(text) + 256;
    out = (char *)malloc(cap);
    if (out == NULL) {
        return NULL;
    }

    strcpy(out, src);
    if (strstr(out, marker) == NULL) {
        size_t n = strlen(out);
        while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) {
            out[--n] = '\0';
        }
        strcat(out, "\n\n## Progress Log\n");
    }

    {
        size_t n = strlen(out);
        while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r')) {
            out[--n] = '\0';
        }
    }

    strcat(out, "\n- ");
    strcat(out, date);
    strcat(out, ": ");
    strcat(out, text);
    strcat(out, "\n");
    return out;
}

static int write_ticket_with_sections(const char *path, const char *fm, const char *body) {
    size_t total = strlen(fm) + strlen(body) + 16;
    char *content = (char *)malloc(total);
    int rc;
    if (content == NULL) {
        return 1;
    }
    snprintf(content, total, "---\n%s---\n\n%s", fm, body);
    rc = write_text_file(path, content);
    free(content);
    return rc;
}

static int cmd_comment_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char ticket_path[PATH_MAX];
    char now_iso[32];
    char *text = NULL;
    char *fm = NULL;
    char *body = NULL;
    char *new_fm = NULL;
    char *new_body = NULL;
    int rc;

    (void)argc;
    if (!resolve_repo_or_cwd(repo_root, sizeof(repo_root))) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }
    rc = resolve_ticket_path(repo_root, argv[2], ticket_path, sizeof(ticket_path));
    if (rc != 0) {
        return rc;
    }
    if (!path_exists(ticket_path)) {
        fprintf(stderr, "Ticket not found: %s\n", ticket_path);
        return 2;
    }

    if (read_all_text(ticket_path, &text) != 0 || text == NULL) {
        fprintf(stderr, "failed to read ticket: %s\n", ticket_path);
        return 1;
    }
    if (split_ticket_sections(text, &fm, &body) != 0) {
        free(text);
        fprintf(stderr, "Missing YAML frontmatter\n");
        return 2;
    }

    now_utc_iso(now_iso, sizeof(now_iso));
    new_fm = build_updated_frontmatter(fm, now_iso, NULL);
    new_body = append_progress_log_line(body, argv[3]);
    if (new_fm == NULL || new_body == NULL) {
        free(text); free(fm); free(body); free(new_fm); free(new_body);
        return 1;
    }

    rc = write_ticket_with_sections(ticket_path, new_fm, new_body);
    free(text); free(fm); free(body); free(new_fm); free(new_body);
    if (rc != 0) {
        return 1;
    }
    printf("commented on %s\n", argv[2]);
    return 0;
}

static int cmd_done_force_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char ticket_path[PATH_MAX];
    char now_iso[32];
    char *text = NULL;
    char *fm = NULL;
    char *body = NULL;
    char *new_fm = NULL;
    int rc;

    (void)argc;
    if (!resolve_repo_or_cwd(repo_root, sizeof(repo_root))) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }
    rc = resolve_ticket_path(repo_root, argv[2], ticket_path, sizeof(ticket_path));
    if (rc != 0) {
        return rc;
    }
    if (!path_exists(ticket_path)) {
        fprintf(stderr, "Ticket not found: %s\n", ticket_path);
        return 2;
    }

    if (read_all_text(ticket_path, &text) != 0 || text == NULL) {
        fprintf(stderr, "failed to read ticket: %s\n", ticket_path);
        return 1;
    }
    if (split_ticket_sections(text, &fm, &body) != 0) {
        free(text);
        fprintf(stderr, "Missing YAML frontmatter\n");
        return 2;
    }

    now_utc_iso(now_iso, sizeof(now_iso));
    new_fm = build_updated_frontmatter(fm, now_iso, "done");
    if (new_fm == NULL) {
        free(text); free(fm); free(body);
        return 1;
    }

    rc = write_ticket_with_sections(ticket_path, new_fm, body);
    free(text); free(fm); free(body); free(new_fm);
    if (rc != 0) {
        return 1;
    }

    printf("done %s\n", argv[2]);
    return 0;
}

static int cmd_archive_force_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char tickets_path[PATH_MAX];
    char archive_path[PATH_MAX];
    char src[PATH_MAX];
    char dst[PATH_MAX];
    DIR *d;
    struct dirent *ent;
    char dependents[2048];
    int has_dependents = 0;

    (void)argc;
    if (!resolve_repo_or_cwd(repo_root, sizeof(repo_root))) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }
    if (!is_valid_ticket_id(argv[2])) {
        fprintf(stderr, "Invalid ticket id: %s\n", argv[2]);
        return 2;
    }

    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    join_path(archive_path, sizeof(archive_path), tickets_path, "archive");
    snprintf(src, sizeof(src), "%s%c%s.md", tickets_path, PATH_SEP, argv[2]);
    snprintf(dst, sizeof(dst), "%s%c%s.md", archive_path, PATH_SEP, argv[2]);

    if (!path_exists(src)) {
        fprintf(stderr, "Ticket not found: %s\n", src);
        return 2;
    }
    if (make_dir_if_missing(archive_path) != 0) {
        return 1;
    }
    if (path_exists(dst)) {
        fprintf(stderr, "Refusing to archive: destination already exists: %s\n", dst);
        return 2;
    }

    dependents[0] = '\0';
    d = opendir(tickets_path);
    if (d != NULL) {
        while ((ent = readdir(d)) != NULL) {
            int n = 0;
            char idbuf[16];
            char p[PATH_MAX];
            char *text = NULL;
            char *fm = NULL;
            char *body = NULL;
            if (!parse_ticket_filename_number(ent->d_name, &n)) {
                continue;
            }
            snprintf(idbuf, sizeof(idbuf), "T-%06d", n);
            if (strcmp(idbuf, argv[2]) == 0) {
                continue;
            }
            snprintf(p, sizeof(p), "%s%c%s", tickets_path, PATH_SEP, ent->d_name);
            if (read_all_text(p, &text) != 0 || text == NULL) {
                continue;
            }
            if (split_ticket_sections(text, &fm, &body) == 0) {
                if (frontmatter_depends_on_id(fm, argv[2])) {
                    if (has_dependents) {
                        strncat(dependents, ", ", sizeof(dependents) - strlen(dependents) - 1);
                    }
                    strncat(dependents, idbuf, sizeof(dependents) - strlen(dependents) - 1);
                    has_dependents = 1;
                }
            }
            free(text); free(fm); free(body);
        }
        closedir(d);
    }

    if (has_dependents) {
        fprintf(
            stderr,
            "Warning: force-archiving with active dependents: %s. This can create invalid board state where active tickets depend_on archived tickets.\n",
            dependents
        );
    }

    if (rename(src, dst) != 0) {
        fprintf(stderr, "failed to archive ticket: %s\n", strerror(errno));
        return 1;
    }
    printf("archived %s -> tickets/archive/%s.md\n", argv[2], argv[2]);
    return 0;
}

static int is_valid_ticket_id(const char *id) {
    int n = 0;
    char extra = '\0';
    if (id == NULL) {
        return 0;
    }
    if (sscanf(id, "T-%6d%c", &n, &extra) != 1) {
        return 0;
    }
    return n >= 0;
}

static int print_file_to_stdout(const char *path) {
    FILE *f;
    char buf[4096];
    size_t n;

    f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "Ticket not found: %s\n", path);
        return 2;
    }
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        if (fwrite(buf, 1, n, stdout) != n) {
            fclose(f);
            fprintf(stderr, "failed writing ticket content\n");
            return 1;
        }
    }
    fclose(f);
    return 0;
}

static int cmd_show_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char tickets_path[PATH_MAX];
    char ticket_path[PATH_MAX];
    const char *id;

    (void)argc;

    id = argv[2];
    if (!is_valid_ticket_id(id)) {
        fprintf(stderr, "Invalid ticket id: %s\n", id != NULL ? id : "<null>");
        return 2;
    }

    if (!find_repo_root(repo_root, sizeof(repo_root))) {
        if (getcwd(repo_root, sizeof(repo_root)) == NULL) {
            fprintf(stderr, "could not determine working directory\n");
            return 2;
        }
    }

    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    snprintf(ticket_path, sizeof(ticket_path), "%s%c%s.md", tickets_path, PATH_SEP, id);
    return print_file_to_stdout(ticket_path);
}

static char *xstrdup(const char *s) {
    size_t n;
    char *p;
    if (s == NULL) {
        return NULL;
    }
    n = strlen(s);
    p = (char *)malloc(n + 1);
    if (p == NULL) {
        return NULL;
    }
    memcpy(p, s, n + 1);
    return p;
}

static void trim_inplace(char *s) {
    size_t i, start = 0, end;
    if (s == NULL) {
        return;
    }
    end = strlen(s);
    while (start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r')) {
        start++;
    }
    while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\n' || s[end - 1] == '\r')) {
        end--;
    }
    if (start > 0) {
        for (i = start; i < end; i++) {
            s[i - start] = s[i];
        }
    }
    s[end - start] = '\0';
}

static void unquote_inplace(char *s) {
    size_t n;
    if (s == NULL) {
        return;
    }
    n = strlen(s);
    if (n >= 2 && ((s[0] == '"' && s[n - 1] == '"') || (s[0] == '\'' && s[n - 1] == '\''))) {
        memmove(s, s + 1, n - 2);
        s[n - 2] = '\0';
    }
}

static int string_list_append(struct StringList *lst, const char *v) {
    if (lst->count >= MAX_ITEMS) {
        return 1;
    }
    strncpy(lst->items[lst->count], v, MAX_ITEM_LEN - 1);
    lst->items[lst->count][MAX_ITEM_LEN - 1] = '\0';
    lst->count++;
    return 0;
}

static void parse_bracket_list(const char *raw, struct StringList *out) {
    char buf[2048];
    char *p;
    char *start;
    if (raw == NULL) {
        return;
    }
    strncpy(buf, raw, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    trim_inplace(buf);
    if (buf[0] == '[') {
        char *end = strrchr(buf, ']');
        if (end != NULL) {
            *end = '\0';
            memmove(buf, buf + 1, strlen(buf));
        }
    }
    p = buf;
    start = buf;
    while (1) {
        if (*p == ',' || *p == '\0') {
            char saved = *p;
            char v[MAX_ITEM_LEN];
            *p = '\0';
            strncpy(v, start, sizeof(v) - 1);
            v[sizeof(v) - 1] = '\0';
            trim_inplace(v);
            unquote_inplace(v);
            if (v[0] != '\0') {
                string_list_append(out, v);
            }
            if (saved == '\0') {
                break;
            }
            start = p + 1;
        }
        p++;
    }
}

static int read_all_text(const char *path, char **out_text) {
    FILE *f;
    long sz;
    char *buf;
    size_t nread;
    *out_text = NULL;
    f = fopen(path, "rb");
    if (f == NULL) {
        return 1;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 1;
    }
    sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        return 1;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return 1;
    }
    buf = (char *)malloc((size_t)sz + 1);
    if (buf == NULL) {
        fclose(f);
        return 1;
    }
    nread = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[nread] = '\0';
    *out_text = buf;
    return 0;
}

static int parse_template_file(const char *template_path, struct TemplateDefaults *tpl) {
    char *text = NULL;
    char *fm_start;
    char *fm_end;
    char *body_start;
    char *line;

    memset(tpl, 0, sizeof(*tpl));
    strcpy(tpl->status, "ready");
    strcpy(tpl->priority, "p1");
    strcpy(tpl->type, "code");
    strcpy(tpl->effort, "s");
    tpl->owner_is_null = 1;
    tpl->branch_is_null = 1;

    if (!path_exists(template_path)) {
        return 0;
    }
    if (read_all_text(template_path, &text) != 0 || text == NULL) {
        fprintf(stderr, "Invalid ticket template at %s: unreadable file\n", template_path);
        return 2;
    }

    if (strncmp(text, "---", 3) != 0) {
        fprintf(stderr, "Invalid ticket template at %s: Missing YAML frontmatter\n", template_path);
        free(text);
        return 2;
    }
    fm_start = text + 3;
    if (*fm_start == '\r') {
        fm_start++;
    }
    if (*fm_start == '\n') {
        fm_start++;
    }
    fm_end = strstr(fm_start, "\n---");
    if (fm_end == NULL) {
        fprintf(stderr, "Invalid ticket template at %s: Unterminated YAML frontmatter\n", template_path);
        free(text);
        return 2;
    }
    *fm_end = '\0';
    body_start = fm_end + 4;
    while (*body_start == '\r' || *body_start == '\n') {
        body_start++;
    }

    line = strtok(fm_start, "\n");
    while (line != NULL) {
        char *colon = strchr(line, ':');
        if (colon != NULL) {
            char key[128];
            char val[512];
            size_t klen = (size_t)(colon - line);
            if (klen >= sizeof(key)) {
                klen = sizeof(key) - 1;
            }
            memcpy(key, line, klen);
            key[klen] = '\0';
            strncpy(val, colon + 1, sizeof(val) - 1);
            val[sizeof(val) - 1] = '\0';
            trim_inplace(key);
            trim_inplace(val);
            unquote_inplace(val);

            if (strcmp(key, "status") == 0) {
                strncpy(tpl->status, val, sizeof(tpl->status) - 1);
            } else if (strcmp(key, "priority") == 0) {
                strncpy(tpl->priority, val, sizeof(tpl->priority) - 1);
            } else if (strcmp(key, "type") == 0) {
                strncpy(tpl->type, val, sizeof(tpl->type) - 1);
            } else if (strcmp(key, "effort") == 0) {
                strncpy(tpl->effort, val, sizeof(tpl->effort) - 1);
            } else if (strcmp(key, "labels") == 0) {
                parse_bracket_list(val, &tpl->labels);
            } else if (strcmp(key, "tags") == 0) {
                parse_bracket_list(val, &tpl->tags);
            } else if (strcmp(key, "depends_on") == 0) {
                parse_bracket_list(val, &tpl->depends_on);
            } else if (strcmp(key, "owner") == 0) {
                if (strcmp(val, "null") == 0 || val[0] == '\0') {
                    tpl->owner_is_null = 1;
                    tpl->owner[0] = '\0';
                } else {
                    tpl->owner_is_null = 0;
                    strncpy(tpl->owner, val, sizeof(tpl->owner) - 1);
                }
            } else if (strcmp(key, "branch") == 0) {
                if (strcmp(val, "null") == 0 || val[0] == '\0') {
                    tpl->branch_is_null = 1;
                    tpl->branch[0] = '\0';
                } else {
                    tpl->branch_is_null = 0;
                    strncpy(tpl->branch, val, sizeof(tpl->branch) - 1);
                }
            }
        }
        line = strtok(NULL, "\n");
    }

    tpl->body = xstrdup(body_start);
    tpl->has_template = 1;
    free(text);
    return 0;
}

static void format_list_yaml(FILE *f, const struct StringList *lst) {
    int i;
    fputs("[", f);
    for (i = 0; i < lst->count; i++) {
        if (i > 0) {
            fputs(", ", f);
        }
        fputs(lst->items[i], f);
    }
    fputs("]", f);
}

static int validate_choice(const char *value, const char *const *choices, int n, const char *name) {
    int i;
    for (i = 0; i < n; i++) {
        if (strcmp(value, choices[i]) == 0) {
            return 0;
        }
    }
    fprintf(stderr, "Invalid %s %s from CLI/template.\n", name, value);
    return 2;
}

static int parse_new_args(int argc, char **argv, struct NewArgs *na) {
    int i;
    memset(na, 0, sizeof(*na));
    na->title = argv[2];
    for (i = 3; i < argc; i++) {
        const char *a = argv[i];
        if ((strcmp(a, "--priority") == 0 || strcmp(a, "--type") == 0 || strcmp(a, "--effort") == 0 ||
             strcmp(a, "--label") == 0 || strcmp(a, "--tag") == 0 || strcmp(a, "--depends-on") == 0 || strcmp(a, "--goal") == 0)) {
            if (i + 1 >= argc) {
                fprintf(stderr, "new: argument %s requires a value\n", a);
                return 2;
            }
            if (strcmp(a, "--priority") == 0) {
                na->priority = argv[++i];
            } else if (strcmp(a, "--type") == 0) {
                na->type = argv[++i];
            } else if (strcmp(a, "--effort") == 0) {
                na->effort = argv[++i];
            } else if (strcmp(a, "--goal") == 0) {
                na->goal = argv[++i];
            } else if (strcmp(a, "--label") == 0) {
                if (string_list_append(&na->labels, argv[++i]) != 0) {
                    return 2;
                }
            } else if (strcmp(a, "--tag") == 0) {
                if (string_list_append(&na->tags, argv[++i]) != 0) {
                    return 2;
                }
            } else if (strcmp(a, "--depends-on") == 0) {
                if (string_list_append(&na->depends_on, argv[++i]) != 0) {
                    return 2;
                }
            }
        } else {
            return -1;
        }
    }
    return 0;
}

static int cmd_new_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char tickets_path[PATH_MAX];
    char template_path[PATH_MAX];
    char ticket_path[PATH_MAX];
    char created[32];
    char updated[32];
    int tracked = 0;
    int scanned = 0;
    int has_tracked = 0;
    int next_n;
    FILE *f;
    struct NewArgs na;
    struct TemplateDefaults tpl;
    const char *priority;
    const char *type;
    const char *effort;
    const char *status;
    const struct StringList *labels;
    const struct StringList *tags;
    const struct StringList *deps;
    int rc;
    const char *const priorities[] = {"p0", "p1", "p2"};
    const char *const types[] = {"spec", "code", "tests", "docs", "refactor", "chore"};
    const char *const efforts[] = {"xs", "s", "m", "l"};

    rc = parse_new_args(argc, argv, &na);
    if (rc == -1) {
        return -1;
    }
    if (rc != 0) {
        return rc;
    }

    if (getcwd(repo_root, sizeof(repo_root)) == NULL) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }
    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    if (make_dir_if_missing(tickets_path) != 0) {
        return 1;
    }

    join_path(template_path, sizeof(template_path), tickets_path, "ticket.template");
    rc = parse_template_file(template_path, &tpl);
    if (rc != 0) {
        return rc;
    }

    has_tracked = read_last_ticket_number_file(tickets_path, &tracked);
    scanned = scan_ticket_max_all_buckets(tickets_path);
    next_n = (has_tracked && tracked > scanned ? tracked : scanned) + 1;

    priority = na.priority != NULL ? na.priority : tpl.priority;
    type = na.type != NULL ? na.type : tpl.type;
    effort = na.effort != NULL ? na.effort : tpl.effort;
    status = tpl.status[0] != '\0' ? tpl.status : "ready";
    if (strcmp(status, "ready") && strcmp(status, "claimed") && strcmp(status, "blocked") && strcmp(status, "needs_review") && strcmp(status, "done")) {
        status = "ready";
    }

    if (validate_choice(priority, priorities, 3, "priority") != 0) {
        free(tpl.body);
        return 2;
    }
    if (validate_choice(type, types, 6, "type") != 0) {
        free(tpl.body);
        return 2;
    }
    if (validate_choice(effort, efforts, 4, "effort") != 0) {
        free(tpl.body);
        return 2;
    }

    labels = na.labels.count > 0 ? &na.labels : &tpl.labels;
    tags = na.tags.count > 0 ? &na.tags : &tpl.tags;
    deps = na.depends_on.count > 0 ? &na.depends_on : &tpl.depends_on;

    snprintf(ticket_path, sizeof(ticket_path), "%s%cT-%06d.md", tickets_path, PATH_SEP, next_n);
    f = fopen(ticket_path, "w");
    if (f == NULL) {
        fprintf(stderr, "failed to write '%s': %s\n", ticket_path, strerror(errno));
        free(tpl.body);
        return 1;
    }

    now_utc_iso(created, sizeof(created));
    now_utc_iso(updated, sizeof(updated));

    fprintf(f,
            "---\n"
            "id: T-%06d\n"
            "title: %s\n"
            "status: %s\n"
            "priority: %s\n"
            "type: %s\n"
            "effort: %s\n"
            "labels: ",
            next_n,
            na.title,
            status,
            priority,
            type,
            effort);
    format_list_yaml(f, labels);
    fputs("\ntags: ", f);
    format_list_yaml(f, tags);
    fputs("\nowner: ", f);
    if (tpl.owner_is_null) {
        fputs("null", f);
    } else {
        fputs(tpl.owner, f);
    }
        fprintf(f,
            "\ncreated: \"%s\"\n"
            "updated: \"%s\"\n"
            "depends_on: ",
            created,
            updated);
    format_list_yaml(f, deps);
    fputs("\nbranch: ", f);
    if (tpl.branch_is_null) {
        fputs("null", f);
    } else {
        fputs(tpl.branch, f);
    }
    fputs("\nretry_count: 0\nretry_limit: 3\nallocated_to: null\nallocated_at: null\nlease_expires_at: null\nlast_error: null\nlast_attempted_at: null\n---\n\n", f);

    if (na.goal != NULL && na.goal[0] != '\0') {
        fprintf(f,
                "## Goal\n"
                "%s\n\n"
                "## Acceptance Criteria\n"
                "- [ ] Define clear, testable checks (2-5 items)\n\n"
                "## Notes\n",
                na.goal);
    } else if (tpl.body != NULL && tpl.body[0] != '\0') {
        fputs(tpl.body, f);
        if (tpl.body[strlen(tpl.body) - 1] != '\n') {
            fputc('\n', f);
        }
    } else {
        fputs(DEFAULT_NEW_BODY, f);
        if (DEFAULT_NEW_BODY[strlen(DEFAULT_NEW_BODY) - 1] != '\n') {
            fputc('\n', f);
        }
    }

    if (fclose(f) != 0) {
        fprintf(stderr, "failed to close '%s': %s\n", ticket_path, strerror(errno));
        free(tpl.body);
        return 1;
    }
    if (write_last_ticket_number_file(tickets_path, next_n) != 0) {
        free(tpl.body);
        return 1;
    }

    printf("%s\n", ticket_path);
    free(tpl.body);
    return 0;
}

static int cmd_init_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    char tickets_path[PATH_MAX];
    char template_path[PATH_MAX];
    int tracked = 0;
    int has_tracked = 0;
    int scanned = 0;
    int next_n;

    (void)argc;
    (void)argv;

    if (getcwd(repo_root, sizeof(repo_root)) == NULL) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }

    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    if (!path_is_dir(tickets_path)) {
        if (make_dir_if_missing(tickets_path) != 0) {
            return 1;
        }
        printf("created %s\n", tickets_path);
    } else {
        printf("tickets dir exists: %s\n", tickets_path);
    }

    join_path(template_path, sizeof(template_path), tickets_path, "ticket.template");
    if (!path_exists(template_path)) {
        if (write_text_file(template_path, DEFAULT_TEMPLATE_TEXT) != 0) {
            return 1;
        }
        printf("created %s\n", template_path);
    }

    if (!has_active_ticket_files(tickets_path)) {
        has_tracked = read_last_ticket_number_file(tickets_path, &tracked);
        scanned = scan_ticket_max_all_buckets(tickets_path);
        next_n = (has_tracked && tracked > scanned ? tracked : scanned) + 1;
        if (write_last_ticket_number_file(tickets_path, next_n) != 0) {
            return 1;
        }
        if (write_example_ticket(tickets_path, next_n) != 0) {
            return 1;
        }
        printf("created example ticket T-%06d\n", next_n);
    } else {
        has_tracked = read_last_ticket_number_file(tickets_path, &tracked);
        scanned = scan_ticket_max_all_buckets(tickets_path);
        if (!has_tracked || tracked < scanned) {
            if (write_last_ticket_number_file(tickets_path, scanned) != 0) {
                return 1;
            }
            printf("updated %s%c%s to T-%06d\n", tickets_path, PATH_SEP, "last_ticket_id", scanned);
        }
    }
    return 0;
}

static int path_exists(const char *path) {
    struct stat st;
    return path != NULL && stat(path, &st) == 0;
}

static int is_executable_file(const char *path) {
    if (!path_is_file(path)) {
        return 0;
    }
#if defined(_WIN32)
    return 1;
#else
    return access(path, X_OK) == 0;
#endif
}

static int find_in_path(const char *cmd, char *out, size_t out_size) {
    const char *path_env;
    char *copy;
    char *tok;
    char candidate[PATH_MAX];

    if (cmd == NULL || cmd[0] == '\0') {
        return 0;
    }
    if (strchr(cmd, '/') != NULL || strchr(cmd, '\\') != NULL) {
        if (is_executable_file(cmd)) {
            strncpy(out, cmd, out_size - 1);
            out[out_size - 1] = '\0';
            return 1;
        }
        return 0;
    }

    path_env = getenv("PATH");
    if (path_env == NULL || path_env[0] == '\0') {
        return 0;
    }

    copy = (char *)malloc(strlen(path_env) + 1);
    if (copy == NULL) {
        return 0;
    }
    strcpy(copy, path_env);

    tok = strtok(copy, ";:");
    while (tok != NULL) {
        join_path(candidate, sizeof(candidate), tok, cmd);
        if (is_executable_file(candidate)) {
            strncpy(out, candidate, out_size - 1);
            out[out_size - 1] = '\0';
            free(copy);
            return 1;
        }
        tok = strtok(NULL, ";:");
    }

    free(copy);
    return 0;
}

static int path_is_dir(const char *path) {
    struct stat st;
    if (path == NULL || stat(path, &st) != 0) {
        return 0;
    }
#if defined(_WIN32)
    return (st.st_mode & _S_IFDIR) != 0;
#else
    return S_ISDIR(st.st_mode);
#endif
}

static int path_is_file(const char *path) {
    struct stat st;
    if (path == NULL || stat(path, &st) != 0) {
        return 0;
    }
#if defined(_WIN32)
    return (st.st_mode & _S_IFREG) != 0;
#else
    return S_ISREG(st.st_mode);
#endif
}

static void join_path(char *dst, size_t dst_size, const char *a, const char *b) {
    size_t len = 0;
    if (dst_size == 0) {
        return;
    }
    dst[0] = '\0';
    if (a != NULL) {
        len = strlen(a);
        if (len >= dst_size) {
            len = dst_size - 1;
        }
        memcpy(dst, a, len);
        dst[len] = '\0';
    }
    if (len > 0 && dst[len - 1] != '/' && dst[len - 1] != '\\' && len + 1 < dst_size) {
        dst[len++] = PATH_SEP;
        dst[len] = '\0';
    }
    if (b != NULL && len + 1 < dst_size) {
        strncat(dst, b, dst_size - strlen(dst) - 1);
    }
}

static int parent_dir(char *path) {
    size_t len;
    if (path == NULL) {
        return 0;
    }
    len = strlen(path);
    while (len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\')) {
        path[len - 1] = '\0';
        len--;
    }
    while (len > 0 && path[len - 1] != '/' && path[len - 1] != '\\') {
        path[len - 1] = '\0';
        len--;
    }
    while (len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\')) {
        path[len - 1] = '\0';
        len--;
    }
    return len > 0;
}

static int find_repo_root(char *out, size_t out_size) {
    char cur[PATH_MAX];
    char tickets_path[PATH_MAX];
    char mt_path[PATH_MAX];

    if (getcwd(cur, sizeof(cur)) == NULL) {
        return 0;
    }

    while (1) {
        join_path(tickets_path, sizeof(tickets_path), cur, "tickets");
        join_path(mt_path, sizeof(mt_path), cur, "mt.py");
        if (path_is_dir(tickets_path) && path_is_file(mt_path)) {
            strncpy(out, cur, out_size - 1);
            out[out_size - 1] = '\0';
            return 1;
        }
        if (!parent_dir(cur)) {
            break;
        }
    }
    return 0;
}

static int dirname_from_path(const char *path, char *out, size_t out_size) {
    size_t len;
    if (path == NULL || path[0] == '\0' || out_size == 0) {
        return 0;
    }
    strncpy(out, path, out_size - 1);
    out[out_size - 1] = '\0';
    len = strlen(out);
    while (len > 0 && out[len - 1] != '/' && out[len - 1] != '\\') {
        out[len - 1] = '\0';
        len--;
    }
    while (len > 0 && (out[len - 1] == '/' || out[len - 1] == '\\')) {
        out[len - 1] = '\0';
        len--;
    }
    return len > 0;
}

static int find_repo_root_from_dir(const char *start_dir, char *out, size_t out_size) {
    char cur[PATH_MAX];
    char tickets_path[PATH_MAX];
    char mt_path[PATH_MAX];

    if (start_dir == NULL || start_dir[0] == '\0') {
        return 0;
    }
    strncpy(cur, start_dir, sizeof(cur) - 1);
    cur[sizeof(cur) - 1] = '\0';

    while (1) {
        join_path(tickets_path, sizeof(tickets_path), cur, "tickets");
        join_path(mt_path, sizeof(mt_path), cur, "mt.py");
        if (path_is_dir(tickets_path) && path_is_file(mt_path)) {
            strncpy(out, cur, out_size - 1);
            out[out_size - 1] = '\0';
            return 1;
        }
        if (!parent_dir(cur)) {
            break;
        }
    }
    return 0;
}

static int find_mt_entry_from_dir(const char *start_dir, char *out, size_t out_size) {
    char cur[PATH_MAX];
    char mt_path[PATH_MAX];

    if (start_dir == NULL || start_dir[0] == '\0') {
        return 0;
    }
    strncpy(cur, start_dir, sizeof(cur) - 1);
    cur[sizeof(cur) - 1] = '\0';

    while (1) {
        join_path(mt_path, sizeof(mt_path), cur, "mt.py");
        if (path_is_file(mt_path)) {
            strncpy(out, mt_path, out_size - 1);
            out[out_size - 1] = '\0';
            return 1;
        }
        if (!parent_dir(cur)) {
            break;
        }
    }
    return 0;
}

#if defined(_WIN32)
static int run_cmd(const char *python_exe, const char *script_path, int argc, char **argv) {
    int i;
    char **cmd_argv = (char **)calloc((size_t)argc + 3, sizeof(char *));
    if (cmd_argv == NULL) {
        fprintf(stderr, "allocation failed\n");
        return 1;
    }

    cmd_argv[0] = (char *)python_exe;
    cmd_argv[1] = (char *)script_path;
    for (i = 1; i < argc; i++) {
        cmd_argv[i + 1] = argv[i];
    }
    cmd_argv[argc + 1] = NULL;

    errno = 0;
    int rc = _spawnvp(_P_WAIT, python_exe, (const char *const *)cmd_argv);
    if (rc < 0) {
        fprintf(stderr, "failed to execute '%s': %s\n", python_exe, strerror(errno));
        free(cmd_argv);
        return 1;
    }
    free(cmd_argv);
    return rc;
}
#else
static int run_cmd(const char *python_exe, const char *script_path, int argc, char **argv) {
    int i;
    char **cmd_argv = (char **)calloc((size_t)argc + 3, sizeof(char *));
    if (cmd_argv == NULL) {
        fprintf(stderr, "allocation failed\n");
        return 1;
    }

    cmd_argv[0] = (char *)python_exe;
    cmd_argv[1] = (char *)script_path;
    for (i = 1; i < argc; i++) {
        cmd_argv[i + 1] = argv[i];
    }
    cmd_argv[argc + 1] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "fork failed: %s\n", strerror(errno));
        free(cmd_argv);
        return 1;
    }
    if (pid == 0) {
        execvp(python_exe, cmd_argv);
        fprintf(stderr, "failed to execute '%s': %s\n", python_exe, strerror(errno));
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        fprintf(stderr, "waitpid failed: %s\n", strerror(errno));
        free(cmd_argv);
        return 1;
    }

    free(cmd_argv);

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return 1;
}
#endif

int main(int argc, char **argv) {
    const char *env_python = getenv("MT_PYTHON");
    const char *env_entry = getenv("MT_PY_ENTRY");
    char python_exe[PATH_MAX];

    char repo_root[PATH_MAX];
    char auto_entry[PATH_MAX];
    char exe_dir[PATH_MAX];
    char exe_abs[PATH_MAX];
    int version_json = 0;
    int new_rc = 0;

    if (should_handle_native_init(argc, argv)) {
        return cmd_init_native(argc, argv);
    }

    if (should_handle_native_new(argc, argv)) {
        new_rc = cmd_new_native(argc, argv);
        if (new_rc >= 0) {
            return new_rc;
        }
    }

    if (should_handle_native_show(argc, argv)) {
        return cmd_show_native(argc, argv);
    }

    if (should_handle_native_comment(argc, argv)) {
        return cmd_comment_native(argc, argv);
    }

    if (should_handle_native_done_force(argc, argv)) {
        return cmd_done_force_native(argc, argv);
    }

    if (should_handle_native_archive_force(argc, argv)) {
        return cmd_archive_force_native(argc, argv);
    }

    if (should_handle_native_version(argc, argv, &version_json)) {
        return cmd_version_native(version_json, argc, argv);
    }

    const char *entry = NULL;
    if (env_entry != NULL && env_entry[0] != '\0') {
        entry = env_entry;
    } else if (resolve_repo_root(repo_root, sizeof(repo_root), argc, argv)) {
        join_path(auto_entry, sizeof(auto_entry), repo_root, "mt.py");
        entry = auto_entry;
    } else if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0' && dirname_from_path(argv[0], exe_dir, sizeof(exe_dir)) && find_mt_entry_from_dir(exe_dir, auto_entry, sizeof(auto_entry))) {
        entry = auto_entry;
    } else if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0' && find_in_path(argv[0], exe_abs, sizeof(exe_abs)) && dirname_from_path(exe_abs, exe_dir, sizeof(exe_dir)) && find_mt_entry_from_dir(exe_dir, auto_entry, sizeof(auto_entry))) {
        entry = auto_entry;
    } else {
        entry = "mt.py";
    }

    if (!path_exists(entry)) {
        fprintf(stderr,
                "could not locate mt.py entrypoint (looked for '%s'). Set MT_PY_ENTRY explicitly.\n",
                entry);
        return 2;
    }

    if (env_python != NULL && env_python[0] != '\0') {
        return run_cmd(env_python, entry, argc, argv);
    }

    if (find_in_path("python3", python_exe, sizeof(python_exe))) {
        return run_cmd(python_exe, entry, argc, argv);
    }
    if (find_in_path("python", python_exe, sizeof(python_exe))) {
        return run_cmd(python_exe, entry, argc, argv);
    }

    fprintf(stderr,
            "failed to run mt.py with python3/python. Set MT_PYTHON to a valid interpreter path.\n");
    return 1;
}
