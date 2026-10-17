FROM hexpm/elixir:1.20.4-erlang-29.1.1-ubuntu-jammy-20260810
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
     build-essential ca-certificates curl git jq sysbench fio iperf3 time bc \
     postgresql-client inotify-tools python3 pkg-config \
  && rm -rf /var/lib/apt/lists/*
