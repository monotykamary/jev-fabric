#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>
#include <limits.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

extern char **environ;

/* No JSON, job state machine, event policy or command execution here. The
 * worker is this same native executable; posix_spawn avoids Bend post-fork
 * allocator/runtime hazards. Every OS string and buffer has a fixed bound. */
typedef struct {
  u32 op, limit;
  int opened;
  char *id, *name, *text, *argv[70];
  size_t argc, text_len, result_len;
  char *result;
} jfh_request;

static int jfh_lease = -1;

static int jfh_private(int fd, int directory) {
  struct stat s;
  if (fstat(fd, &s) < 0) return -1;
  if (s.st_uid != geteuid() || (s.st_mode & 077) ||
      (directory ? !S_ISDIR(s.st_mode) : (!S_ISREG(s.st_mode) || s.st_nlink != 1))) {
    errno = EPERM; return -1;
  }
  return 0;
}

static int jfh_id(const char *s) {
  if (strlen(s) != 32) return 0;
  for (unsigned i = 0; i < 32; i++)
    if (!((s[i] >= 'a' && s[i] <= 'f') || (s[i] >= '0' && s[i] <= '9'))) return 0;
  return 1;
}

static int jfh_leaf(const char *s) {
  size_t n = strlen(s);
  if (!n || n > 64 || s[0] == '.') return 0;
  for (size_t i = 0; i < n; i++)
    if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '.' || s[i] == '-')) return 0;
  return 1;
}

/* Walk components with no-follow directory descriptors, including ancestors.
 * No realpath(root): it would silently bless symlink traversal. */
static int jfh_root(void) {
  const char *env = getenv("JEV_FABRIC_HOME");
  const char *path = env ? env : ".jev-fabric-native";
  if (!*path || strlen(path) >= PATH_MAX) { errno = EINVAL; return -1; }
  char copy[PATH_MAX]; strcpy(copy, path);
  int fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return -1;
  char *save = NULL, *part = strtok_r(copy, "/", &save);
  while (part) {
    if (!strcmp(part, ".") || !strcmp(part, "..")) { close(fd); errno = EINVAL; return -1; }
    if (mkdirat(fd, part, 0700) < 0 && errno != EEXIST) { int e = errno; close(fd); errno = e; return -1; }
    int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int e = errno; close(fd); fd = next;
    if (fd < 0) { errno = e; return -1; }
    part = strtok_r(NULL, "/", &save);
  }
  if (jfh_private(fd, 1) < 0) { int e = errno; close(fd); errno = e; return -1; }
  return fd;
}

static int jfh_dir(const char *id) {
  if (!jfh_id(id)) { errno = EINVAL; return -1; }
  int root = jfh_root();
  if (root < 0) return -1;
  int fd = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int e = errno; close(root);
  if (fd < 0) { errno = e; return -1; }
  if (jfh_private(fd, 1) < 0) { e = errno; close(fd); errno = e; return -1; }
  return fd;
}

static int jfh_random(char out[33]) {
  unsigned char bytes[16];
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  size_t used = 0;
  while (used < sizeof bytes) {
    ssize_t n = read(fd, bytes + used, sizeof bytes - used);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { int e = n ? errno : EIO; close(fd); errno = e; return -1; }
    used += (size_t)n;
  }
  close(fd);
  for (unsigned i = 0; i < 16; i++) { out[2*i] = "0123456789abcdef"[bytes[i] >> 4]; out[2*i+1] = "0123456789abcdef"[bytes[i] & 15]; }
  out[32] = 0; return 0;
}

static int jfh_read_file(int dir, const char *name, u32 limit, char **text, size_t *length) {
  int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return errno == ENOENT ? 0 : -1;
  struct stat s;
  if (jfh_private(fd, 0) < 0 || fstat(fd, &s) < 0) { int e = errno; close(fd); errno = e; return -1; }
  if (s.st_size < 0 || (uint64_t)s.st_size > limit) { close(fd); errno = EFBIG; return -1; }
  *text = malloc((size_t)limit + 1);
  if (!*text) { close(fd); errno = ENOMEM; return -1; }
  size_t used = 0;
  while (used <= limit) {
    ssize_t n = read(fd, *text + used, (size_t)limit + 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) { int e = errno; close(fd); errno = e; return -1; }
    if (!n) break;
    used += (size_t)n;
  }
  close(fd);
  if (used > limit) { errno = EFBIG; return -1; }
  *length = used; return 0;
}

static int jfh_atomic(int dir, const char *name, const char *text, size_t length) {
  struct stat s;
  if (fstatat(dir, name, &s, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(s.st_mode) || s.st_uid != geteuid() || (s.st_mode & 077) || s.st_nlink != 1) { errno = EPERM; return -1; }
  } else if (errno != ENOENT) return -1;
  char random[33], temp[40];
  if (jfh_random(random) < 0) return -1;
  snprintf(temp, sizeof temp, ".%s.tmp", random);
  int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  size_t used = 0; int result = -1;
  while (used < length) {
    ssize_t n = write(fd, text + used, length - used);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) goto end;
    used += (size_t)n;
  }
  if (fsync(fd) < 0 || renameat(dir, temp, dir, name) < 0 || fsync(dir) < 0) goto end;
  result = 0;
end:;
  int e = errno; close(fd); unlinkat(dir, temp, 0); errno = e; return result;
}

static void *jfh_reap(void *value) {
  pid_t pid = (pid_t)(intptr_t)value;
  while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
  return NULL;
}

static int jfh_spawn_process(jfh_request *r) {
  if (!r->argc || r->argv[0][0] != '/') { errno = EINVAL; return -1; }
  posix_spawn_file_actions_t actions;
  int rc = posix_spawn_file_actions_init(&actions);
  if (rc) { errno = rc; return -1; }
  for (int i = 0; i < 3 && !rc; i++) rc = posix_spawn_file_actions_addopen(&actions, i, "/dev/null", i ? O_WRONLY : O_RDONLY, 0);
  pid_t pid;
  if (!rc) rc = posix_spawn(&pid, r->argv[0], &actions, NULL, r->argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  if (rc) { errno = rc; return -1; }
  pthread_t thread;
  /* Reap while the launcher lives; after its exit the OS adopts the worker.
   * Failure to allocate a reaper does not invalidate a successfully spawned job. */
  if (!pthread_create(&thread, NULL, jfh_reap, (void *)(intptr_t)pid)) pthread_detach(thread);
  return 0;
}

static void jfh_call(IoWork *w) {
  jfh_request *r = (jfh_request *)w->data;
  int dir = -1, fd = -1, rc = -1;
  if (r->op == 0) {
    char path[PATH_MAX], resolved[PATH_MAX];
#ifdef __APPLE__
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) { errno = ENAMETOOLONG; goto end; }
#else
    ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
    if (n < 0) goto end;
    if ((size_t)n == sizeof path - 1) { errno = ENAMETOOLONG; goto end; }
    path[n] = 0;
#endif
    if (!realpath(path, resolved)) goto end;
    r->result = strdup(resolved); r->result_len = strlen(resolved); rc = r->result ? 0 : -1;
  } else if (r->op == 1) {
    if (!r->limit || r->limit > 4096) { errno = EINVAL; goto end; }
    dir = jfh_root(); if (dir < 0 || flock(dir, LOCK_EX) < 0) goto end;
    int copy = fcntl(dir, F_DUPFD_CLOEXEC, 3); if (copy < 0) goto end;
    DIR *entries = fdopendir(copy); if (!entries) { close(copy); goto end; }
    unsigned count = 0; struct dirent *ent;
    while (count < r->limit && (ent = readdir(entries)))
      if (strcmp(ent->d_name, ".") && strcmp(ent->d_name, "..")) count++;
    closedir(entries);
    if (count >= r->limit) { errno = ENOSPC; goto end; }
    char id[33]; if (jfh_random(id) < 0 || mkdirat(dir, id, 0700) < 0 || fsync(dir) < 0) goto end;
    r->result = strdup(id); r->result_len = 32; rc = r->result ? 0 : -1;
  } else if (r->op == 6) {
    rc = jfh_spawn_process(r);
  } else {
    dir = jfh_dir(r->id); if (dir < 0) goto end;
    if (r->op == 7) {
      if (!jfh_leaf(r->name)) { errno = EINVAL; goto end; }
      fd = openat(dir, r->name, O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (r->limit ? (O_WRONLY | O_CREAT | O_EXCL) : O_RDONLY), 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) goto end;
      r->opened = fd; fd = -1; rc = 0;
    } else if (r->op == 2 || r->op == 3) {
      if (!jfh_leaf(r->name)) { errno = EINVAL; goto end; }
      rc = r->op == 2 ? jfh_read_file(dir, r->name, r->limit, &r->result, &r->result_len) : jfh_atomic(dir, r->name, r->text, r->text_len);
    } else if (r->op == 4 || r->op == 5) {
      fd = openat(dir, ".lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) goto end;
      if (r->op == 4) {
        if (jfh_lease >= 0) { errno = EBUSY; goto end; }
        if (flock(fd, LOCK_EX | LOCK_NB) < 0) goto end;
        if (setsid() < 0) goto end;
        jfh_lease = fd; fd = -1; rc = 0;
      } else {
        int locked = flock(fd, LOCK_EX | LOCK_NB);
        if (locked < 0 && errno != EWOULDBLOCK && errno != EAGAIN) goto end;
        r->result = strdup(locked < 0 ? "1" : "0"); r->result_len = 1; rc = r->result ? 0 : -1;
      }
    } else errno = EINVAL;
  }
end:
  w->code = rc < 0 ? (errno ? errno : EIO) : 0;
  if (fd >= 0) close(fd);
  if (dir >= 0) close(dir);
}

static Term jfh_pack(Env e, IoWork *w) {
  jfh_request *r = (jfh_request *)w->data;
  Term result = w->code ? io_fail(e, w->code, "native private job operation failed") : io_done(e, r->op == 7 ? io_hand(r->opened) : io_str(e, r->result ? r->result : "", r->result_len));
  free(r->id); free(r->name); free(r->text); free(r->result);
  for (size_t i = 0; i < r->argc; i++) free(r->argv[i]);
  free(r); return result;
}

Term jfh_os_run(Env e, Term *f, IoWork *w) {
  jfh_request *r = io_mem(calloc(1, sizeof *r));
  w->data = (char *)r; w->code = 0;
  r->op = (u32)f[0]; r->limit = (u32)f[5];
  u64 a, b, c;
  r->id = io_cstr(e, f[1], &a); r->name = io_cstr(e, f[2], &b); r->text = io_cstr(e, f[3], &c); r->text_len = (size_t)c;
  if (r->op > 6 || a > 32 || b > 64 || c > 1048576 || r->limit > 1048576 || io_nul(r->id, a) || io_nul(r->name, b)) w->code = EINVAL;
  Term args = f[4];
  while (term_aux(args) == CID_CON) {
    Term fields[2]; spare_free(e, cls_fit(2), ctr_take(e, args, 2, fields));
    u64 length; char *arg = io_cstr(e, fields[0], &length);
    if (r->argc == 69 || length > 4096 || io_nul(arg, length)) { w->code = EINVAL; free(arg); }
    else r->argv[r->argc++] = arg;
    args = fields[1];
  }
  return w->code ? jfh_pack(e, w) : io_work(w, jfh_call, jfh_pack);
}

Term jfh_spool_run(Env e, Term *f, IoWork *w) {
  jfh_request *r = io_mem(calloc(1, sizeof *r));
  w->data = (char *)r; w->code = 0;
  r->op = 7; r->limit = term_aux(f[2]) == CID_TRUE;
  u64 a, b;
  r->id = io_cstr(e, f[0], &a); r->name = io_cstr(e, f[1], &b);
  if (a > 32 || b > 64 || io_nul(r->id, a) || io_nul(r->name, b)) w->code = EINVAL;
  return w->code ? jfh_pack(e, w) : io_work(w, jfh_call, jfh_pack);
}

static void __attribute__((constructor)) jfh_os_use(void) {
#ifdef CID_JFH_OS
  io_eff(CID_JFH_OS, jfh_os_run, 0);
#endif
#ifdef CID_JFH_SPOOL
  io_eff(CID_JFH_SPOOL, jfh_spool_run, 0);
#endif
}
