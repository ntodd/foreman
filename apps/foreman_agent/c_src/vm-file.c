#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif
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

int main(int argc, char **argv)
{
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
