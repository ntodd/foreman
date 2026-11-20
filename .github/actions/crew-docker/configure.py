"""Use this Crew runner's registry cache as the sole upstream for CI."""
import json
import tomllib
from pathlib import Path
from urllib.parse import urlsplit

CA = "/usr/local/share/ca-certificates/crew-cache.crt"


def cache_server(path, url):
    path.parent.mkdir(exist_ok=True)
    path.write_text(
        f"server = {json.dumps(url)}\n"
        f"ca = {json.dumps(CA)}\n"
        'capabilities = ["pull", "resolve"]\n'
        "override_path = true\n"
    )


def configure(certs):
    mirrors = {}
    for path in sorted(certs.glob("*/hosts.toml")):
        config = tomllib.loads(path.read_text())
        # Accept either Crew's original mirror or this job's resolver on retry.
        candidates = dict(config.get("host", {}))
        if "server" in config:
            candidates[config["server"]] = config
        for url, host in candidates.items():
            if host.get("ca") == CA and urlsplit(url).scheme == "https":
                mirrors[path.parent.name] = url
                break

    if "public.ecr.aws" not in mirrors:
        raise SystemExit("The Crew runner has no ECR Public cache configuration")

    # Docker and its embedded BuildKit read these files for each registry.
    # A mirror in [host] still falls back to the public server.
    cache = urlsplit(mirrors["public.ecr.aws"])
    for registry, url in mirrors.items():
        cache_server(certs / registry / "hosts.toml", url)

    # Crew rejects unknown prefixes. This also covers new registry names.
    cache_server(certs / "_default/hosts.toml", f"https://{cache.netloc}/v2/unconfigured")
    # The updater tests pushes and pulls against their own loopback registry.
    local = certs / "localhost:5000/hosts.toml"
    local.parent.mkdir(exist_ok=True)
    local.write_text('server = "http://localhost:5000"\n')
    print("Crew registry cache required for", ", ".join(mirrors))


if __name__ == "__main__":
    configure(Path("/etc/docker/certs.d"))
