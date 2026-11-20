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

int main(int argc, char **argv)
{
    int reading = argc == 3 && strcmp(argv[1], "read-record") == 0;
    int trimming = argc == 4 && strcmp(argv[1], "trim-log") == 0;
    if (!reading && !trimming)
        return 1;

    int flags = (reading ? O_RDONLY : O_WRONLY) | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY;
    int fd = open(argv[2], flags);
    if (fd < 0)
        return 1;

    struct stat st;
    int result = 1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1) {
        result = reading ? read_record(fd, st.st_size) : trim_log(fd, st.st_size, argv[3]);
    }
    return close(fd) != 0 || result;
}
