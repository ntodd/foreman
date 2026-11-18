// The VMM can rename its logs while the agent is collecting stats.
// Open without following links or truncating. Check and trim the same inode.
const fs = require("node:fs");
const { O_WRONLY, O_NOFOLLOW, O_NONBLOCK, O_NOCTTY } = fs.constants;
const [, , path, limit] = process.argv;
let fd;
try {
  fd = fs.openSync(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
  const stat = fs.fstatSync(fd);
  if (stat.isFile() && stat.nlink === 1 && stat.size > Number(limit)) {
    fs.ftruncateSync(fd, 0);
    fs.writeSync(fd, "[foreman: the console passed 16 MB and was cut]\n");
  }
} catch (error) {
  // A removed or replaced log can wait until the next stats sample.
  if (!["ENOENT", "ELOOP", "ENXIO"].includes(error.code)) throw error;
} finally {
  if (fd !== undefined) fs.closeSync(fd);
}
