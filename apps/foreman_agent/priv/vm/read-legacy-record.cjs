// Old releases kept this record in the VMM's writable directory. Read only
// a bounded regular file, through the descriptor used for the type check.
const fs = require("node:fs");
const { O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_NOCTTY } = fs.constants;
const fd = fs.openSync(process.argv[2], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
try {
  const stat = fs.fstatSync(fd);
  if (!stat.isFile() || stat.nlink !== 1 || stat.size > 65536) process.exitCode = 1;
  else {
    const data = Buffer.alloc(stat.size);
    if (fs.readSync(fd, data, 0, data.length, 0) === data.length) process.stdout.write(data);
    else process.exitCode = 1;
  }
} finally {
  fs.closeSync(fd);
}
