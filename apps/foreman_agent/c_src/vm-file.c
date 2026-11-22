#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include <dirent.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The VMM can replace these files. Check and use the same descriptor. */
static int read_record(int fd, off_t size)
{
    char record[65536];
    if (size < 0 || size > (off_t)sizeof(record))
        return 1;
    if (read(fd, record, (size_t)size) != size)
        return 1;
    return fwrite(record, 1, (size_t)size, stdout) != (size_t)size || fflush(stdout) != 0;
}

static int trim_log(int fd, off_t size, const char *limit)
{
    char *end;
    errno = 0;
    long max_size = strtol(limit, &end, 10);
    if (errno || end == limit || *end || max_size <= 0)
        return 1;
    if (size <= max_size)
        return 0;

    static const char marker[] = "[foreman: the console passed 16 MB and was cut]\n";
    if (ftruncate(fd, 0) != 0)
        return 1;
    return write(fd, marker, sizeof(marker) - 1) != (ssize_t)(sizeof(marker) - 1);
}

/*
 * What a console gained since `from`: where to read from next on a line of
 * its own, then the whole lines up to there. A guest can write without
 * end, so only the last 64 KiB is read, and a console shorter than `from`
 * (cut, or started again) is read from its beginning. A line still being
 * written waits for its end.
 */
static int read_log(int fd, off_t size, const char *from)
{
    static char window[65536];
    char *end;
    errno = 0;
    long long offset = strtoll(from, &end, 10);
    if (errno || end == from || *end || offset < 0 || size < 0)
        return 1;
    if (offset > size)
        offset = 0;
    if (size - offset > (off_t)sizeof(window))
        offset = size - (off_t)sizeof(window);

    ssize_t got = pread(fd, window, (size_t)(size - offset), (off_t)offset);
    if (got < 0)
        return 1;
    size_t lines = (size_t)got;
    while (lines > 0 && window[lines - 1] != '\n')
        lines--;
    /* A full window without a line end has nothing worth waiting for. */
    if (lines == 0 && (size_t)got == sizeof(window))
        offset += got;

    if (printf("%lld\n", offset + (long long)lines) < 0)
        return 1;
    return fwrite(window, 1, lines, stdout) != lines || fflush(stdout) != 0;
}

/* Descend only through pinned directory descriptors. A replaced entry
 * is unlinked as a leaf or makes the operation fail for a later retry. */
static int remove_entry(int parent, const char *name)
{
    int fd = openat(parent, name, O_DIRECTORY | O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        if (errno == ENOENT)
            return 0;
        if (errno != ENOTDIR && errno != ELOOP)
            return -1;
        return unlinkat(parent, name, 0);
    }

    DIR *dir = fdopendir(fd);
    if (!dir) {
        close(fd);
        return -1;
    }
    int result = 0;
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(dir);
        if (!entry) {
            result = errno ? -1 : 0;
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        if (remove_entry(fd, entry->d_name) != 0) {
            result = -1;
            break;
        }
    }
    if (closedir(dir) || result)
        return -1;
    return unlinkat(parent, name, AT_REMOVEDIR);
}

static int remove_tree(const char *parent, const char *name)
{
    if (!*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, ".."))
        return 1;
    int fd = open(parent, O_DIRECTORY | O_RDONLY | O_NOFOLLOW);
    if (fd < 0)
        return errno != ENOENT;
    int result = remove_entry(fd, name);
    if (result)
        perror("remove");
    return close(fd) != 0 || result != 0;
}

/* linkat with flags zero pins the entry itself, including a symlink.
 * Only a socket may be published in the agent-owned destination. */
static int pin_socket(const char *source, const char *tmp, const char *dest)
{
    if (linkat(AT_FDCWD, source, AT_FDCWD, tmp, 0))
        return 1;
    struct stat st, previous;
    int ok = !lstat(tmp, &st) && S_ISSOCK(st.st_mode);
    if (ok) {
        int already_pinned = !lstat(dest, &previous) &&
            previous.st_dev == st.st_dev && previous.st_ino == st.st_ino;
        ok = st.st_nlink == (already_pinned ? 3u : 2u) && !rename(tmp, dest);
    }
    unlink(tmp); /* rename is a no-op if dest already names the same inode. */
    return !ok;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "remove-tree"))
        return remove_tree(argv[2], argv[3]);
    if (argc == 3 && !strcmp(argv[1], "mkdir-private"))
        return mkdir(argv[2], 0700) != 0;
    if (argc == 5 && !strcmp(argv[1], "pin-socket"))
        return pin_socket(argv[2], argv[3], argv[4]);

    int reading = argc == 3 && strcmp(argv[1], "read-record") == 0;
    int trimming = argc == 4 && strcmp(argv[1], "trim-log") == 0;
    int following = argc == 4 && strcmp(argv[1], "read-log") == 0;
    if (!reading && !trimming && !following)
        return 1;

    int flags = (trimming ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY;
    int fd = open(argv[2], flags);
    if (fd < 0)
        return 1;

    struct stat st;
    int result = 1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1) {
        if (reading)
            result = read_record(fd, st.st_size);
        else if (trimming)
            result = trim_log(fd, st.st_size, argv[3]);
        else
            result = read_log(fd, st.st_size, argv[3]);
    }
    return close(fd) != 0 || result;
}
