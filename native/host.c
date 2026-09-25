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

#define JFH_ID_LEN 32
#define JFH_LEAF_MAX 64
#define JFH_ARGS 69
#define JFH_ARG_BYTES 4096
#define JFH_TEXT_MAX 1048576
#define JFH_JOBS_MAX 4096

// Operations of Host.jfh_os (0..6) and Host.jfh_spool (7).
enum {
  JFH_SELF = 0,
  JFH_CREATE = 1,
  JFH_READ = 2,
  JFH_WRITE = 3,
  JFH_CLAIM = 4,
  JFH_ALIVE = 5,
  JFH_SPAWN = 6,
  JFH_SPOOL = 7,
};

/* No JSON, job state machine, event policy or command execution here. The
 * worker is this same native executable; posix_spawn avoids Bend post-fork
 * allocator/runtime hazards. Every OS string and buffer has a fixed bound. */
typedef struct {
  u32 op;
  u32 limit;
  int opened;
  char *id;
  char *name;
  char *text;
  char *argv[JFH_ARGS + 1];
  size_t argc;
  size_t text_len;
  size_t result_len;
  char *result;
} jfh_request;

static int jfh_lease = -1;

// Owned by us, no group/other permissions, and a directory or a single-link regular file.
static int jfh_private(int fd, int directory) {
  struct stat s;
  if (fstat(fd, &s) < 0) {
    return -1;
  }
  int right_type = directory ? S_ISDIR(s.st_mode) : (S_ISREG(s.st_mode) && s.st_nlink == 1);
  if (s.st_uid != geteuid() || (s.st_mode & 077) || !right_type) {
    errno = EPERM;
    return -1;
  }
  return 0;
}

static int jfh_id(const char *s) {
  if (strlen(s) != JFH_ID_LEN) {
    return 0;
  }
  for (unsigned i = 0; i < JFH_ID_LEN; i++) {
    int hex = (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= '0' && s[i] <= '9');
    if (!hex) {
      return 0;
    }
  }
  return 1;
}

static int jfh_leaf(const char *s) {
  size_t n = strlen(s);
  if (!n || n > JFH_LEAF_MAX || s[0] == '.') {
    return 0;
  }
  for (size_t i = 0; i < n; i++) {
    int allowed = (s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9')
      || s[i] == '.' || s[i] == '-';
    if (!allowed) {
      return 0;
    }
  }
  return 1;
}

/* Walk components with no-follow directory descriptors, including ancestors.
 * No realpath(root): it would silently bless symlink traversal. */
static int jfh_root(void) {
  const char *env = getenv("JEV_FABRIC_HOME");
  const char *path = env ? env : ".jev-fabric-native";
  if (!*path || strlen(path) >= PATH_MAX) {
    errno = EINVAL;
    return -1;
  }
  char copy[PATH_MAX];
  strcpy(copy, path);
  int fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    return -1;
  }
  char *save = NULL;
  char *part = strtok_r(copy, "/", &save);
  while (part) {
    if (!strcmp(part, ".") || !strcmp(part, "..")) {
      close(fd);
      errno = EINVAL;
      return -1;
    }
    if (mkdirat(fd, part, 0700) < 0 && errno != EEXIST) {
      int saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
    int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno;
    close(fd);
    fd = next;
    if (fd < 0) {
      errno = saved;
      return -1;
    }
    part = strtok_r(NULL, "/", &save);
  }
  if (jfh_private(fd, 1) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

static int jfh_dir(const char *id) {
  if (!jfh_id(id)) {
    errno = EINVAL;
    return -1;
  }
  int root = jfh_root();
  if (root < 0) {
    return -1;
  }
  int fd = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int saved = errno;
  close(root);
  if (fd < 0) {
    errno = saved;
    return -1;
  }
  if (jfh_private(fd, 1) < 0) {
    saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

// Writes 32 lowercase hex digits from /dev/urandom plus a NUL.
static int jfh_random(char out[JFH_ID_LEN + 1]) {
  static const char digits[] = "0123456789abcdef";
  unsigned char bytes[JFH_ID_LEN / 2];
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return -1;
  }
  size_t used = 0;
  while (used < sizeof bytes) {
    ssize_t got = read(fd, bytes + used, sizeof bytes - used);
    if (got < 0 && errno == EINTR) {
      continue;
    }
    if (got <= 0) {
      int saved = got ? errno : EIO;
      close(fd);
      errno = saved;
      return -1;
    }
    used += (size_t)got;
  }
  close(fd);
  for (unsigned i = 0; i < sizeof bytes; i++) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 15];
  }
  out[JFH_ID_LEN] = 0;
  return 0;
}

// A missing file succeeds with *text unset; the caller treats that as empty.
static int jfh_read_file(int dir, const char *name, u32 limit, char **text, size_t *length) {
  int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) {
    return errno == ENOENT ? 0 : -1;
  }
  struct stat s;
  if (jfh_private(fd, 0) < 0 || fstat(fd, &s) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  if (s.st_size < 0 || (uint64_t)s.st_size > limit) {
    close(fd);
    errno = EFBIG;
    return -1;
  }
  *text = malloc((size_t)limit + 1);
  if (!*text) {
    close(fd);
    errno = ENOMEM;
    return -1;
  }
  // Read one byte past the limit so growth after the fstat is detected.
  size_t used = 0;
  while (used <= limit) {
    ssize_t got = read(fd, *text + used, (size_t)limit + 1 - used);
    if (got < 0 && errno == EINTR) {
      continue;
    }
    if (got < 0) {
      int saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
    if (!got) {
      break;
    }
    used += (size_t)got;
  }
  close(fd);
  if (used > limit) {
    errno = EFBIG;
    return -1;
  }
  *length = used;
  return 0;
}

// Replace `name` via a fsynced exclusive temp file and rename.
static int jfh_atomic(int dir, const char *name, const char *text, size_t length) {
  struct stat s;
  if (fstatat(dir, name, &s, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(s.st_mode) || s.st_uid != geteuid() || (s.st_mode & 077) || s.st_nlink != 1) {
      errno = EPERM;
      return -1;
    }
  } else if (errno != ENOENT) {
    return -1;
  }
  char random[JFH_ID_LEN + 1];
  char temp[40];
  if (jfh_random(random) < 0) {
    return -1;
  }
  snprintf(temp, sizeof temp, ".%s.tmp", random);
  int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) {
    return -1;
  }
  size_t used = 0;
  int result = -1;
  while (used < length) {
    ssize_t put = write(fd, text + used, length - used);
    if (put < 0 && errno == EINTR) {
      continue;
    }
    if (put <= 0) {
      goto end;
    }
    used += (size_t)put;
  }
  if (fsync(fd) < 0 || renameat(dir, temp, dir, name) < 0 || fsync(dir) < 0) {
    goto end;
  }
  result = 0;
end:;
  int saved = errno;
  close(fd);
  unlinkat(dir, temp, 0);
  errno = saved;
  return result;
}

static void *jfh_reap(void *value) {
  pid_t pid = (pid_t)(intptr_t)value;
  while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
  return NULL;
}

static int jfh_spawn_process(jfh_request *req) {
  if (!req->argc || req->argv[0][0] != '/') {
    errno = EINVAL;
    return -1;
  }
  posix_spawn_file_actions_t actions;
  int rc = posix_spawn_file_actions_init(&actions);
  if (rc) {
    errno = rc;
    return -1;
  }
  for (int fd = 0; fd < 3 && !rc; fd++) {
    int mode = fd ? O_WRONLY : O_RDONLY;
    rc = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0);
  }
  pid_t pid;
  if (!rc) {
    rc = posix_spawn(&pid, req->argv[0], &actions, NULL, req->argv, environ);
  }
  posix_spawn_file_actions_destroy(&actions);
  if (rc) {
    errno = rc;
    return -1;
  }
  pthread_t thread;
  /* Reap while the launcher lives; after its exit the OS adopts the worker.
   * Failure to allocate a reaper does not invalidate a successfully spawned job. */
  if (!pthread_create(&thread, NULL, jfh_reap, (void *)(intptr_t)pid)) {
    pthread_detach(thread);
  }
  return 0;
}

static void jfh_call(IoWork *w) {
  jfh_request *req = (jfh_request *)w->data;
  int dir = -1;
  int fd = -1;
  int rc = -1;
  if (req->op == JFH_SELF) {
    char path[PATH_MAX];
    char resolved[PATH_MAX];
#ifdef __APPLE__
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) {
      errno = ENAMETOOLONG;
      goto end;
    }
#else
    ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
    if (n < 0) {
      goto end;
    }
    if ((size_t)n == sizeof path - 1) {
      errno = ENAMETOOLONG;
      goto end;
    }
    path[n] = 0;
#endif
    if (!realpath(path, resolved)) {
      goto end;
    }
    req->result = strdup(resolved);
    req->result_len = strlen(resolved);
    rc = req->result ? 0 : -1;
  } else if (req->op == JFH_CREATE) {
    // `limit` is the maximum number of job directories under the root.
    if (!req->limit || req->limit > JFH_JOBS_MAX) {
      errno = EINVAL;
      goto end;
    }
    dir = jfh_root();
    if (dir < 0 || flock(dir, LOCK_EX) < 0) {
      goto end;
    }
    int copy = fcntl(dir, F_DUPFD_CLOEXEC, 3);
    if (copy < 0) {
      goto end;
    }
    DIR *entries = fdopendir(copy);
    if (!entries) {
      close(copy);
      goto end;
    }
    unsigned count = 0;
    struct dirent *ent;
    while (count < req->limit && (ent = readdir(entries))) {
      if (strcmp(ent->d_name, ".") && strcmp(ent->d_name, "..")) {
        count++;
      }
    }
    closedir(entries);
    if (count >= req->limit) {
      errno = ENOSPC;
      goto end;
    }
    char id[JFH_ID_LEN + 1];
    if (jfh_random(id) < 0 || mkdirat(dir, id, 0700) < 0 || fsync(dir) < 0) {
      goto end;
    }
    req->result = strdup(id);
    req->result_len = JFH_ID_LEN;
    rc = req->result ? 0 : -1;
  } else if (req->op == JFH_SPAWN) {
    rc = jfh_spawn_process(req);
  } else {
    dir = jfh_dir(req->id);
    if (dir < 0) {
      goto end;
    }
    if (req->op == JFH_SPOOL) {
      if (!jfh_leaf(req->name)) {
        errno = EINVAL;
        goto end;
      }
      // For spool, a nonzero `limit` means "create the writer".
      int mode = req->limit ? (O_WRONLY | O_CREAT | O_EXCL) : O_RDONLY;
      fd = openat(dir, req->name, O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | mode, 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) {
        goto end;
      }
      req->opened = fd;
      fd = -1;
      rc = 0;
    } else if (req->op == JFH_READ || req->op == JFH_WRITE) {
      if (!jfh_leaf(req->name)) {
        errno = EINVAL;
        goto end;
      }
      if (req->op == JFH_READ) {
        rc = jfh_read_file(dir, req->name, req->limit, &req->result, &req->result_len);
      } else {
        rc = jfh_atomic(dir, req->name, req->text, req->text_len);
      }
    } else if (req->op == JFH_CLAIM || req->op == JFH_ALIVE) {
      fd = openat(dir, ".lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
      if (fd < 0 || jfh_private(fd, 0) < 0) {
        goto end;
      }
      if (req->op == JFH_CLAIM) {
        if (jfh_lease >= 0) {
          errno = EBUSY;
          goto end;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
          goto end;
        }
        if (setsid() < 0) {
          goto end;
        }
        jfh_lease = fd;
        fd = -1;
        rc = 0;
      } else {
        int locked = flock(fd, LOCK_EX | LOCK_NB);
        if (locked < 0 && errno != EWOULDBLOCK && errno != EAGAIN) {
          goto end;
        }
        req->result = strdup(locked < 0 ? "1" : "0");
        req->result_len = 1;
        rc = req->result ? 0 : -1;
      }
    } else {
      errno = EINVAL;
    }
  }
end:
  w->code = rc < 0 ? (errno ? errno : EIO) : 0;
  if (fd >= 0) {
    close(fd);
  }
  if (dir >= 0) {
    close(dir);
  }
}

// Spool answers a File handle; every other operation answers a String.
static Term jfh_pack(Env e, IoWork *w) {
  jfh_request *req = (jfh_request *)w->data;
  Term result;
  if (w->code) {
    result = io_fail(e, w->code, "native private job operation failed");
  } else if (req->op == JFH_SPOOL) {
    result = io_done(e, io_hand(req->opened));
  } else {
    result = io_done(e, io_str(e, req->result ? req->result : "", req->result_len));
  }
  free(req->id);
  free(req->name);
  free(req->text);
  free(req->result);
  for (size_t i = 0; i < req->argc; i++) {
    free(req->argv[i]);
  }
  free(req);
  return result;
}

Term jfh_os_run(Env e, Term *f, IoWork *w) {
  jfh_request *req = io_mem(calloc(1, sizeof *req));
  w->data = (char *)req;
  w->code = 0;
  req->op = (u32)f[0];
  req->limit = (u32)f[5];
  u64 id_len;
  u64 name_len;
  u64 text_len;
  req->id = io_cstr(e, f[1], &id_len);
  req->name = io_cstr(e, f[2], &name_len);
  req->text = io_cstr(e, f[3], &text_len);
  req->text_len = (size_t)text_len;
  if (req->op > JFH_SPAWN || id_len > JFH_ID_LEN || name_len > JFH_LEAF_MAX
      || text_len > JFH_TEXT_MAX || req->limit > JFH_TEXT_MAX
      || io_nul(req->id, id_len) || io_nul(req->name, name_len)) {
    w->code = EINVAL;
  }
  Term args = f[4];
  while (term_aux(args) == CID_CON) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, args, 2, fields));
    u64 length;
    char *arg = io_cstr(e, fields[0], &length);
    if (req->argc == JFH_ARGS || length > JFH_ARG_BYTES || io_nul(arg, length)) {
      w->code = EINVAL;
      free(arg);
    } else {
      req->argv[req->argc++] = arg;
    }
    args = fields[1];
  }
  return w->code ? jfh_pack(e, w) : io_work(w, jfh_call, jfh_pack);
}

Term jfh_spool_run(Env e, Term *f, IoWork *w) {
  jfh_request *req = io_mem(calloc(1, sizeof *req));
  w->data = (char *)req;
  w->code = 0;
  req->op = JFH_SPOOL;
  req->limit = term_aux(f[2]) == CID_TRUE;
  u64 id_len;
  u64 name_len;
  req->id = io_cstr(e, f[0], &id_len);
  req->name = io_cstr(e, f[1], &name_len);
  if (id_len > JFH_ID_LEN || name_len > JFH_LEAF_MAX
      || io_nul(req->id, id_len) || io_nul(req->name, name_len)) {
    w->code = EINVAL;
  }
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
