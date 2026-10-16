// Parses one compose file for ForemanAgent.Env.ComposeScan and prints it
// as JSON: node compose_yaml.js <file>
//
// js-yaml (vendored, see js-yaml.js) resolves anchors and aliases the way
// compose does. The core schema leaves `<<` merge keys as ordinary keys
// holding the merged maps, so the scan sees every value a merge could
// produce. Compose's own tags (!reset, !override) only change how files
// merge and are read as plain values; any other tag is an error, as are
// duplicate keys (compose refuses those too).
//
// Exit codes: 0 parsed, 2 not YAML compose could read, 3 too large.
"use strict";
const fs = require("fs");
const yaml = require("./js-yaml.js");

const MAX_BYTES = 1048576;
const MAX_NODES = 100000;

const tags = ["!reset", "!override"].flatMap((tag) =>
  ["scalar", "sequence", "mapping"].map((kind) => new yaml.Type(tag, { kind, construct: (d) => d }))
);
const schema = yaml.CORE_SCHEMA.extend(tags);

function fail(code, message) {
  process.stderr.write(message + "\n");
  process.exit(code);
}

// Aliases share structure, so a walk over them can be exponential: stop
// at a budget rather than expanding without end.
function count(value, budget) {
  if (budget < 0) return budget;
  budget -= 1;
  if (Array.isArray(value)) {
    for (const v of value) if ((budget = count(v, budget)) < 0) return budget;
  } else if (value !== null && typeof value === "object") {
    for (const k of Object.keys(value)) if ((budget = count(value[k], budget)) < 0) return budget;
  }
  return budget;
}

const text = fs.readFileSync(process.argv[2], "utf8");
if (Buffer.byteLength(text) > MAX_BYTES) fail(3, "larger than 1 MiB");

let doc;
try {
  doc = yaml.load(text, { schema });
} catch (e) {
  fail(2, String(e.message).split("\n")[0]);
}

if (count(doc, MAX_NODES) < 0) fail(3, "too large once its aliases are expanded");
process.stdout.write(JSON.stringify(doc === undefined ? null : doc));
