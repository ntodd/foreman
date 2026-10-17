#!/bin/bash
# The benchmark matrix, one configuration at a time so they don't compete:
# the same 4 CPU / 8 GB environment in a container and in a VM, each with
# the full workload suite and the lifecycle timings. Run as root after
# `bench.sh setup`.
#   e2e/vmbench/matrix.sh [label-suffix]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
suffix=${1:-}
export REPS=${REPS:-3}

clean_box_docker() {
  # A cold start for the container box: no images or build cache, except
  # the control plane's (in use, so prune keeps it).
  docker system prune -af --volumes >/dev/null
}

clean_box_docker
bash "$here/bench.sh" run bench-ct "ct-4$suffix" 4 8192
bash "$here/bench.sh" lifecycle bench-ct "ct-4$suffix" 4 8192

bash "$here/bench.sh" run bench-vm "vm-4$suffix" 4 8192
bash "$here/bench.sh" lifecycle bench-vm "vm-4$suffix" 4 8192
echo "matrix done"
