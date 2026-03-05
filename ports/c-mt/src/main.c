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

static int path_is_file(const char *path);
static int path_is_dir(const char *path);
static int path_exists(const char *path);
static void join_path(char *dst, size_t dst_size, const char *a, const char *b);
static int find_in_path(const char *cmd, char *out, size_t out_size);
static int find_repo_root(char *out, size_t out_size);
static int dirname_from_path(const char *path, char *out, size_t out_size);
static int find_repo_root_from_dir(const char *start_dir, char *out, size_t out_size);

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

    if (!resolve_repo_root(repo_root, sizeof(repo_root), argc, argv)) {
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
    if (as_json != NULL) {
        *as_json = 0;
    }
    if (argc <= 1) {
        return 1;
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
            "created: %s\n"
            "updated: %s\n"
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
    int version_json = 0;

    if (should_handle_native_init(argc, argv)) {
        return cmd_init_native(argc, argv);
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
