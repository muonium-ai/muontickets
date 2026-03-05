#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static void join_path(char *dst, size_t dst_size, const char *a, const char *b);
static int find_in_path(const char *cmd, char *out, size_t out_size);
static int find_repo_root(char *out, size_t out_size);
static int dirname_from_path(const char *path, char *out, size_t out_size);
static int find_repo_root_from_dir(const char *start_dir, char *out, size_t out_size);

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
