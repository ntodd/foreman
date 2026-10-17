#!/bin/sh
# Builds the benchmark fixture repo: the devcontainer in repo/, plus the
# workloads it compiles. Writes a bare repo at <dir>/acme/vmbench.git that
# the agent can clone over git's dumb HTTP protocol (see e2e/make-git-fixture.sh).
#
#   e2e/vmbench/make-repo.sh <dir>
#
# Workloads: this checkout's control plane and protocol apps with their
# deps (an Elixir/Phoenix compile and a Postgres-backed test suite), Redis
# (a parallel C build) and a generated Vite + React + TypeScript project.
set -eu

dir=$1
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
redis_version=7.4.6
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
src="$dir/vmbench"

rm -rf "$src" "$dir/acme/vmbench.git"
cp -R "$here/repo" "$src"
mkdir -p "$src/workloads"

# The control plane at HEAD, with its fetched deps but nothing compiled.
tar -C "$root" -czf "$src/workloads/foreman.tar.gz" \
  --exclude='_build' --exclude='*.db' --exclude='*.db-*' --exclude='erl_crash.dump' \
  --exclude='node_modules' --exclude='tmp' --exclude='priv/static/assets' \
  apps/foreman apps/foreman_protocol

if [ ! -f "$dir/redis-$redis_version.tar.gz" ]; then
  curl -fsSL -o "$dir/redis-$redis_version.tar.gz" "https://download.redis.io/releases/redis-$redis_version.tar.gz"
fi
cp "$dir/redis-$redis_version.tar.gz" "$src/workloads/redis.tar.gz"

node="$src/workloads/node"
mkdir -p "$node/src/components"
cat > "$node/package.json" <<'EOF'
{
  "name": "vmbench-node",
  "private": true,
  "type": "module",
  "scripts": {"build": "tsc -p . && vite build"},
  "dependencies": {
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "zod": "3.25.76",
    "date-fns": "4.1.0",
    "lodash-es": "4.17.21",
    "@tanstack/react-query": "5.90.2"
  },
  "devDependencies": {
    "typescript": "5.9.3",
    "vite": "7.1.9",
    "@vitejs/plugin-react": "5.0.4",
    "@types/react": "18.3.26",
    "@types/react-dom": "18.3.7",
    "@types/lodash-es": "4.17.12",
    "eslint": "9.37.0",
    "prettier": "3.6.2",
    "tailwindcss": "4.1.14",
    "vitest": "3.2.4"
  }
}
EOF
cat > "$node/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler",
    "jsx": "react-jsx", "strict": true, "skipLibCheck": false,
    "outDir": "dist/tsc", "declaration": true
  },
  "include": ["src"]
}
EOF
cat > "$node/vite.config.ts" <<'EOF'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({ plugins: [react()], build: { outDir: "dist/vite" } });
EOF
cat > "$node/index.html" <<'EOF'
<!doctype html><html><body><div id="root"></div><script type="module" src="/src/main.tsx"></script></body></html>
EOF
i=0
imports=""
uses=""
while [ $i -lt 300 ]; do
  cat > "$node/src/components/Widget$i.tsx" <<EOF
import { useMemo, useState } from "react";
import { z } from "zod";
import { format, addDays } from "date-fns";
import { groupBy, sortBy } from "lodash-es";

export const Item$i = z.object({ id: z.number(), name: z.string(), tags: z.array(z.string()), due: z.date() });
export type Item$i = z.infer<typeof Item$i>;

export function Widget$i({ items }: { items: Item$i[] }) {
  const [days, setDays] = useState($i % 7);
  const groups = useMemo(() => groupBy(sortBy(items, (x) => x.name), (x) => x.tags[0] ?? "none"), [items]);
  return (
    <section onClick={() => setDays(days + 1)}>
      {Object.entries(groups).map(([tag, xs]) => (
        <ul key={tag}>{xs.map((x) => <li key={x.id}>{x.name} {format(addDays(x.due, days), "yyyy-MM-dd")}</li>)}</ul>
      ))}
    </section>
  );
}
EOF
  imports="$imports
import { Widget$i } from \"./components/Widget$i\";"
  uses="$uses<Widget$i items={[]} />"
  i=$((i + 1))
done
cat > "$node/src/main.tsx" <<EOF
import { createRoot } from "react-dom/client";
$imports
createRoot(document.getElementById("root")!).render(<>$uses</>);
EOF

# npm ci needs a lockfile; resolve it once and reuse it.
if [ ! -f "$dir/package-lock.json" ]; then
  (cd "$node" && npm install --package-lock-only --no-audit --no-fund >/dev/null)
  cp "$node/package-lock.json" "$dir/package-lock.json"
fi
cp "$dir/package-lock.json" "$node/package-lock.json"

chmod +x "$src/bench/run.sh"
(
  cd "$src"
  git init -q -b main
  git add -A
  git -c user.email=bench@foreman -c user.name=bench commit -qm "vmbench fixture"
)
mkdir -p "$dir/acme"
git clone -q --bare "$src" "$dir/acme/vmbench.git"
git -C "$dir/acme/vmbench.git" update-server-info
echo "$dir/acme/vmbench.git"
