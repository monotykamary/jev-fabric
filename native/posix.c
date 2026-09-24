#include <spawn.h>
#include <sys/wait.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <stdatomic.h>

extern char **environ;

#define JF_TAIL 32768
#define JF_ARGS 64
#define JF_JOBS 8

typedef struct {
  char *argv[JF_ARGS + 1];
  size_t argc;
  char *input;
  u64 input_len;
  u32 timeout;
  int inherit_stdin;
  u32 code;
  u32 flags;
  char out[JF_TAIL];
  char err[JF_TAIL];
  size_t out_len;
  size_t err_len;
} JfExec;

static pthread_mutex_t jf_gate = PTHREAD_MUTEX_INITIALIZER;
static unsigned jf_jobs;
static pid_t jf_pids[JF_JOBS];
static int jf_shutdown;
static _Atomic int jf_interrupt;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal flag must be lock-free");

static void jf_signal(int signal_number) { atomic_store_explicit(&jf_interrupt, signal_number, memory_order_relaxed); }

static void jf_cleanup(void) {
  pid_t owned[JF_JOBS];
  pthread_mutex_lock(&jf_gate);
  jf_shutdown = 1;
  memcpy(owned, jf_pids, sizeof owned);
  for (unsigned i = 0; i < JF_JOBS; i++) if (owned[i] > 0) kill(-owned[i], SIGKILL);
  pthread_mutex_unlock(&jf_gate);
  for (unsigned i = 0; i < JF_JOBS; i++) {
    if (owned[i] > 0) while (waitpid(owned[i], NULL, 0) < 0 && errno == EINTR) {}
  }
}

static void jf_close(int *fd) {
  if (*fd >= 0) { close(*fd); *fd = -1; }
}

static int jf_pipe(int fds[2]) {
  if (pipe(fds) < 0) return -1;
  if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
    int saved = errno; jf_close(&fds[0]); jf_close(&fds[1]); errno = saved; return -1;
  }
  return 0;
}

static void jf_tail(char *dest, size_t *used, const char *data, size_t count, u32 *flags, u32 bit) {
  if (*used + count > JF_TAIL) *flags |= bit;
  if (count >= JF_TAIL) { memcpy(dest, data + count - JF_TAIL, JF_TAIL); *used = JF_TAIL; }
  else {
    size_t discard = *used + count > JF_TAIL ? *used + count - JF_TAIL : 0;
    memmove(dest, dest + discard, *used - discard);
    *used -= discard; memcpy(dest + *used, data, count); *used += count;
  }
}

static void jf_read(int *fd, JfExec *job, int err) {
  char buffer[8192];
  ssize_t n = read(*fd, buffer, sizeof buffer);
  if (n > 0) {
    jf_tail(err ? job->err : job->out, err ? &job->err_len : &job->out_len,
      buffer, (size_t)n, &job->flags, err ? 4 : 2);
  } else if (n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) jf_close(fd);
}

// This helper thread owns all descriptors and the child's process group.
// It never touches Bend terms or Env; packing occurs back on Bend's IO loop.
static void jf_exec_call(IoWork *w) {
  JfExec *job = (JfExec *)w->data;
  int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
  pid_t pid = -1;
  int status = 0, done = 0, registered = 0, slot = -1;
  size_t sent = 0;
  u64 exited_at = 0;
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  int have_actions = 0, have_attr = 0;
  pthread_mutex_lock(&jf_gate);
  if (!jf_shutdown && jf_jobs < JF_JOBS) {
    for (unsigned i = 0; i < JF_JOBS; i++) if (jf_pids[i] == 0) { slot = (int)i; jf_pids[i] = -1; break; }
    jf_jobs++; registered = 1;
  }
  pthread_mutex_unlock(&jf_gate);
  if (!registered) { w->code = EAGAIN; return; }
  if (jf_interrupt) { w->code = EINTR; goto cleanup; }
  if ((!job->inherit_stdin && jf_pipe(in) < 0) || jf_pipe(out) < 0 || jf_pipe(err) < 0) { w->code = errno; goto cleanup; }
  w->code = posix_spawn_file_actions_init(&actions);
  if (w->code) goto cleanup;
  have_actions = 1;
  w->code = posix_spawnattr_init(&attr);
  if (w->code) goto cleanup;
  have_attr = 1;
  sigset_t defaults;
  sigemptyset(&defaults); sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM);
  if ((w->code = posix_spawnattr_setpgroup(&attr, 0)) ||
      (w->code = posix_spawnattr_setsigdefault(&attr, &defaults)) ||
      (w->code = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))) goto cleanup;
  if ((w->code = posix_spawn_file_actions_adddup2(&actions, job->inherit_stdin ? STDIN_FILENO : in[0], STDIN_FILENO)) ||
      (w->code = posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)) ||
      (w->code = posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))) goto cleanup;
  pthread_mutex_lock(&jf_gate);
  w->code = jf_shutdown ? ECANCELED : posix_spawnp(&pid, job->argv[0], &actions, &attr, job->argv, environ);
  if (!w->code) jf_pids[slot] = pid;
  else pid = -1;
  pthread_mutex_unlock(&jf_gate);
  if (w->code) goto cleanup;
  jf_close(&in[0]); jf_close(&out[1]); jf_close(&err[1]);
  if ((in[1] >= 0 && fcntl(in[1], F_SETFL, O_NONBLOCK) < 0) || fcntl(out[0], F_SETFL, O_NONBLOCK) < 0 || fcntl(err[0], F_SETFL, O_NONBLOCK) < 0) {
    w->code = errno; goto cleanup;
  }
  u64 deadline = io_tick() + (u64)job->timeout * 1000000ull;
  while (!done || out[0] >= 0 || err[0] >= 0) {
    if (!done && jf_interrupt && !(job->flags & 8)) {
      job->flags |= 8; job->code = 128 + jf_interrupt; kill(-pid, SIGKILL);
    }
    if (!done && io_tick() >= deadline && !(job->flags & (1 | 8))) {
      job->flags |= 1; job->code = 124; kill(-pid, SIGKILL);
    }
    if (!done) {
      pid_t got = waitpid(pid, &status, WNOHANG);
      if (got == pid) {
        done = 1; exited_at = io_tick(); kill(-pid, SIGKILL); jf_close(&in[1]);
        pthread_mutex_lock(&jf_gate); jf_pids[slot] = -1; pthread_mutex_unlock(&jf_gate);
      }
      else if (got < 0 && errno != EINTR) { w->code = errno; goto cleanup; }
    }
    if (done && io_tick() - exited_at > 100000000ull) {
      // Do not hang on an escaped daemon that retained a pipe. Disclose lost output.
      if (out[0] >= 0) job->flags |= 2;
      if (err[0] >= 0) job->flags |= 4;
      jf_close(&out[0]); jf_close(&err[0]); break;
    }
    if (sent == job->input_len) jf_close(&in[1]);
    struct pollfd fds[3] = {{out[0], POLLIN, 0}, {err[0], POLLIN, 0}, {in[1], POLLOUT, 0}};
    int ready = poll(fds, 3, 10);
    if (ready < 0 && errno != EINTR) { w->code = errno; goto cleanup; }
    if (out[0] >= 0 && fds[0].revents) jf_read(&out[0], job, 0);
    if (err[0] >= 0 && fds[1].revents) jf_read(&err[0], job, 1);
    if (in[1] >= 0 && fds[2].revents) {
      ssize_t n = write(in[1], job->input + sent, job->input_len - sent);
      if (n > 0) sent += n;
      else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) jf_close(&in[1]);
    }
  }
  if (!(job->flags & (1 | 8))) job->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
cleanup:
  if (pid > 0 && !done) {
    kill(-pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  }
  jf_close(&in[0]); jf_close(&in[1]); jf_close(&out[0]); jf_close(&out[1]); jf_close(&err[0]); jf_close(&err[1]);
  if (have_actions) posix_spawn_file_actions_destroy(&actions);
  if (have_attr) posix_spawnattr_destroy(&attr);
  pthread_mutex_lock(&jf_gate); jf_pids[slot] = 0; jf_jobs--; pthread_mutex_unlock(&jf_gate);
}

static Term jf_exec_pack(Env e, IoWork *w) {
  JfExec *job = (JfExec *)w->data;
  Term result;
  if (w->code) result = io_fail(e, w->code, "native subprocess request failed");
  else result = io_done(e, io_tup(e, (Term)job->code,
    io_tup(e, (Term)job->flags, io_tup(e, io_str(e, job->out, job->out_len), io_str(e, job->err, job->err_len)))));
  for (size_t i = 0; i < job->argc; i++) free(job->argv[i]);
  free(job->input); free(job); return result;
}

Term native_exec_run(Env e, Term *f, IoWork *w) {
  JfExec *job = io_mem(calloc(1, sizeof *job));
  w->data = (char *)job; w->code = 0;
  Term args = f[0];
  while (term_aux(args) == CID_CON) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, args, 2, fields));
    u64 length = 0;
    char *arg = io_cstr(e, fields[0], &length);
    if (job->argc == JF_ARGS || length > 4096 || io_nul(arg, length)) { w->code = EINVAL; free(arg); }
    else job->argv[job->argc++] = arg;
    args = fields[1];
  }
  job->input = io_cstr(e, f[1], &job->input_len);
  job->timeout = (u32)f[2];
  job->inherit_stdin = term_aux(f[3]) == CID_TRUE;
  if (!job->argc || !job->argv[0][0] || job->input_len > 131072 || !job->timeout || job->timeout > 3600000) w->code = EINVAL;
  return w->code ? jf_exec_pack(e, w) : io_work(w, jf_exec_call, jf_exec_pack);
}

static void __attribute__((constructor)) native_exec_use(void) {
  struct sigaction action;
  memset(&action, 0, sizeof action); action.sa_handler = jf_signal; sigemptyset(&action.sa_mask);
  sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  atexit(jf_cleanup);
  io_eff(CID_NATIVE_EXEC, native_exec_run, 0);
}
