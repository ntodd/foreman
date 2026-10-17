// Microbenchmarks for the paths where a VM differs from a container:
// syscalls, process creation, page faults, context switches and file
// metadata. Each prints one JSON line: {"name":..., "value":..., "unit":...}.
//
//   cc -O2 -o micro micro.c && ./micro <scratch dir>
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void report(const char *name, double value, const char *unit) {
  printf("{\"name\":\"%s\",\"value\":%.6f,\"unit\":\"%s\"}\n", name, value, unit);
  fflush(stdout);
}

static void bench_syscall(void) {
  const long n = 5000000;
  double t = now();
  for (long i = 0; i < n; i++) syscall(SYS_getppid);
  report("micro.syscall_ns", (now() - t) / n * 1e9, "ns");
}

static void bench_fork_exec(void) {
  const int n = 3000;
  double t = now();
  for (int i = 0; i < n; i++) {
    pid_t pid = fork();
    if (pid == 0) {
      execl("/bin/true", "true", (char *)NULL);
      _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
  }
  report("micro.fork_exec_us", (now() - t) / n * 1e6, "us");
}

static void bench_page_faults(void) {
  // MICRO_FAULT_MB shrinks it for small boxes (default 2 GiB).
  const char *mb = getenv("MICRO_FAULT_MB");
  const size_t size = (size_t)(mb ? atol(mb) : 2048) << 20;
  double t = now();
  char *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); return; }
  // Defeat transparent huge pages so every 4 KiB page faults.
  madvise(p, size, MADV_NOHUGEPAGE);
  for (size_t i = 0; i < size; i += 4096) p[i] = 1;
  double elapsed = now() - t;
  munmap(p, size);
  report("micro.page_fault_ns", elapsed / (size / 4096) * 1e9, "ns");
}

static void bench_pipe_pingpong(void) {
  int a[2], b[2];
  if (pipe(a) || pipe(b)) { perror("pipe"); return; }
  const int n = 200000;
  char c = 0;
  pid_t pid = fork();
  if (pid == 0) {
    for (int i = 0; i < n; i++) {
      if (read(a[0], &c, 1) != 1) _exit(1);
      if (write(b[1], &c, 1) != 1) _exit(1);
    }
    _exit(0);
  }
  double t = now();
  for (int i = 0; i < n; i++) {
    if (write(a[1], &c, 1) != 1) break;
    if (read(b[0], &c, 1) != 1) break;
  }
  double elapsed = now() - t;
  waitpid(pid, NULL, 0);
  report("micro.pipe_roundtrip_us", elapsed / n * 1e6, "us");
}

static void bench_fs_meta(const char *dir) {
  const int n = 50000;
  char path[4096];
  snprintf(path, sizeof path, "%s/meta", dir);
  mkdir(path, 0755);
  double t = now();
  for (int i = 0; i < n; i++) {
    snprintf(path, sizeof path, "%s/meta/f%d", dir, i);
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return; }
    if (write(fd, "0123456789abcdef0123456789abcdef", 32) != 32) perror("write");
    close(fd);
  }
  double created = now();
  struct stat st;
  for (int i = 0; i < n; i++) {
    snprintf(path, sizeof path, "%s/meta/f%d", dir, i);
    stat(path, &st);
  }
  double statted = now();
  snprintf(path, sizeof path, "%s/meta", dir);
  DIR *d = opendir(path);
  long entries = 0;
  while (d && readdir(d)) entries++;
  if (d) closedir(d);
  for (int i = 0; i < n; i++) {
    snprintf(path, sizeof path, "%s/meta/f%d", dir, i);
    unlink(path);
  }
  double removed = now();
  snprintf(path, sizeof path, "%s/meta", dir);
  rmdir(path);
  report("micro.fs_create_us", (created - t) / n * 1e6, "us");
  report("micro.fs_stat_us", (statted - created) / n * 1e6, "us");
  report("micro.fs_unlink_us", (removed - statted) / n * 1e6, "us");
}

static void bench_fsync(const char *dir) {
  const int n = 2000;
  char path[4096];
  snprintf(path, sizeof path, "%s/fsync.dat", dir);
  int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
  if (fd < 0) { perror("open"); return; }
  char buf[4096];
  memset(buf, 'x', sizeof buf);
  double t = now();
  for (int i = 0; i < n; i++) {
    if (write(fd, buf, sizeof buf) != (ssize_t)sizeof buf) perror("write");
    fdatasync(fd);
  }
  double elapsed = now() - t;
  close(fd);
  unlink(path);
  report("micro.write_fdatasync_us", elapsed / n * 1e6, "us");
}

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : ".";
  bench_syscall();
  bench_fork_exec();
  bench_page_faults();
  bench_pipe_pingpong();
  bench_fs_meta(dir);
  bench_fsync(dir);
  return 0;
}
