#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <limits.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <regex.h>

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
    int maj, min, patch;
    char extra;

    join_path(version_path, sizeof(version_path), repo_root, "VERSION");
    f = fopen(version_path, "r");
    if (f == NULL) {
        fprintf(stderr, "Missing VERSION file at project root: %s\n", version_path);
        return 2;
    }
    if (fgets(buf, sizeof(buf), f) == NULL) {
        fclose(f);
        fprintf(stderr, "VERSION must match '<major>.<minor>[.<patch>]' (example: 0.1 or 0.1.1)\n");
        return 2;
    }
    fclose(f);

    if (sscanf(buf, "%d.%d.%d %c", &maj, &min, &patch, &extra) == 3) {
        if (version_text != NULL && version_text_size > 0) {
            snprintf(version_text, version_text_size, "%d.%d.%d", maj, min, patch);
        }
    } else if (sscanf(buf, "%d.%d %c", &maj, &min, &extra) == 2) {
        if (version_text != NULL && version_text_size > 0) {
            snprintf(version_text, version_text_size, "%d.%d", maj, min);
        }
    } else {
        fprintf(stderr, "VERSION must match '<major>.<minor>[.<patch>]' (example: 0.1 or 0.1.1)\n");
        return 2;
    }

    if (major != NULL) {
        *major = maj;
    }
    if (minor != NULL) {
        *minor = min;
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
    char cwd[PATH_MAX];
    char version_path[PATH_MAX];

    if (as_json != NULL) {
        *as_json = 0;
    }
    if (argc <= 1) {
        if (find_repo_root(repo_root, sizeof(repo_root))) {
            return 1;
        }
        if (getcwd(cwd, sizeof(cwd)) != NULL) {
            join_path(version_path, sizeof(version_path), cwd, "VERSION");
            if (path_is_file(version_path)) {
                return 1;
            }
        }
        return 0;
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

/* ======================================================================
 * Maintain command group: native C implementation
 * ====================================================================== */

#define MAINT_RULE_COUNT 150
#define MAX_FINDINGS 256
#define MAX_FINDING_DETAIL 512
#define MAX_SOURCE_FILES 4096

static const char *MAINTENANCE_CATEGORIES[] = {
    "security", "deps", "code-health", "performance",
    "database", "infrastructure", "observability",
    "testing", "docs",
};
#define NUM_MAINT_CATEGORIES 9

struct MaintenanceRule {
    int id;
    const char *title;
    const char *category;
    const char *detection;
    const char *action;
    const char *default_priority;
    const char *default_type;
    const char *default_effort;
    const char *labels[4];
    int label_count;
    const char *external_tool;
    int has_builtin_scanner;
};

struct Finding {
    char file[256];
    int line;
    char detail[MAX_FINDING_DETAIL];
};

struct ScanResult {
    int rule_id;
    char status[8]; /* "pass", "fail", "skip" */
    char title[256];
    char category[32];
    char reason[512];
    struct Finding findings[MAX_FINDINGS];
    int finding_count;
};

#define R2(id,title,cat,det,act,pri,typ,eff,l1,l2,ext,bi) \
    {id,title,cat,det,act,pri,typ,eff,{l1,l2,NULL,NULL},2,ext,bi}

static struct MaintenanceRule MAINT_RULES[MAINT_RULE_COUNT] = {
    /* Security 1-20 */
    R2(1,"CVE Dependency Vulnerability","security","dependency version < secure version from CVE DB","upgrade dependency and run tests","p0","chore","m","maintenance","security","npm audit | pip-audit | cargo audit | osv-scanner | trivy | grype",0),
    R2(2,"Exposed Secrets in Repo","security","regex patterns (AKIA..., private_key)","remove secret and move to vault","p0","chore","s","maintenance","security",NULL,1),
    R2(3,"Expired SSL Certificate","security","ssl_expiry_date < now + 14 days","renew certificate","p0","chore","s","maintenance","security","openssl s_client -connect host:443 | openssl x509 -noout -dates",0),
    R2(4,"Missing Security Headers","security","missing CSP, X-Frame-Options, X-XSS-Protection","add headers","p1","chore","s","maintenance","security","curl -I <url> (check response headers for CSP, X-Frame-Options, X-XSS-Protection)",0),
    R2(5,"Insecure Hashing Algorithm","security","md5 or sha1 usage","migrate to argon2/bcrypt","p0","chore","m","maintenance","security","grep -rn 'md5\\|sha1\\|MD5\\|SHA1' --include='*.py' --include='*.js' --include='*.go'",0),
    R2(6,"Hardcoded Password","security","password=\"...\" pattern","move to environment variable","p0","chore","s","maintenance","security",NULL,1),
    R2(7,"Open Debug Ports","security","container exposing debug ports (9229, 3000)","disable in production","p1","chore","s","maintenance","security","docker inspect <container> | grep -i port; kubectl get svc -o json",0),
    R2(8,"Unauthenticated Admin Endpoint","security","/admin route without auth middleware","enforce auth guard","p0","chore","m","maintenance","security","review route definitions for /admin paths without auth middleware",0),
    R2(9,"Excessive IAM Privileges","security","policy contains \"*\"","restrict permissions","p1","chore","m","maintenance","security","aws iam list-policies --only-attached | grep '\"*\"'; gcloud iam policies",0),
    R2(10,"Unencrypted DB Connection","security","connection string missing TLS flag","enforce encrypted connections","p1","chore","s","maintenance","security","grep -rn 'sslmode=disable\\|ssl=false\\|useSSL=false' (connection strings)",0),
    R2(11,"Weak JWT Secret","security","JWT secret length < 32 characters or common value","rotate to strong secret","p0","chore","s","maintenance","security","grep -rn 'jwt.sign\\|JWT_SECRET\\|jwt_secret' and check secret length/entropy",0),
    R2(12,"Missing Rate Limiting","security","API endpoints without rate limit middleware","add rate limiting","p1","chore","m","maintenance","security","review API framework middleware config for rate-limit setup",0),
    R2(13,"Disabled CSRF Protection","security","CSRF middleware disabled or missing","enable CSRF protection","p1","chore","s","maintenance","security","review framework config for CSRF middleware (csrf_exempt, disable_csrf)",0),
    R2(14,"Dependency Signature Mismatch","security","package checksum does not match registry","verify and re-fetch dependency","p0","chore","s","maintenance","security","npm audit signatures | pip hash --verify | cargo verify-project",0),
    R2(15,"Container Running as Root","security","Dockerfile missing USER directive","add non-root user","p1","chore","s","maintenance","security",NULL,1),
    R2(16,"Outdated OpenSSL","security","OpenSSL version < latest stable","upgrade OpenSSL","p0","chore","m","maintenance","security","openssl version; dpkg -l openssl; brew info openssl",0),
    R2(17,"Public Cloud Bucket","security","storage bucket with public access enabled","restrict bucket access","p0","chore","s","maintenance","security","aws s3api get-bucket-acl --bucket <name>; gsutil iam get gs://<bucket>",0),
    R2(18,"Exposed .env File","security",".env file tracked in git or publicly accessible","remove from tracking and add to .gitignore","p0","chore","s","maintenance","security",NULL,1),
    R2(19,"Missing MFA for Admin","security","admin accounts without MFA enabled","enforce MFA","p1","chore","s","maintenance","security","aws iam get-login-profile; review admin user MFA status in cloud console",0),
    R2(20,"Suspicious Login Activity","security","unusual login patterns or locations","investigate and rotate credentials","p0","chore","m","maintenance","security","review auth/access logs for unusual IPs, times, or geolocations",0),
    /* Deps 21-40 */
    R2(21,"Outdated Dependency","deps","npm/pip/cargo outdated","upgrade version","p1","chore","s","maintenance","deps","npm outdated | pip list --outdated | cargo outdated | uv pip list --outdated",0),
    R2(22,"Deprecated Library","deps","upstream marked deprecated","migrate to replacement","p1","chore","m","maintenance","deps","npm info <pkg> deprecated; check PyPI/crates.io status page",0),
    R2(23,"Unmaintained Dependency","deps","last commit > 3 years","replace library","p1","chore","l","maintenance","deps","check GitHub last commit date via API; npm info <pkg> time.modified",0),
    R2(24,"Duplicate Libraries","deps","multiple versions installed","consolidate version","p1","chore","s","maintenance","deps","npm ls --all | grep deduped; pip list | sort | uniq -d",0),
    R2(25,"Vulnerable Transitive Dependency","deps","nested CVE scan","update dependency tree","p0","chore","m","maintenance","deps","npm audit | pip-audit | cargo audit | osv-scanner (transitive deps)",0),
    R2(26,"Lockfile Drift","deps","mismatch with installed packages","rebuild lockfile","p1","chore","s","maintenance","deps","npm ci --dry-run; pip freeze > /tmp/freeze.txt && diff requirements.txt /tmp/freeze.txt",0),
    R2(27,"Outdated Build Toolchain","deps","compiler older than LTS","upgrade toolchain","p1","chore","m","maintenance","deps","rustc --version; python3 --version; node --version; go version; zig version",0),
    R2(28,"Runtime EOL","deps","runtime end-of-life version","upgrade runtime","p0","chore","m","maintenance","deps","check endoflife.date API for runtime EOL dates (python, node, ruby, etc.)",0),
    R2(29,"Dependency Size Explosion","deps","bundle size threshold exceeded","audit dependency","p2","chore","m","maintenance","deps","npm pack --dry-run; du -sh node_modules; cargo bloat",0),
    R2(30,"Unused Dependency","deps","static import analysis","remove package","p2","chore","s","maintenance","deps","depcheck (npm) | vulture (python) | cargo-udeps (rust)",0),
    R2(31,"License Change Detection","deps","dependency license changed in new version","review license compatibility","p1","chore","s","maintenance","deps","license-checker (npm) | pip-licenses | cargo-license; diff against previous",0),
    R2(32,"Conflicting Version Ranges","deps","dependency resolution conflicts","resolve version conflicts","p1","chore","m","maintenance","deps","npm ls --all 2>&1 | grep 'ERESOLVE\\|peer dep'; pip check",0),
    R2(33,"Unused Peer Dependencies","deps","peer dependency declared but unused","remove peer dependency","p2","chore","s","maintenance","deps","npm ls --all | grep 'peer dep'",0),
    R2(34,"Broken Registry References","deps","package registry URL unreachable","fix registry reference","p1","chore","s","maintenance","deps","npm ping; pip config list (check index-url reachability)",0),
    R2(35,"Checksum Mismatch","deps","package checksum mismatch on install","re-fetch and verify package","p0","chore","s","maintenance","deps","npm cache verify; pip hash --verify; cargo verify-project",0),
    R2(36,"Incompatible Binary Architecture","deps","native module built for wrong arch","rebuild for target architecture","p1","chore","m","maintenance","deps","file node_modules/**/*.node; check platform/arch in native bindings",0),
    R2(37,"Outdated WASM Runtime","deps","WASM runtime version behind stable","upgrade WASM runtime","p2","chore","m","maintenance","deps","check wasmtime/wasmer version against latest stable release",0),
    R2(38,"Outdated GPU Drivers","deps","GPU driver version behind stable","upgrade GPU drivers","p2","chore","m","maintenance","deps","nvidia-smi; check driver version against CUDA compatibility matrix",0),
    R2(39,"Mirror Outage Fallback","deps","primary package mirror unreachable","configure fallback mirror","p1","chore","s","maintenance","deps","npm ping --registry <mirror>; pip install --dry-run -i <mirror>",0),
    R2(40,"Corrupted Dependency Cache","deps","dependency cache integrity check fails","clear and rebuild cache","p1","chore","s","maintenance","deps","npm cache clean --force; pip cache purge; cargo clean",0),
    /* Code Health 41-60 */
    R2(41,"High Cyclomatic Complexity","code-health","cyclomatic complexity > 15","refactor into smaller functions","p2","refactor","m","maintenance","code-health","radon cc -a (python) | eslint --rule complexity (js) | gocyclo (go)",0),
    R2(42,"File Too Large","code-health","file > 1000 lines","split into modules","p2","refactor","l","maintenance","code-health",NULL,1),
    R2(43,"Duplicate Code Blocks","code-health","repeated code blocks detected","extract shared function","p2","refactor","m","maintenance","code-health","jscpd | flay (ruby) | PMD CPD (java); semgrep --config=p/duplicate-code",0),
    R2(44,"Dead Code Detection","code-health","unreachable or unused code paths","remove dead code","p2","refactor","s","maintenance","code-health","vulture (python) | ts-prune (typescript) | deadcode (go)",0),
    R2(45,"Deprecated API Usage","code-health","calls to deprecated functions/methods","migrate to replacement API","p1","refactor","m","maintenance","code-health","grep -rn '@deprecated\\|DeprecationWarning\\|DEPRECATED'",0),
    R2(46,"Missing Error Handling","code-health","unhandled exceptions or missing error checks","add error handling","p1","code","m","maintenance","code-health","pylint --disable=all --enable=W0702,W0703 | eslint no-empty-catch",0),
    R2(47,"Logging Inconsistency","code-health","inconsistent log levels or formats","standardize logging","p2","refactor","s","maintenance","code-health","grep -rn 'console.log\\|print(\\|log.Debug' and review log level consistency",0),
    R2(48,"Excessive TODO Comments","code-health","TODO/FIXME/HACK count exceeds threshold","address or create tickets for TODOs","p2","chore","m","maintenance","code-health",NULL,1),
    R2(49,"Long Parameter Lists","code-health","function parameters > 6","refactor to use parameter objects","p2","refactor","m","maintenance","code-health","pylint --disable=all --enable=R0913 | eslint max-params",0),
    R2(50,"Circular Imports","code-health","circular import dependency detected","restructure module dependencies","p1","refactor","l","maintenance","code-health","python -c 'import importlib; importlib.import_module(\"pkg\")' | madge --circular (js)",0),
    R2(51,"Missing Type Hints","code-health","functions without type annotations","add type hints","p2","refactor","m","maintenance","code-health","mypy --strict | pyright; check function signatures for missing annotations",0),
    R2(52,"Unused Imports","code-health","imported modules never referenced","remove unused imports","p2","refactor","xs","maintenance","code-health","autoflake --check (python) | eslint no-unused-vars (js)",0),
    R2(53,"Inconsistent Formatting","code-health","code style deviates from project standard","run formatter","p2","chore","xs","maintenance","code-health","black --check (python) | prettier --check (js) | rustfmt --check (rust)",0),
    R2(54,"Poor Naming Patterns","code-health","variable/function names unclear or inconsistent","rename for clarity","p2","refactor","m","maintenance","code-health","pylint naming-convention | eslint camelcase/naming-convention",0),
    R2(55,"Missing Docstrings","code-health","public functions without documentation","add docstrings","p2","docs","m","maintenance","code-health","pydocstyle | darglint | interrogate (python)",0),
    R2(56,"Nested Loops","code-health","deeply nested loops (> 3 levels)","refactor to reduce nesting","p2","refactor","m","maintenance","code-health","review code for nested for/while loops > 3 levels deep",0),
    R2(57,"Unsafe Pointer Operations","code-health","raw pointer usage without safety checks","add bounds checking or use safe alternatives","p1","code","m","maintenance","code-health","clippy (rust) | cppcheck (c/c++) | review unsafe blocks",0),
    R2(58,"Unbounded Recursion","code-health","recursive function without base case limit","add recursion depth limit","p1","code","s","maintenance","code-health","review recursive functions for missing base case or depth limit",0),
    R2(59,"Magic Numbers","code-health","unexplained numeric literals in code","extract to named constants","p2","refactor","s","maintenance","code-health","pylint --disable=all --enable=W0612 | eslint no-magic-numbers",0),
    R2(60,"Mutable Global State","code-health","global variables modified at runtime","refactor to local/injected state","p1","refactor","m","maintenance","code-health","grep -rn 'global ' (python) | review mutable module-level state",0),
    /* Performance 61-80 */
    R2(61,"Slow Database Query","performance","query execution > 500ms","optimize query or add index","p1","code","m","maintenance","performance","EXPLAIN ANALYZE <query>; pg_stat_statements; slow query log",0),
    R2(62,"N+1 Query Pattern","performance","repeated queries in loop","batch or join queries","p1","code","m","maintenance","performance","django-debug-toolbar | bullet gem (rails) | review ORM queries in loops",0),
    R2(63,"Memory Leak Detection","performance","heap growth without release","fix memory leak","p0","code","l","maintenance","performance","valgrind --leak-check=full | heaptrack | node --inspect + Chrome DevTools",0),
    R2(64,"High API Latency","performance","p95 latency exceeds threshold","profile and optimize endpoint","p1","code","m","maintenance","performance","check APM dashboards (Datadog, New Relic, Grafana) for p95 latency",0),
    R2(65,"Cache Miss Ratio","performance","cache miss ratio > 0.6","tune cache strategy","p1","code","m","maintenance","performance","redis-cli INFO stats | memcached stats; check cache hit/miss metrics",0),
    R2(66,"Large Response Payloads","performance","API response size exceeds threshold","add pagination or compression","p2","code","m","maintenance","performance","curl -s <api> | wc -c; check API response sizes in APM",0),
    R2(67,"O(n^2) Algorithms","performance","quadratic complexity in hot paths","replace with efficient algorithm","p1","code","m","maintenance","performance","review hot-path code for nested loops; profile with py-spy/perf/flamegraph",0),
    R2(68,"Unbounded Job Queue","performance","job queue grows without limit","add backpressure or queue limits","p1","code","m","maintenance","performance","check job queue metrics (Sidekiq, Celery, Bull) for queue depth trends",0),
    R2(69,"Excessive Logging Overhead","performance","high-frequency logging in hot paths","reduce log verbosity or sample","p2","code","s","maintenance","performance","review logging in hot paths; check log volume metrics",0),
    R2(70,"Slow Cold Start","performance","service startup > threshold","optimize initialization","p2","code","m","maintenance","performance","time service startup; profile with py-spy/perf during init",0),
    R2(71,"Thread Starvation","performance","thread pool exhaustion detected","increase pool size or reduce blocking","p1","code","m","maintenance","performance","jstack (java) | py-spy dump | review thread pool configs",0),
    R2(72,"Lock Contention","performance","high lock wait times","reduce critical section scope","p1","code","m","maintenance","performance","lock contention profiling; review mutex/lock usage in hot paths",0),
    R2(73,"Blocking IO in Async Code","performance","synchronous IO in async context","convert to async IO","p1","code","m","maintenance","performance","review async code for sync IO calls (requests, open, subprocess)",0),
    R2(74,"Oversized Images","performance","image assets exceed size threshold","compress or resize images","p2","chore","s","maintenance","performance","find . -name '*.png' -o -name '*.jpg' | xargs identify -format '%f %wx%h %b\\n'",0),
    R2(75,"Redundant Network Calls","performance","duplicate API calls for same data","deduplicate or cache results","p2","code","m","maintenance","performance","review network calls in code; check for duplicate HTTP requests in APM",0),
    R2(76,"Inefficient Serialization","performance","slow serialization format in hot path","switch to efficient format","p2","code","m","maintenance","performance","benchmark serialization (json vs msgpack vs protobuf) in hot paths",0),
    R2(77,"Slow WASM Execution Path","performance","WASM module performance below threshold","profile and optimize WASM code","p2","code","m","maintenance","performance","wasm profiling tools; review WASM module execution times",0),
    R2(78,"GPU Underutilization","performance","GPU compute usage below capacity","optimize GPU workload distribution","p2","code","l","maintenance","performance","nvidia-smi dmon; review GPU utilization metrics",0),
    R2(79,"Excessive Disk Writes","performance","write IOPS exceeds threshold","batch or buffer writes","p2","code","m","maintenance","performance","iostat; check write IOPS metrics; review fsync/flush patterns",0),
    R2(80,"Poor Pagination","performance","unbounded result sets returned","implement cursor-based pagination","p1","code","m","maintenance","performance","review API endpoints for unbounded SELECT/find queries without LIMIT",0),
    /* Database 81-100 */
    R2(81,"Missing Index","database","frequent query without supporting index","add database index","p1","code","s","maintenance","database","EXPLAIN ANALYZE <query>; pg_stat_user_tables (seq_scan count); slow query log",0),
    R2(82,"Unused Index","database","index with zero reads","drop unused index","p2","chore","s","maintenance","database","pg_stat_user_indexes (idx_scan = 0); MySQL sys.schema_unused_indexes",0),
    R2(83,"Table Bloat","database","dead tuple ratio exceeds threshold","vacuum or repack table","p1","chore","s","maintenance","database","pg_stat_user_tables (n_dead_tup); VACUUM VERBOSE",0),
    R2(84,"Fragmented Index","database","index fragmentation > threshold","rebuild index","p2","chore","s","maintenance","database","pg_stat_user_indexes; DBCC SHOWCONTIG (SQL Server); OPTIMIZE TABLE (MySQL)",0),
    R2(85,"Orphan Records","database","records referencing deleted parents","clean up orphan records","p2","chore","m","maintenance","database","SELECT orphans with LEFT JOIN ... WHERE parent.id IS NULL",0),
    R2(86,"Duplicate Rows","database","duplicate records detected","deduplicate data","p1","chore","m","maintenance","database","SELECT columns, COUNT(*) GROUP BY columns HAVING COUNT(*) > 1",0),
    R2(87,"Data Format Drift","database","column data deviates from expected format","normalize data format","p2","chore","m","maintenance","database","sample column data and check format consistency; pg_typeof()",0),
    R2(88,"Backup Failure","database","last backup older than policy threshold","investigate and fix backup","p0","chore","m","maintenance","database","pg_stat_archiver; check backup tool logs (pg_dump, mysqldump, mongodump)",0),
    R2(89,"Failed Migration","database","migration in failed/partial state","fix and rerun migration","p0","chore","m","maintenance","database","check migration status table; rails db:migrate:status | alembic current",0),
    R2(90,"Slow Join Queries","database","join query exceeding time threshold","optimize join or denormalize","p1","code","m","maintenance","database","EXPLAIN ANALYZE for JOIN queries; check pg_stat_statements for slow joins",0),
    R2(91,"Oversized JSON Columns","database","JSON column average size exceeds threshold","normalize into relational columns","p2","refactor","l","maintenance","database","SELECT avg(pg_column_size(json_col)) FROM table; check JSON column sizes",0),
    R2(92,"Unused Tables","database","tables with no recent reads or writes","archive or drop unused tables","p2","chore","s","maintenance","database","pg_stat_user_tables (last_autovacuum, seq_scan, idx_scan for zero-activity tables)",0),
    R2(93,"Table Scan Alerts","database","full table scan on large table","add index or optimize query","p1","code","m","maintenance","database","pg_stat_user_tables (seq_scan on large tables); MySQL slow query log",0),
    R2(94,"Encoding Mismatch","database","mixed character encodings across tables","standardize encoding","p2","chore","m","maintenance","database","SELECT table_name, character_set_name FROM information_schema.columns",0),
    R2(95,"Unbounded Table Growth","database","table row count growing without retention policy","implement retention or archival","p1","chore","m","maintenance","database","SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC",0),
    R2(96,"Missing Partitioning","database","large table without partitioning scheme","add table partitioning","p2","chore","l","maintenance","database","check table sizes; review partitioning strategy for tables > 10M rows",0),
    R2(97,"Outdated Statistics","database","query planner statistics stale","analyze/update statistics","p2","chore","s","maintenance","database","pg_stat_user_tables (last_analyze); ANALYZE VERBOSE",0),
    R2(98,"Corrupted Index Pages","database","index corruption detected","rebuild corrupted index","p0","chore","m","maintenance","database","pg_catalog.pg_index (indisvalid = false); REINDEX",0),
    R2(99,"Replication Lag","database","replica behind primary by threshold","investigate replication lag","p0","chore","m","maintenance","database","SELECT * FROM pg_stat_replication; check replica lag metrics",0),
    R2(100,"Foreign Key Inconsistencies","database","orphaned foreign key references","fix referential integrity","p1","chore","m","maintenance","database","check foreign key constraints; SELECT with LEFT JOIN for orphaned references",0),
    /* Infrastructure 101-120 */
    R2(101,"Container Image Outdated","infrastructure","base image version behind latest","update container base image","p1","chore","m","maintenance","infrastructure","docker pull <image>:latest --dry-run; compare Dockerfile FROM tag to latest",0),
    R2(102,"Missing OS Security Patches","infrastructure","OS packages with available security updates","apply security patches","p0","chore","m","maintenance","infrastructure","apt list --upgradable | yum check-update | apk version -l '<'",0),
    R2(103,"Low Disk Space","infrastructure","disk usage > 85%","clean up or expand storage","p0","chore","s","maintenance","infrastructure","df -h; kubectl top nodes; cloud console storage metrics",0),
    R2(104,"CPU Saturation","infrastructure","sustained CPU usage > 90%","scale or optimize workload","p0","chore","m","maintenance","infrastructure","top; kubectl top pods; cloud monitoring CPU metrics",0),
    R2(105,"Memory Pressure","infrastructure","memory usage > 90% or OOM events","investigate memory usage and scale","p0","chore","m","maintenance","infrastructure","free -h; kubectl top pods; check OOM events in dmesg/journal",0),
    R2(106,"CrashLoop Pods","infrastructure","pod in CrashLoopBackOff state","diagnose and fix crash loop","p0","chore","m","maintenance","infrastructure","kubectl get pods --field-selector=status.phase!=Running; kubectl describe pod",0),
    R2(107,"Orphan Containers","infrastructure","stopped containers consuming resources","remove orphan containers","p2","chore","s","maintenance","infrastructure","docker ps -a --filter status=exited; docker system df",0),
    R2(108,"Stale Storage Volumes","infrastructure","unattached volumes with no recent access","clean up stale volumes","p2","chore","s","maintenance","infrastructure","kubectl get pv --no-headers | grep Available; aws ec2 describe-volumes --filters Name=status,Values=available",0),
    R2(109,"Expired DNS Records","infrastructure","DNS records pointing to decommissioned resources","update DNS records","p1","chore","s","maintenance","infrastructure","dig <hostname>; nslookup; check DNS records against active infrastructure",0),
    R2(110,"Misconfigured Load Balancer","infrastructure","health check failures or routing errors","fix load balancer configuration","p0","chore","m","maintenance","infrastructure","kubectl describe ingress; aws elb describe-target-health; health check logs",0),
    R2(111,"High Network Latency","infrastructure","inter-service latency exceeds threshold","investigate network path","p1","chore","m","maintenance","infrastructure","ping; traceroute; mtr; check network latency metrics in monitoring",0),
    R2(112,"Unused Cloud Resources","infrastructure","idle VMs, IPs, or load balancers","decommission unused resources","p2","chore","s","maintenance","infrastructure","aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped; cloud cost reports",0),
    R2(113,"Broken CI Runners","infrastructure","CI runner offline or failing jobs","repair or replace CI runner","p0","chore","m","maintenance","infrastructure","check CI dashboard for offline runners; gitlab-runner verify; gh api /repos/{owner}/{repo}/actions/runners",0),
    R2(114,"Container Restart Loops","infrastructure","container restart count exceeds threshold","diagnose restart cause","p0","chore","m","maintenance","infrastructure","docker inspect --format='{{.RestartCount}}'; kubectl describe pod (restart count)",0),
    R2(115,"Unused Security Groups","infrastructure","security groups not attached to resources","remove unused security groups","p2","chore","s","maintenance","infrastructure","aws ec2 describe-security-groups; check for unattached security groups",0),
    R2(116,"Expired API Gateway Cert","infrastructure","API gateway certificate expiring soon","renew API gateway certificate","p0","chore","s","maintenance","infrastructure","aws apigateway get-domain-names; check certificate expiry dates",0),
    R2(117,"Infrastructure Drift","infrastructure","live config differs from IaC definitions","reconcile infrastructure state","p1","chore","m","maintenance","infrastructure","terraform plan | pulumi preview | compare live state vs IaC definitions",0),
    R2(118,"Registry Cleanup Required","infrastructure","container registry storage exceeds threshold","prune old images from registry","p2","chore","s","maintenance","infrastructure","docker system df; cloud registry storage metrics; skopeo list-tags",0),
    R2(119,"Log Storage Overflow","infrastructure","log volume approaching storage limit","rotate or archive logs","p1","chore","s","maintenance","infrastructure","du -sh /var/log; check log rotation config; cloud logging storage metrics",0),
    R2(120,"Node Version Drift","infrastructure","cluster nodes running different versions","align node versions","p1","chore","m","maintenance","infrastructure","kubectl get nodes -o wide; compare node versions across cluster",0),
    /* Observability 121-130 */
    R2(121,"Missing Metrics","observability","service endpoints without metrics instrumentation","add metrics collection","p1","code","m","maintenance","observability","review service endpoints for metrics instrumentation; check Prometheus targets",0),
    R2(122,"Broken Alerts","observability","alert rules referencing missing metrics","fix alert configuration","p1","chore","s","maintenance","observability","promtool check rules; review alert rule YAML for missing metric references",0),
    R2(123,"Missing Distributed Tracing","observability","services without trace propagation","add trace instrumentation","p1","code","m","maintenance","observability","review code for trace context propagation (OpenTelemetry, Jaeger, Zipkin)",0),
    R2(124,"Log Retention Overflow","observability","log retention exceeding storage policy","adjust retention policy","p2","chore","s","maintenance","observability","check log retention policies; du -sh log storage; cloud logging config",0),
    R2(125,"Missing Uptime Checks","observability","production endpoints without health monitoring","add uptime checks","p1","chore","s","maintenance","observability","review uptime monitoring config (Pingdom, UptimeRobot, cloud health checks)",0),
    R2(126,"Alert Fatigue Detection","observability","high volume of non-actionable alerts","tune alert thresholds","p2","chore","m","maintenance","observability","review alert history for frequency; check PagerDuty/Opsgenie alert volume",0),
    R2(127,"Missing Error Classification","observability","errors logged without categorization","add error classification","p2","code","m","maintenance","observability","review error logging for categorization (error codes, error types)",0),
    R2(128,"Inconsistent Log Schema","observability","log format varies across services","standardize log schema","p2","chore","m","maintenance","observability","compare log formats across services; check structured logging config",0),
    R2(129,"Missing Service Map","observability","no service dependency map available","generate service map","p2","docs","m","maintenance","observability","review service dependencies; generate from traces or config (Kiali, Jaeger)",0),
    R2(130,"Outdated Dashboards","observability","dashboards referencing deprecated metrics","update dashboards","p2","chore","s","maintenance","observability","review Grafana/Datadog dashboards for deprecated metric references",0),
    /* Testing 131-140 */
    R2(131,"Failing Tests","testing","test suite has persistent failures","fix failing tests","p0","tests","m","maintenance","testing","run test suite and check exit code; review CI pipeline history for failures",0),
    R2(132,"Flaky Tests","testing","tests with intermittent pass/fail","stabilize flaky tests","p1","tests","m","maintenance","testing","run tests multiple times; check CI history for intermittent failures",0),
    R2(133,"Missing Regression Tests","testing","recent bug fixes without regression tests","add regression tests","p1","tests","m","maintenance","testing","review recent bug-fix commits for associated test additions",0),
    R2(134,"Low Coverage Modules","testing","modules below coverage threshold","add tests for low coverage areas","p2","tests","m","maintenance","testing","coverage run -m pytest; nyc; go test -cover; review coverage report",0),
    R2(135,"Outdated Snapshot Tests","testing","snapshot tests not updated after code changes","update snapshot tests","p2","tests","s","maintenance","testing","jest --updateSnapshot --dry-run; check snapshot diff against code changes",0),
    R2(136,"Slow Test Suite","testing","test suite execution exceeds threshold","optimize slow tests","p2","tests","m","maintenance","testing","time test suite execution; pytest --durations=10; jest --verbose",0),
    R2(137,"Missing Integration Tests","testing","critical paths without integration test coverage","add integration tests","p1","tests","l","maintenance","testing","review critical user paths for integration test coverage",0),
    R2(138,"Broken CI Pipeline","testing","CI pipeline failing on main branch","fix CI pipeline","p0","tests","m","maintenance","testing","check CI pipeline status on main branch; review recent CI logs",0),
    R2(139,"Missing Edge Case Tests","testing","boundary conditions untested","add edge case tests","p2","tests","m","maintenance","testing","review test cases for boundary values, null inputs, empty collections",0),
    R2(140,"Inconsistent Test Data","testing","test fixtures with hardcoded or stale data","standardize test data","p2","tests","s","maintenance","testing","review test fixtures for hardcoded dates, IDs, or stale data",0),
    /* Docs 141-150 */
    R2(141,"Outdated API Docs","docs","API documentation does not match implementation","update API documentation","p1","docs","m","maintenance","docs","diff API implementation against API docs; check OpenAPI spec freshness",0),
    R2(142,"Broken Documentation Links","docs","dead links in documentation","fix broken links","p2","docs","s","maintenance","docs",NULL,1),
    R2(143,"Outdated Onboarding Docs","docs","onboarding guide references removed features","update onboarding documentation","p1","docs","m","maintenance","docs","review onboarding docs against current setup/install process",0),
    R2(144,"Missing Architecture Diagram","docs","no architecture diagram or diagram is outdated","create or update architecture diagram","p2","docs","m","maintenance","docs","check for architecture diagrams in docs/; compare against current system",0),
    R2(145,"Missing CLI Examples","docs","CLI commands without usage examples","add CLI usage examples","p2","docs","s","maintenance","docs","review CLI --help output against documentation examples",0),
    R2(146,"Outdated Deployment Guide","docs","deployment guide does not match current process","update deployment guide","p1","docs","m","maintenance","docs","compare deployment docs against current deploy scripts/CI config",0),
    R2(147,"Undocumented Endpoints","docs","API endpoints without documentation","document undocumented endpoints","p1","docs","m","maintenance","docs","list API routes and compare against documented endpoints",0),
    R2(148,"Stale README","docs","README last updated significantly before repo activity","update README","p2","docs","s","maintenance","docs",NULL,1),
    R2(149,"Outdated SDK Docs","docs","SDK documentation does not match current API","update SDK documentation","p1","docs","m","maintenance","docs","diff SDK methods against API documentation; check SDK version alignment",0),
    R2(150,"Missing Changelog","docs","no changelog or changelog not updated for recent releases","update changelog","p2","docs","s","maintenance","docs","check CHANGELOG.md last entry date vs latest release tag",0),
};

/* Source file extensions for scanners */
static int is_source_ext(const char *ext) {
    static const char *exts[] = {
        ".py",".js",".ts",".jsx",".tsx",".go",".rs",".c",".h",
        ".cpp",".java",".rb",".sh",".bash",".zsh",".yaml",".yml",
        ".toml",".cfg",".ini",".json",".xml",".zig",NULL
    };
    int i;
    for (i = 0; exts[i]; i++) {
        if (strcmp(ext, exts[i]) == 0) return 1;
    }
    return 0;
}

static int is_skip_dir(const char *name, int skip_tests) {
    static const char *binary_dirs[] = {
        ".git","node_modules","__pycache__",".venv","venv",
        "target","zig-out","zig-cache","build","dist",".tox",NULL
    };
    static const char *test_dirs[] = {
        "tests","test","spec","fixtures","testdata",NULL
    };
    int i;
    for (i = 0; binary_dirs[i]; i++) {
        if (strcmp(name, binary_dirs[i]) == 0) return 1;
    }
    if (skip_tests) {
        for (i = 0; test_dirs[i]; i++) {
            if (strcmp(name, test_dirs[i]) == 0) return 1;
        }
    }
    return 0;
}

static const char *get_extension(const char *filename) {
    const char *dot = strrchr(filename, '.');
    return dot ? dot : "";
}

struct SourceFileList {
    char files[MAX_SOURCE_FILES][PATH_MAX];
    int count;
};

static void collect_source_files_recurse(const char *base, const char *rel_prefix, struct SourceFileList *out, int skip_tests) {
    DIR *d;
    struct dirent *ent;
    char full[PATH_MAX];
    char rel[PATH_MAX];

    d = opendir(base);
    if (!d) return;
    while ((ent = readdir(d)) != NULL && out->count < MAX_SOURCE_FILES) {
        if (ent->d_name[0] == '.') continue;
        join_path(full, sizeof(full), base, ent->d_name);
        if (rel_prefix[0]) {
            snprintf(rel, sizeof(rel), "%s/%s", rel_prefix, ent->d_name);
        } else {
            snprintf(rel, sizeof(rel), "%s", ent->d_name);
        }
        if (path_is_dir(full)) {
            if (!is_skip_dir(ent->d_name, skip_tests)) {
                collect_source_files_recurse(full, rel, out, skip_tests);
            }
        } else if (path_is_file(full)) {
            if (is_source_ext(get_extension(ent->d_name))) {
                strncpy(out->files[out->count], rel, PATH_MAX - 1);
                out->files[out->count][PATH_MAX - 1] = '\0';
                out->count++;
            }
        }
    }
    closedir(d);
}

static struct SourceFileList *collect_source_files(const char *repo, int skip_tests) {
    struct SourceFileList *list = (struct SourceFileList *)calloc(1, sizeof(struct SourceFileList));
    if (!list) return NULL;
    collect_source_files_recurse(repo, "", list, skip_tests);
    return list;
}

/* Scanner: rules 2, 6 - exposed secrets */
static int scan_exposed_secrets(const char *repo, struct ScanResult *result) {
    struct SourceFileList *files;
    int i;
    regex_t re_akia, re_password, re_privkey, re_secretkey;
    int have_akia, have_password, have_privkey, have_secretkey;

    have_akia = (regcomp(&re_akia, "AKIA[0-9A-Z]\\{16\\}", REG_NOSUB) == 0);
    have_password = (regcomp(&re_password, "password[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]", REG_NOSUB) == 0);
    have_privkey = (regcomp(&re_privkey, "-----BEGIN[[:space:]]+(RSA|DSA|EC|OPENSSH)?[[:space:]]*PRIVATE KEY-----", REG_EXTENDED | REG_NOSUB) == 0);
    have_secretkey = (regcomp(&re_secretkey, "secret_key[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]", REG_NOSUB) == 0);

    files = collect_source_files(repo, 1);
    if (!files) goto done;

    for (i = 0; i < files->count && result->finding_count < MAX_FINDINGS; i++) {
        char fullpath[PATH_MAX];
        FILE *f;
        char line[4096];
        int lineno = 0;

        join_path(fullpath, sizeof(fullpath), repo, files->files[i]);
        f = fopen(fullpath, "r");
        if (!f) continue;
        while (fgets(line, sizeof(line), f) && result->finding_count < MAX_FINDINGS) {
            lineno++;
            const char *desc = NULL;
            if (have_akia && regexec(&re_akia, line, 0, NULL, 0) == 0) {
                desc = "AWS access key pattern detected";
            } else if (have_password && regexec(&re_password, line, 0, NULL, 0) == 0) {
                desc = "hardcoded password detected";
            } else if (have_privkey && regexec(&re_privkey, line, 0, NULL, 0) == 0) {
                desc = "private key detected";
            } else if (have_secretkey && regexec(&re_secretkey, line, 0, NULL, 0) == 0) {
                desc = "hardcoded secret_key detected";
            }
            if (desc) {
                struct Finding *fd = &result->findings[result->finding_count++];
                strncpy(fd->file, files->files[i], sizeof(fd->file) - 1);
                fd->line = lineno;
                strncpy(fd->detail, desc, sizeof(fd->detail) - 1);
            }
        }
        fclose(f);
    }

done:
    free(files);
    if (have_akia) regfree(&re_akia);
    if (have_password) regfree(&re_password);
    if (have_privkey) regfree(&re_privkey);
    if (have_secretkey) regfree(&re_secretkey);
    return 0;
}

/* Scanner: rule 15 - container running as root */
static int scan_container_root(const char *repo, struct ScanResult *result) {
    /* Look for Dockerfile* in repo recursively */
    DIR *d;
    struct dirent *ent;
    char full[PATH_MAX];
    (void)repo;

    d = opendir(repo);
    if (!d) return 0;
    while ((ent = readdir(d)) != NULL && result->finding_count < MAX_FINDINGS) {
        if (strncmp(ent->d_name, "Dockerfile", 10) == 0) {
            join_path(full, sizeof(full), repo, ent->d_name);
            if (path_is_file(full)) {
                char *text = NULL;
                if (read_all_text(full, &text) == 0 && text) {
                    if (strstr(text, "FROM ") != NULL) {
                        /* Check for USER directive */
                        int has_user = 0;
                        char *line = text;
                        while (*line) {
                            /* Skip whitespace at start of line */
                            char *ls = line;
                            while (*ls == ' ' || *ls == '\t') ls++;
                            if (strncmp(ls, "USER ", 5) == 0 || strncmp(ls, "USER\t", 5) == 0) {
                                has_user = 1;
                                break;
                            }
                            line = strchr(line, '\n');
                            if (!line) break;
                            line++;
                        }
                        if (!has_user) {
                            struct Finding *fd = &result->findings[result->finding_count++];
                            strncpy(fd->file, ent->d_name, sizeof(fd->file) - 1);
                            fd->line = 0;
                            strncpy(fd->detail, "Dockerfile missing USER directive (runs as root)", sizeof(fd->detail) - 1);
                        }
                    }
                    free(text);
                }
            }
        }
    }
    closedir(d);
    return 0;
}

/* Scanner: rule 18 - exposed .env file */
static int scan_exposed_env(const char *repo, struct ScanResult *result) {
    char cmd[PATH_MAX + 64];
    int rc;
    snprintf(cmd, sizeof(cmd), "cd \"%s\" && git ls-files --error-unmatch .env 2>/dev/null", repo);
    rc = system(cmd);
    if (rc == 0) {
        struct Finding *fd = &result->findings[result->finding_count++];
        strncpy(fd->file, ".env", sizeof(fd->file) - 1);
        fd->line = 0;
        strncpy(fd->detail, ".env file is tracked in git", sizeof(fd->detail) - 1);
    }
    return 0;
}

/* Scanner: rule 42 - large files */
static int scan_large_files(const char *repo, struct ScanResult *result) {
    struct SourceFileList *files;
    int i;

    files = collect_source_files(repo, 0);
    if (!files) return 0;

    for (i = 0; i < files->count && result->finding_count < MAX_FINDINGS; i++) {
        char fullpath[PATH_MAX];
        FILE *f;
        int count = 0;
        char line[4096];

        join_path(fullpath, sizeof(fullpath), repo, files->files[i]);
        f = fopen(fullpath, "r");
        if (!f) continue;
        while (fgets(line, sizeof(line), f)) count++;
        fclose(f);
        if (count > 1000) {
            struct Finding *fd = &result->findings[result->finding_count++];
            strncpy(fd->file, files->files[i], sizeof(fd->file) - 1);
            fd->line = 0;
            snprintf(fd->detail, sizeof(fd->detail), "%d lines (threshold: 1000)", count);
        }
    }
    free(files);
    return 0;
}

/* Scanner: rule 48 - TODO density */
static int scan_todo_density(const char *repo, struct ScanResult *result) {
    struct SourceFileList *files;
    int i;
    regex_t re_todo;
    int have_re;

    have_re = (regcomp(&re_todo, "\\b(TODO|FIXME|HACK|XXX)\\b", REG_EXTENDED | REG_NOSUB | REG_ICASE) == 0);
    if (!have_re) return 0;

    files = collect_source_files(repo, 0);
    if (!files) { regfree(&re_todo); return 0; }

    for (i = 0; i < files->count && result->finding_count < MAX_FINDINGS; i++) {
        char fullpath[PATH_MAX];
        FILE *f;
        int count = 0;
        char line[4096];

        join_path(fullpath, sizeof(fullpath), repo, files->files[i]);
        f = fopen(fullpath, "r");
        if (!f) continue;
        while (fgets(line, sizeof(line), f)) {
            if (regexec(&re_todo, line, 0, NULL, 0) == 0) count++;
        }
        fclose(f);
        if (count >= 10) {
            struct Finding *fd = &result->findings[result->finding_count++];
            strncpy(fd->file, files->files[i], sizeof(fd->file) - 1);
            fd->line = 0;
            snprintf(fd->detail, sizeof(fd->detail), "%d TODO/FIXME/HACK comments", count);
        }
    }
    free(files);
    regfree(&re_todo);
    return 0;
}

/* Scanner: rule 142 - broken doc links */
static int scan_broken_doc_links(const char *repo, struct ScanResult *result) {
    /* Walk for *.md files and check relative links */
    struct SourceFileList mdfiles;
    DIR *d;
    struct dirent *ent;
    char full[PATH_MAX];
    regex_t re_link;
    int have_re;

    memset(&mdfiles, 0, sizeof(mdfiles));
    have_re = (regcomp(&re_link, "\\[([^]]+)\\]\\(([^)]+)\\)", REG_EXTENDED) == 0);
    if (!have_re) return 0;

    /* Simple approach: find .md files in repo top level */
    d = opendir(repo);
    if (!d) { regfree(&re_link); return 0; }
    while ((ent = readdir(d)) != NULL && mdfiles.count < MAX_SOURCE_FILES) {
        size_t nlen = strlen(ent->d_name);
        if (nlen > 3 && strcmp(ent->d_name + nlen - 3, ".md") == 0) {
            join_path(full, sizeof(full), repo, ent->d_name);
            if (path_is_file(full)) {
                strncpy(mdfiles.files[mdfiles.count], ent->d_name, PATH_MAX - 1);
                mdfiles.count++;
            }
        }
    }
    closedir(d);

    {
        int i;
        for (i = 0; i < mdfiles.count && result->finding_count < MAX_FINDINGS; i++) {
            FILE *f;
            char line[4096];
            int lineno = 0;
            char fpath[PATH_MAX];
            join_path(fpath, sizeof(fpath), repo, mdfiles.files[i]);
            f = fopen(fpath, "r");
            if (!f) continue;
            while (fgets(line, sizeof(line), f) && result->finding_count < MAX_FINDINGS) {
                regmatch_t matches[3];
                const char *search = line;
                lineno++;
                while (regexec(&re_link, search, 3, matches, 0) == 0) {
                    char target[512];
                    int tlen = (int)(matches[2].rm_eo - matches[2].rm_so);
                    if (tlen >= (int)sizeof(target)) tlen = (int)sizeof(target) - 1;
                    memcpy(target, search + matches[2].rm_so, (size_t)tlen);
                    target[tlen] = '\0';

                    /* Skip http, #, mailto */
                    if (strncmp(target, "http://", 7) != 0 && strncmp(target, "https://", 8) != 0 &&
                        target[0] != '#' && strncmp(target, "mailto:", 7) != 0) {
                        /* Strip #fragment and ?query */
                        char *hash = strchr(target, '#');
                        char *ques = strchr(target, '?');
                        if (hash) *hash = '\0';
                        if (ques) *ques = '\0';
                        if (target[0]) {
                            char link_full[PATH_MAX];
                            /* Resolve relative to the md file's directory */
                            char fdir[PATH_MAX];
                            strncpy(fdir, fpath, sizeof(fdir) - 1);
                            fdir[sizeof(fdir) - 1] = '\0';
                            {
                                char *last_sep = strrchr(fdir, '/');
                                if (!last_sep) last_sep = strrchr(fdir, '\\');
                                if (last_sep) *(last_sep + 1) = '\0';
                                else { fdir[0] = '.'; fdir[1] = '/'; fdir[2] = '\0'; }
                            }
                            join_path(link_full, sizeof(link_full), fdir, target);
                            if (!path_exists(link_full)) {
                                struct Finding *fd = &result->findings[result->finding_count++];
                                strncpy(fd->file, mdfiles.files[i], sizeof(fd->file) - 1);
                                fd->line = lineno;
                                snprintf(fd->detail, sizeof(fd->detail), "broken link to %s", target);
                            }
                        }
                    }
                    search += matches[0].rm_eo;
                }
            }
            fclose(f);
        }
    }

    regfree(&re_link);
    return 0;
}

/* Scanner: rule 148 - stale README */
static int scan_stale_readme(const char *repo, struct ScanResult *result) {
    char readme_path[PATH_MAX];
    struct stat readme_st;
    double readme_mtime, latest_source;
    struct SourceFileList *files;
    int i;
    double days_stale;

    join_path(readme_path, sizeof(readme_path), repo, "README.md");
    if (stat(readme_path, &readme_st) != 0) {
        struct Finding *fd = &result->findings[result->finding_count++];
        strncpy(fd->file, "README.md", sizeof(fd->file) - 1);
        fd->line = 0;
        strncpy(fd->detail, "README.md does not exist", sizeof(fd->detail) - 1);
        return 0;
    }
    readme_mtime = (double)readme_st.st_mtime;

    files = collect_source_files(repo, 0);
    if (!files) return 0;

    latest_source = 0.0;
    for (i = 0; i < files->count; i++) {
        char fullpath[PATH_MAX];
        struct stat st;
        join_path(fullpath, sizeof(fullpath), repo, files->files[i]);
        if (stat(fullpath, &st) == 0) {
            double mt = (double)st.st_mtime;
            if (mt > latest_source) latest_source = mt;
        }
    }
    free(files);

    if (latest_source <= 0) return 0;
    days_stale = (latest_source - readme_mtime) / 86400.0;
    if (days_stale > 90) {
        struct Finding *fd = &result->findings[result->finding_count++];
        strncpy(fd->file, "README.md", sizeof(fd->file) - 1);
        fd->line = 0;
        snprintf(fd->detail, sizeof(fd->detail), "README.md is %d days behind latest source change", (int)days_stale);
    }
    return 0;
}

/* Dispatch scanner for a rule */
static void run_builtin_scanner(const char *repo, int rule_id, struct ScanResult *result) {
    switch (rule_id) {
        case 2: case 6:
            scan_exposed_secrets(repo, result);
            break;
        case 15:
            scan_container_root(repo, result);
            break;
        case 18:
            scan_exposed_env(repo, result);
            break;
        case 42:
            scan_large_files(repo, result);
            break;
        case 48:
            scan_todo_density(repo, result);
            break;
        case 142:
            scan_broken_doc_links(repo, result);
            break;
        case 148:
            scan_stale_readme(repo, result);
            break;
        default:
            break;
    }
}

/* Scan a single rule */
static void scan_rule(const char *repo, const struct MaintenanceRule *rule, struct ScanResult *out) {
    memset(out, 0, sizeof(*out));
    out->rule_id = rule->id;
    strncpy(out->title, rule->title, sizeof(out->title) - 1);
    strncpy(out->category, rule->category, sizeof(out->category) - 1);

    if (rule->has_builtin_scanner) {
        run_builtin_scanner(repo, rule->id, out);
        if (out->finding_count > 0) {
            strcpy(out->status, "fail");
        } else {
            strcpy(out->status, "pass");
        }
    } else {
        strcpy(out->status, "skip");
        strcpy(out->reason, "no built-in scanner");
        if (rule->external_tool) {
            strncat(out->reason, "; try: ", sizeof(out->reason) - strlen(out->reason) - 1);
            strncat(out->reason, rule->external_tool, sizeof(out->reason) - strlen(out->reason) - 1);
        }
    }
}

/* Filter rules by category list and/or rule ID list */
struct MaintFilterArgs {
    const char *categories[16];
    int category_count;
    int rule_ids[64];
    int rule_id_count;
};

static int rule_matches_filter(const struct MaintenanceRule *rule, const struct MaintFilterArgs *filter) {
    int i;
    int cat_match = 1;
    int id_match = 1;

    if (filter->category_count > 0) {
        cat_match = 0;
        for (i = 0; i < filter->category_count; i++) {
            if (strcmp(rule->category, filter->categories[i]) == 0) {
                cat_match = 1;
                break;
            }
        }
    }
    if (filter->rule_id_count > 0) {
        id_match = 0;
        for (i = 0; i < filter->rule_id_count; i++) {
            if (rule->id == filter->rule_ids[i]) {
                id_match = 1;
                break;
            }
        }
    }
    return cat_match && id_match;
}

/* Default maintain config */
static const char *DEFAULT_MAINTAIN_CONFIG =
    "# tickets/maintain.yaml\n"
    "# Enable/disable categories and configure external tools for mt maintain scan.\n"
    "\n"
    "# Global settings\n"
    "settings:\n"
    "  log_file: tickets/maintain.log\n"
    "  timeout: 60\n"
    "  enabled: true\n"
    "\n"
    "# Per-category tool configuration\n"
    "# Set enabled: true and provide the command for your stack.\n"
    "# Use {repo} as placeholder for the repository root path.\n"
    "# Optional per-tool fields:\n"
    "#   timeout: 120          # per-tool timeout in seconds (overrides global)\n"
    "#   fix_command: ...      # auto-fix command (used with mt maintain scan --fix)\n"
    "\n"
    "security:\n"
    "  cve_scanner:\n"
    "    enabled: false\n"
    "    # command: pip-audit --format=json\n"
    "    # command: npm audit --json\n"
    "    # command: cargo audit --json\n"
    "    # command: osv-scanner --format=json -r {repo}\n"
    "  secret_scanner:\n"
    "    enabled: false\n"
    "    # command: gitleaks detect --source={repo} --report-format=json --no-git\n"
    "  ssl_check:\n"
    "    enabled: false\n"
    "    # command: openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -enddate\n"
    "\n"
    "deps:\n"
    "  outdated_check:\n"
    "    enabled: false\n"
    "    # command: pip list --outdated --format=json\n"
    "    # command: npm outdated --json\n"
    "    # command: cargo outdated --format=json\n"
    "  license_check:\n"
    "    enabled: false\n"
    "    # command: pip-licenses --format=json\n"
    "    # command: license-checker --json\n"
    "  unused_deps:\n"
    "    enabled: false\n"
    "    # command: depcheck --json\n"
    "    # command: vulture {repo}\n"
    "\n"
    "code_health:\n"
    "  complexity:\n"
    "    enabled: false\n"
    "    # command: radon cc {repo} -a -j\n"
    "  linter:\n"
    "    enabled: false\n"
    "    # command: pylint {repo} --output-format=json\n"
    "    # command: eslint {repo}/src --format=json\n"
    "    # command: cargo clippy --message-format=json\n"
    "    # fix_command: cargo clippy --fix --allow-dirty\n"
    "  formatter_check:\n"
    "    enabled: false\n"
    "    # command: black --check {repo} --quiet\n"
    "    # fix_command: black {repo}\n"
    "    # command: cargo fmt --check\n"
    "    # fix_command: cargo fmt\n"
    "  type_check:\n"
    "    enabled: false\n"
    "    # command: mypy {repo} --no-error-summary\n"
    "\n"
    "performance:\n"
    "  profiler:\n"
    "    enabled: false\n"
    "  bundle_size:\n"
    "    enabled: false\n"
    "\n"
    "database:\n"
    "  migration_check:\n"
    "    enabled: false\n"
    "  query_analyzer:\n"
    "    enabled: false\n"
    "\n"
    "infrastructure:\n"
    "  container_scan:\n"
    "    enabled: false\n"
    "  k8s_health:\n"
    "    enabled: false\n"
    "  terraform_drift:\n"
    "    enabled: false\n"
    "\n"
    "observability:\n"
    "  prometheus_check:\n"
    "    enabled: false\n"
    "  alert_check:\n"
    "    enabled: false\n"
    "\n"
    "testing:\n"
    "  coverage:\n"
    "    enabled: false\n"
    "    # command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout\n"
    "    # command: nyc --reporter=json npm test\n"
    "  test_runner:\n"
    "    enabled: false\n"
    "    # command: pytest {repo} --tb=short -q\n"
    "\n"
    "documentation:\n"
    "  link_checker:\n"
    "    enabled: false\n"
    "    # command: markdown-link-check {repo}/docs/**/*.md --json\n"
    "  openapi_diff:\n"
    "    enabled: false\n";

/* --- Maintain subcommands --- */

static int cmd_maintain_init_config(int argc, char **argv, const char *repo_root) {
    char tickets_path[PATH_MAX];
    char config_path[PATH_MAX];
    int force = 0;
    int detect = 0;
    int i;

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--force") == 0) force = 1;
        else if (strcmp(argv[i], "--detect") == 0) detect = 1;
    }

    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    make_dir_if_missing(tickets_path);
    join_path(config_path, sizeof(config_path), tickets_path, "maintain.yaml");

    if (path_exists(config_path) && !force) {
        fprintf(stderr, "config already exists: %s\n", config_path);
        fprintf(stderr, "use --force to overwrite\n");
        return 1;
    }

    if (detect) {
        /* Detect project stack and generate tailored config */
        char pyproject[PATH_MAX], pkg_json[PATH_MAX], cargo_toml[PATH_MAX], go_mod[PATH_MAX];
        int has_python = 0, has_node = 0, has_rust = 0, has_go = 0;
        FILE *f;
        char detected_list[256] = "";

        join_path(pyproject, sizeof(pyproject), repo_root, "pyproject.toml");
        if (path_exists(pyproject)) has_python = 1;
        else {
            char setup_py[PATH_MAX], req_txt[PATH_MAX];
            join_path(setup_py, sizeof(setup_py), repo_root, "setup.py");
            join_path(req_txt, sizeof(req_txt), repo_root, "requirements.txt");
            if (path_exists(setup_py) || path_exists(req_txt)) has_python = 1;
        }
        join_path(pkg_json, sizeof(pkg_json), repo_root, "package.json");
        if (path_exists(pkg_json)) has_node = 1;
        join_path(cargo_toml, sizeof(cargo_toml), repo_root, "Cargo.toml");
        if (path_exists(cargo_toml)) has_rust = 1;
        join_path(go_mod, sizeof(go_mod), repo_root, "go.mod");
        if (path_exists(go_mod)) has_go = 1;

        if (!has_python && !has_node && !has_rust && !has_go)
            strcpy(detected_list, "none");
        else {
            if (has_go) { if (detected_list[0]) strcat(detected_list, ", "); strcat(detected_list, "go"); }
            if (has_node) { if (detected_list[0]) strcat(detected_list, ", "); strcat(detected_list, "node"); }
            if (has_python) { if (detected_list[0]) strcat(detected_list, ", "); strcat(detected_list, "python"); }
            if (has_rust) { if (detected_list[0]) strcat(detected_list, ", "); strcat(detected_list, "rust"); }
        }

        fprintf(stderr, "detected stacks: %s\n", detected_list);

        f = fopen(config_path, "w");
        if (!f) { fprintf(stderr, "failed to write %s\n", config_path); return 1; }
        fprintf(f, "# tickets/maintain.yaml\n# Auto-generated by mt maintain init-config --detect\n# Detected stacks: %s\n\n", detected_list);
        fprintf(f, "settings:\n  log_file: tickets/maintain.log\n  timeout: 60\n  enabled: true\n\n");

        /* Write stack-specific config */
        if (has_python) {
            fprintf(f, "security:\n  cve_scanner:\n    enabled: true\n    command: pip-audit --format=json\n  secret_scanner:\n    enabled: true\n    command: gitleaks detect --source={repo} --report-format=json --no-git\n\n");
            fprintf(f, "deps:\n  outdated_check:\n    enabled: true\n    command: pip list --outdated --format=json\n  license_check:\n    enabled: true\n    command: pip-licenses --format=json\n\n");
            fprintf(f, "code_health:\n  linter:\n    enabled: true\n    command: pylint {repo} --output-format=json --exit-zero\n  formatter_check:\n    enabled: true\n    command: black --check {repo} --quiet\n  type_check:\n    enabled: true\n    command: mypy {repo} --no-error-summary\n\n");
            fprintf(f, "testing:\n  coverage:\n    enabled: true\n    command: coverage run -m pytest {repo} -q && coverage json -o /dev/stdout\n  test_runner:\n    enabled: true\n    command: pytest {repo} --tb=short -q\n\n");
        }

        fprintf(f, "documentation:\n  link_checker:\n    enabled: false\n    # command: markdown-link-check {repo}/docs/**/*.md --json\n\n");
        fclose(f);
    } else {
        if (write_text_file(config_path, DEFAULT_MAINTAIN_CONFIG) != 0) return 1;
    }

    printf("%s\n", config_path);
    return 0;
}

/* Simple YAML key-value parser for maintain.yaml */
struct MaintainConfig {
    int loaded;
    char log_file[PATH_MAX];
    /* We parse enabled tool names and commands for doctor */
    struct {
        char name[64];
        char binary[128];
    } tools[32];
    int tool_count;
};

static void load_maintain_config(const char *repo_root, struct MaintainConfig *cfg) {
    char tickets_path[PATH_MAX];
    char config_path[PATH_MAX];
    char *text = NULL;
    char *line_ptr;
    char *saveptr = NULL;
    char current_tool[64] = "";
    int in_tool = 0;
    int tool_enabled = 0;
    char tool_command[512] = "";

    memset(cfg, 0, sizeof(*cfg));
    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    join_path(config_path, sizeof(config_path), tickets_path, "maintain.yaml");

    if (read_all_text(config_path, &text) != 0 || !text) return;
    cfg->loaded = 1;

    /* Extract log_file from settings */
    {
        char *lf = strstr(text, "log_file:");
        if (lf) {
            char val[PATH_MAX];
            if (sscanf(lf, "log_file: %s", val) == 1) {
                strncpy(cfg->log_file, val, sizeof(cfg->log_file) - 1);
            }
        }
    }

    /* Parse tool blocks - we look for patterns like:
       toolname:
         enabled: true
         command: something */
    line_ptr = strtok_r(text, "\n", &saveptr);
    while (line_ptr) {
        char trimmed[512];
        strncpy(trimmed, line_ptr, sizeof(trimmed) - 1);
        trimmed[sizeof(trimmed) - 1] = '\0';

        /* Count leading spaces */
        int indent = 0;
        while (trimmed[indent] == ' ') indent++;

        char *content = trimmed + indent;
        if (content[0] == '#' || content[0] == '\0') {
            line_ptr = strtok_r(NULL, "\n", &saveptr);
            continue;
        }

        if (indent == 4 && strchr(content, ':') && content[strlen(content)-1] == ':') {
            /* Save previous tool if it was complete */
            if (in_tool && tool_enabled && tool_command[0] && cfg->tool_count < 32) {
                strncpy(cfg->tools[cfg->tool_count].name, current_tool, 63);
                /* Extract binary from command (first word) */
                char bin[128];
                strncpy(bin, tool_command, sizeof(bin) - 1);
                bin[sizeof(bin) - 1] = '\0';
                {
                    char *sp = strchr(bin, ' ');
                    if (sp) *sp = '\0';
                }
                strncpy(cfg->tools[cfg->tool_count].binary, bin, 127);
                cfg->tool_count++;
            }
            /* Start new tool */
            {
                char *colon = strchr(content, ':');
                if (colon) {
                    size_t nlen = (size_t)(colon - content);
                    if (nlen >= sizeof(current_tool)) nlen = sizeof(current_tool) - 1;
                    memcpy(current_tool, content, nlen);
                    current_tool[nlen] = '\0';
                }
            }
            in_tool = 1;
            tool_enabled = 0;
            tool_command[0] = '\0';
        } else if (indent >= 6 && in_tool) {
            if (strncmp(content, "enabled:", 8) == 0) {
                char val[32];
                if (sscanf(content, "enabled: %31s", val) == 1) {
                    tool_enabled = (strcmp(val, "true") == 0);
                }
            } else if (strncmp(content, "command:", 8) == 0) {
                char *val = content + 8;
                while (*val == ' ') val++;
                strncpy(tool_command, val, sizeof(tool_command) - 1);
            }
        } else if (indent < 4) {
            /* Left a tool section */
            if (in_tool && tool_enabled && tool_command[0] && cfg->tool_count < 32) {
                strncpy(cfg->tools[cfg->tool_count].name, current_tool, 63);
                char bin[128];
                strncpy(bin, tool_command, sizeof(bin) - 1);
                bin[sizeof(bin) - 1] = '\0';
                {
                    char *sp = strchr(bin, ' ');
                    if (sp) *sp = '\0';
                }
                strncpy(cfg->tools[cfg->tool_count].binary, bin, 127);
                cfg->tool_count++;
            }
            in_tool = 0;
            tool_enabled = 0;
            tool_command[0] = '\0';
        }

        line_ptr = strtok_r(NULL, "\n", &saveptr);
    }

    /* Handle last tool */
    if (in_tool && tool_enabled && tool_command[0] && cfg->tool_count < 32) {
        strncpy(cfg->tools[cfg->tool_count].name, current_tool, 63);
        char bin[128];
        strncpy(bin, tool_command, sizeof(bin) - 1);
        bin[sizeof(bin) - 1] = '\0';
        {
            char *sp = strchr(bin, ' ');
            if (sp) *sp = '\0';
        }
        strncpy(cfg->tools[cfg->tool_count].binary, bin, 127);
        cfg->tool_count++;
    }

    free(text);
}

static int cmd_maintain_doctor(int argc, char **argv, const char *repo_root) {
    struct MaintainConfig cfg;
    int i, ok_count = 0, fail_count = 0;
    char found[PATH_MAX];

    (void)argc; (void)argv;
    load_maintain_config(repo_root, &cfg);
    if (!cfg.loaded) {
        fprintf(stderr, "no tickets/maintain.yaml found. run: mt maintain init-config\n");
        return 2;
    }

    if (cfg.tool_count == 0) {
        fprintf(stderr, "no external tools enabled in maintain.yaml\n");
        return 0;
    }

    for (i = 0; i < cfg.tool_count; i++) {
        if (find_in_path(cfg.tools[i].binary, found, sizeof(found))) {
            printf("[OK]    %-20s %s -> %s\n", cfg.tools[i].name, cfg.tools[i].binary, found);
            ok_count++;
        } else {
            printf("[MISS]  %-20s %s -- not found on PATH\n", cfg.tools[i].name, cfg.tools[i].binary);
            fail_count++;
        }
    }

    fprintf(stderr, "\n%d tool(s) checked: %d available, %d missing\n", ok_count + fail_count, ok_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}

static int cmd_maintain_list(int argc, char **argv, const char *repo_root) {
    struct MaintFilterArgs filter;
    int i, j, found = 0;

    (void)repo_root;
    memset(&filter, 0, sizeof(filter));

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--category") == 0 && i + 1 < argc) {
            if (filter.category_count < 16)
                filter.categories[filter.category_count++] = argv[++i];
        } else if (strcmp(argv[i], "--rule") == 0 && i + 1 < argc) {
            if (filter.rule_id_count < 64)
                filter.rule_ids[filter.rule_id_count++] = atoi(argv[++i]);
        }
    }

    for (j = 0; j < MAINT_RULE_COUNT; j++) {
        const struct MaintenanceRule *rule = &MAINT_RULES[j];
        if (!rule_matches_filter(rule, &filter)) continue;
        found++;
        printf("  %3d  [%-16s] %s  (%s)\n", rule->id, rule->category, rule->title,
               rule->has_builtin_scanner ? "built-in" : "external");
        printf("        detection: %s\n", rule->detection);
        if (rule->external_tool) {
            printf("        tool: %s\n", rule->external_tool);
        }
    }

    if (!found) {
        fprintf(stderr, "no rules match the given filters.\n");
        return 1;
    }
    return 0;
}

static int cmd_maintain_scan(int argc, char **argv, const char *repo_root) {
    struct MaintFilterArgs filter;
    int i, j, found = 0;
    int use_json = 0;
    int use_all = 0;
    const char *profile = NULL;
    int fail_count = 0, pass_count = 0, skip_count = 0;
    struct ScanResult *results;
    int result_count = 0;
    char last_scan_path[PATH_MAX];

    memset(&filter, 0, sizeof(filter));

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--category") == 0 && i + 1 < argc) {
            if (filter.category_count < 16)
                filter.categories[filter.category_count++] = argv[++i];
        } else if (strcmp(argv[i], "--rule") == 0 && i + 1 < argc) {
            if (filter.rule_id_count < 64)
                filter.rule_ids[filter.rule_id_count++] = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
            i++;
            if (strcmp(argv[i], "json") == 0) use_json = 1;
        } else if (strcmp(argv[i], "--all") == 0) {
            use_all = 1;
        } else if (strcmp(argv[i], "--profile") == 0 && i + 1 < argc) {
            profile = argv[++i];
        } else if (strcmp(argv[i], "--diff") == 0 || strcmp(argv[i], "--fix") == 0) {
            /* Accepted but simplified implementation */
        }
    }

    /* Apply profile */
    if (profile) {
        if (strcmp(profile, "ci") == 0) {
            static const char *ci_cats[] = {"security", "code-health", "testing"};
            for (i = 0; i < 3; i++) {
                int dup = 0;
                for (j = 0; j < filter.category_count; j++) {
                    if (strcmp(filter.categories[j], ci_cats[i]) == 0) { dup = 1; break; }
                }
                if (!dup && filter.category_count < 16)
                    filter.categories[filter.category_count++] = ci_cats[i];
            }
        } else if (strcmp(profile, "nightly") == 0) {
            use_all = 1;
        }
    }

    if (use_all) {
        filter.category_count = NUM_MAINT_CATEGORIES;
        for (i = 0; i < NUM_MAINT_CATEGORIES; i++)
            filter.categories[i] = MAINTENANCE_CATEGORIES[i];
    }

    if (filter.category_count == 0 && filter.rule_id_count == 0) {
        fprintf(stderr, "error: --category, --rule, --all, or --profile required for scanning.\n");
        fprintf(stderr, "hint: mt maintain list  (to browse rules first)\n");
        return 2;
    }

    results = (struct ScanResult *)calloc(MAINT_RULE_COUNT, sizeof(struct ScanResult));
    if (!results) return 1;

    for (j = 0; j < MAINT_RULE_COUNT; j++) {
        const struct MaintenanceRule *rule = &MAINT_RULES[j];
        if (!rule_matches_filter(rule, &filter)) continue;
        scan_rule(repo_root, rule, &results[result_count]);
        result_count++;
    }

    /* Save results to maintain.last.json */
    {
        char tickets_path[PATH_MAX];
        join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
        join_path(last_scan_path, sizeof(last_scan_path), tickets_path, "maintain.last.json");
        make_dir_if_missing(tickets_path);
        {
            FILE *f = fopen(last_scan_path, "w");
            if (f) {
                fprintf(f, "[\n");
                for (i = 0; i < result_count; i++) {
                    struct ScanResult *r = &results[i];
                    fprintf(f, "  {\"rule_id\": %d, \"status\": \"%s\", \"title\": \"", r->rule_id, r->status);
                    /* Escape title for JSON */
                    {
                        const char *p = r->title;
                        while (*p) {
                            if (*p == '"' || *p == '\\') fputc('\\', f);
                            fputc(*p, f);
                            p++;
                        }
                    }
                    fprintf(f, "\", \"category\": \"%s\", \"findings\": [", r->category);
                    for (j = 0; j < r->finding_count; j++) {
                        struct Finding *fd = &r->findings[j];
                        if (j > 0) fprintf(f, ", ");
                        fprintf(f, "{\"file\": \"%s\", \"line\": %d, \"detail\": \"", fd->file, fd->line);
                        {
                            const char *p = fd->detail;
                            while (*p) {
                                if (*p == '"' || *p == '\\') fputc('\\', f);
                                fputc(*p, f);
                                p++;
                            }
                        }
                        fprintf(f, "\"}");
                    }
                    fprintf(f, "]");
                    if (strcmp(r->status, "skip") == 0 && r->reason[0]) {
                        fprintf(f, ", \"reason\": \"");
                        {
                            const char *p = r->reason;
                            while (*p) {
                                if (*p == '"' || *p == '\\') fputc('\\', f);
                                fputc(*p, f);
                                p++;
                            }
                        }
                        fprintf(f, "\"");
                    }
                    fprintf(f, "}%s\n", i < result_count - 1 ? "," : "");
                }
                fprintf(f, "]\n");
                fclose(f);
            }
        }
    }

    /* Output */
    if (use_json) {
        printf("[\n");
        for (i = 0; i < result_count; i++) {
            struct ScanResult *r = &results[i];
            printf("  {\"rule_id\": %d, \"status\": \"%s\", \"title\": \"", r->rule_id, r->status);
            {
                const char *p = r->title;
                while (*p) {
                    if (*p == '"' || *p == '\\') { putchar('\\'); }
                    putchar(*p);
                    p++;
                }
            }
            printf("\", \"category\": \"%s\", \"findings\": [", r->category);
            for (j = 0; j < r->finding_count; j++) {
                struct Finding *fd = &r->findings[j];
                if (j > 0) printf(", ");
                printf("{\"file\": \"%s\", \"line\": %d, \"detail\": \"", fd->file, fd->line);
                {
                    const char *p = fd->detail;
                    while (*p) {
                        if (*p == '"' || *p == '\\') putchar('\\');
                        putchar(*p);
                        p++;
                    }
                }
                printf("\"}");
            }
            printf("]");
            if (strcmp(r->status, "skip") == 0 && r->reason[0]) {
                printf(", \"reason\": \"");
                {
                    const char *p = r->reason;
                    while (*p) {
                        if (*p == '"' || *p == '\\') putchar('\\');
                        putchar(*p);
                        p++;
                    }
                }
                printf("\"");
            }
            printf("}%s\n", i < result_count - 1 ? "," : "");
        }
        printf("]\n");
    } else {
        for (i = 0; i < result_count; i++) {
            struct ScanResult *r = &results[i];
            if (strcmp(r->status, "fail") == 0) {
                printf("[FAIL]  rule %3d: %s -- %d finding(s)\n", r->rule_id, r->title, r->finding_count);
                for (j = 0; j < r->finding_count; j++) {
                    struct Finding *fd = &r->findings[j];
                    if (fd->line) {
                        printf("        %s:%d: %s\n", fd->file, fd->line, fd->detail);
                    } else {
                        printf("        %s: %s\n", fd->file, fd->detail);
                    }
                }
            } else if (strcmp(r->status, "pass") == 0) {
                printf("[PASS]  rule %3d: %s -- ok\n", r->rule_id, r->title);
            } else {
                printf("[SKIP]  rule %3d: %s -- %s\n", r->rule_id, r->title,
                       r->reason[0] ? r->reason : "no built-in scanner");
            }
        }
    }

    for (i = 0; i < result_count; i++) {
        if (strcmp(results[i].status, "fail") == 0) fail_count++;
        else if (strcmp(results[i].status, "pass") == 0) pass_count++;
        else skip_count++;
        found++;
    }

    fprintf(stderr, "\n%d rule(s) scanned: %d failed, %d passed, %d skipped\n",
            result_count, fail_count, pass_count, skip_count);

    free(results);
    return fail_count > 0 ? 1 : 0;
}

static int cmd_maintain_create(int argc, char **argv, const char *repo_root) {
    struct MaintFilterArgs filter;
    int i, j;
    int dry_run = 0, skip_scan = 0, use_all = 0;
    const char *priority_override = NULL;
    const char *owner_override = NULL;
    int created = 0, skipped_dedup = 0, skipped_pass = 0;
    char tickets_path[PATH_MAX];
    struct ScanResult *scan_results = NULL;
    int scan_count = 0;

    memset(&filter, 0, sizeof(filter));

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--category") == 0 && i + 1 < argc) {
            if (filter.category_count < 16)
                filter.categories[filter.category_count++] = argv[++i];
        } else if (strcmp(argv[i], "--rule") == 0 && i + 1 < argc) {
            if (filter.rule_id_count < 64)
                filter.rule_ids[filter.rule_id_count++] = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = 1;
        } else if (strcmp(argv[i], "--skip-scan") == 0) {
            skip_scan = 1;
        } else if (strcmp(argv[i], "--all") == 0) {
            use_all = 1;
        } else if (strcmp(argv[i], "--priority") == 0 && i + 1 < argc) {
            priority_override = argv[++i];
        } else if (strcmp(argv[i], "--owner") == 0 && i + 1 < argc) {
            owner_override = argv[++i];
        }
    }

    if (use_all) {
        filter.category_count = NUM_MAINT_CATEGORIES;
        for (i = 0; i < NUM_MAINT_CATEGORIES; i++)
            filter.categories[i] = MAINTENANCE_CATEGORIES[i];
    }

    if (filter.category_count == 0 && filter.rule_id_count == 0) {
        fprintf(stderr, "error: --category, --rule, or --all required.\n");
        fprintf(stderr, "hint: mt maintain scan --category <cat>  (to scan first)\n");
        return 2;
    }

    join_path(tickets_path, sizeof(tickets_path), repo_root, "tickets");
    make_dir_if_missing(tickets_path);

    /* Scan unless skip_scan */
    if (!skip_scan) {
        scan_results = (struct ScanResult *)calloc(MAINT_RULE_COUNT, sizeof(struct ScanResult));
        if (!scan_results) return 1;
        for (j = 0; j < MAINT_RULE_COUNT; j++) {
            if (!rule_matches_filter(&MAINT_RULES[j], &filter)) continue;
            scan_rule(repo_root, &MAINT_RULES[j], &scan_results[scan_count]);
            scan_count++;
        }
    }

    /* Collect existing maint tags for deduplication */
    {
        DIR *d;
        struct dirent *ent;
        char existing_tags[256][32]; /* maint-rule-NNN tags */
        int existing_tag_count = 0;
        int rule_idx;

        d = opendir(tickets_path);
        if (d) {
            while ((ent = readdir(d)) != NULL) {
                int n = 0;
                char ticket_file[PATH_MAX];
                char *text = NULL;
                if (!parse_ticket_filename_number(ent->d_name, &n)) continue;
                join_path(ticket_file, sizeof(ticket_file), tickets_path, ent->d_name);
                if (read_all_text(ticket_file, &text) == 0 && text) {
                    /* Check if status is not "done" and has maint-rule- tags */
                    char *fm = NULL, *body = NULL;
                    if (split_ticket_sections(text, &fm, &body) == 0) {
                        /* Check status */
                        int is_done = 0;
                        char *status_line = strstr(fm, "status:");
                        if (status_line) {
                            if (strstr(status_line, "done")) is_done = 1;
                        }
                        if (!is_done) {
                            /* Extract maint-rule tags */
                            char *tag_pos = strstr(fm, "tags:");
                            if (tag_pos) {
                                char *mr = tag_pos;
                                while ((mr = strstr(mr, "maint-rule-")) != NULL && existing_tag_count < 256) {
                                    /* Extract the tag */
                                    char tag[32];
                                    int tlen = 0;
                                    const char *tp = mr;
                                    while (*tp && *tp != ',' && *tp != ']' && *tp != '\n' && *tp != ' ' && tlen < 31) {
                                        tag[tlen++] = *tp++;
                                    }
                                    tag[tlen] = '\0';
                                    strncpy(existing_tags[existing_tag_count], tag, 31);
                                    existing_tags[existing_tag_count][31] = '\0';
                                    existing_tag_count++;
                                    mr++;
                                }
                            }
                        }
                        free(fm);
                        free(body);
                    }
                    free(text);
                }
            }
            closedir(d);
        }

        /* Now iterate rules and create tickets */
        rule_idx = 0;
        for (j = 0; j < MAINT_RULE_COUNT; j++) {
            const struct MaintenanceRule *rule = &MAINT_RULES[j];
            char maint_tag[32];
            int is_dup = 0;
            struct ScanResult *scan = NULL;
            const char *priority;

            if (!rule_matches_filter(rule, &filter)) continue;

            snprintf(maint_tag, sizeof(maint_tag), "maint-rule-%d", rule->id);

            /* Check dedup */
            for (i = 0; i < existing_tag_count; i++) {
                if (strcmp(existing_tags[i], maint_tag) == 0) { is_dup = 1; break; }
            }
            if (is_dup) { skipped_dedup++; rule_idx++; continue; }

            /* Find scan result if scan was done */
            if (scan_results && rule_idx < scan_count) {
                scan = &scan_results[rule_idx];
            }

            if (scan && strcmp(scan->status, "pass") == 0) {
                skipped_pass++;
                rule_idx++;
                continue;
            }

            if (dry_run) {
                const char *label = (scan && strcmp(scan->status, "fail") == 0) ? "findings" : "suggestion";
                printf("[dry-run] [%s] [MAINT-%03d] %s\n", label, rule->id, rule->title);
                created++;
                rule_idx++;
                continue;
            }

            /* Create actual ticket */
            {
                int tracked = 0, scanned = 0, has_tracked = 0, next_n;
                char ticket_path[PATH_MAX];
                char created_ts[32], updated_ts[32];
                FILE *f;

                has_tracked = read_last_ticket_number_file(tickets_path, &tracked);
                scanned = scan_ticket_max_all_buckets(tickets_path);
                next_n = (has_tracked && tracked > scanned ? tracked : scanned) + 1;

                snprintf(ticket_path, sizeof(ticket_path), "%s%cT-%06d.md", tickets_path, PATH_SEP, next_n);
                f = fopen(ticket_path, "w");
                if (!f) { rule_idx++; continue; }

                now_utc_iso(created_ts, sizeof(created_ts));
                now_utc_iso(updated_ts, sizeof(updated_ts));

                priority = priority_override ? priority_override : rule->default_priority;

                fprintf(f,
                    "---\n"
                    "id: T-%06d\n"
                    "title: [MAINT-%03d] %s\n"
                    "status: ready\n"
                    "priority: %s\n"
                    "type: %s\n"
                    "effort: %s\n"
                    "labels: [%s, %s, auto-maintenance]\n"
                    "tags: [maint-rule-%d, maint-cat-%s]\n"
                    "owner: %s\n"
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
                    "---\n\n",
                    next_n, rule->id, rule->title,
                    priority, rule->default_type, rule->default_effort,
                    rule->labels[0], rule->labels[1],
                    rule->id, rule->category,
                    owner_override ? owner_override : "null",
                    created_ts, updated_ts);

                /* Write body */
                if (scan && strcmp(scan->status, "fail") == 0 && scan->finding_count > 0) {
                    int fi;
                    fprintf(f, "## Goal\nFix detected issue: %s\n\n## Findings\n", rule->title);
                    for (fi = 0; fi < scan->finding_count; fi++) {
                        struct Finding *fd = &scan->findings[fi];
                        if (fd->line) {
                            fprintf(f, "- `%s` (line %d): %s\n", fd->file, fd->line, fd->detail);
                        } else {
                            fprintf(f, "- `%s` (file): %s\n", fd->file, fd->detail);
                        }
                    }
                    fprintf(f, "\n## Recommended Action\n%s\n", rule->action);
                    fprintf(f, "\n## Acceptance Criteria\n- [ ] Address all findings listed above\n- [ ] Verify fix passes CI\n");
                    fprintf(f, "\n## Notes\nAuto-detected by `mt maintain scan` (rule %d, category: %s)\n", rule->id, rule->category);
                } else {
                    fprintf(f, "## Goal\nInvestigate and remediate: %s\n\n", rule->title);
                    fprintf(f, "## Detection Heuristic\n%s\n", rule->detection);
                    if (rule->external_tool) {
                        fprintf(f, "\n## External Tool\n```\n%s\n```\n", rule->external_tool);
                    }
                    fprintf(f, "\n## Recommended Action\n%s\n", rule->action);
                    fprintf(f, "\n## Acceptance Criteria\n- [ ] Run detection heuristic against codebase\n- [ ] Fix any issues found, or close ticket if none exist\n- [ ] Verify fix passes CI\n");
                    fprintf(f, "\n## Notes\nAuto-generated by `mt maintain create` (rule %d, category: %s)\n", rule->id, rule->category);
                }

                fclose(f);
                write_last_ticket_number_file(tickets_path, next_n);
                printf("%s\n", ticket_path);
                created++;
            }
            rule_idx++;
        }
    }

    if (scan_results) free(scan_results);

    fprintf(stderr, "%d ticket(s) %screated, %d skipped (duplicates), %d skipped (scan passed)\n",
            created, dry_run ? "would be " : "", skipped_dedup, skipped_pass);
    return 0;
}

/* Detect and dispatch maintain subcommands */
static int should_handle_native_maintain(int argc, char **argv) {
    if (argc < 3) return 0;
    return strcmp(argv[1], "maintain") == 0;
}

static int cmd_maintain_native(int argc, char **argv) {
    char repo_root[PATH_MAX];
    const char *subcmd;

    if (argc < 3) {
        fprintf(stderr, "usage: mt maintain <subcommand> [options]\n");
        fprintf(stderr, "subcommands: init-config, doctor, list, scan, create\n");
        return 2;
    }

    if (getcwd(repo_root, sizeof(repo_root)) == NULL) {
        fprintf(stderr, "could not determine working directory\n");
        return 2;
    }

    subcmd = argv[2];

    if (strcmp(subcmd, "init-config") == 0) {
        return cmd_maintain_init_config(argc, argv, repo_root);
    } else if (strcmp(subcmd, "doctor") == 0) {
        return cmd_maintain_doctor(argc, argv, repo_root);
    } else if (strcmp(subcmd, "list") == 0) {
        return cmd_maintain_list(argc, argv, repo_root);
    } else if (strcmp(subcmd, "scan") == 0) {
        return cmd_maintain_scan(argc, argv, repo_root);
    } else if (strcmp(subcmd, "create") == 0) {
        return cmd_maintain_create(argc, argv, repo_root);
    } else {
        fprintf(stderr, "unknown maintain subcommand: %s\n", subcmd);
        return 2;
    }
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

    if (should_handle_native_maintain(argc, argv)) {
        return cmd_maintain_native(argc, argv);
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
        if (should_handle_native_show(argc, argv)) {
            return cmd_show_native(argc, argv);
        }
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
