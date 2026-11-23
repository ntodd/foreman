"""Publish or resume the tagged workflow's release, verifying the remote result."""

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def api(endpoint, *args):
    return json.loads(subprocess.check_output(["gh", "api", endpoint, *args]))


def mutate(*args):
    # GitHub can apply a mutation before the connection fails. Every caller
    # re-reads remote state before proceeding or reporting success.
    return subprocess.run(["gh", *args], check=False).returncode


def asset_names(tag):
    version = tag[1:]
    names = {f"foreman-cli-{tag}-SHA256SUMS", f"foreman-guest-{version}-linux-amd64.tar"}
    for arch in ("amd64", "arm64"):
        agent = f"foreman_agent-{version}-linux-{arch}.tar.gz"
        names.update([agent, agent + ".sig"])
        for system in ("darwin", "linux"):
            names.add(f"foreman-cli-{tag}-{system}-{arch}.tar.gz")
    return names


def digest(stream):
    h = hashlib.sha256()
    for block in iter(lambda: stream.read(1 << 20), b""):
        h.update(block)
    return "sha256:" + h.hexdigest()


def download_digest(endpoint):
    # Hash raw bytes in the pipe, including terminal escape codes in archives.
    with subprocess.Popen(["gh", "api", "--allow-escape-sequences", endpoint,
                           "-H", "Accept: application/octet-stream"],
                          stdout=subprocess.PIPE) as proc:
        checksum = digest(proc.stdout)
        if proc.wait():
            raise ValueError(f"could not verify asset bytes at {endpoint}")
        return checksum


def verify_tag(base, tag, commit):
    obj = api(f"{base}/git/ref/tags/{tag}")["object"]
    while obj["type"] == "tag":
        obj = api(f"{base}/git/tags/{obj['sha']}")["object"]
    if obj["type"] != "commit" or obj["sha"] != commit:
        raise ValueError(f"remote tag {tag} does not point to workflow commit {commit}")


def find_release(base, tag):
    pages = api(f"{base}/releases?per_page=100", "--paginate", "--slurp")
    matches = [row for page in pages for row in page if row["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError(f"ambiguous releases for {tag}")
    return matches[0] if matches else None


def inspect_release(base, row, tag, notes, expected):
    if (row["tag_name"] != tag or row["prerelease"] or row["name"] != f"Foreman {tag[1:]}"
            or (row["body"] or "").splitlines() != notes.splitlines()):
        raise ValueError(f"release metadata differs for {tag}")

    pages = api(f"{base}/releases/{row['id']}/assets?per_page=100", "--paginate", "--slurp")
    missing = set(expected)
    starters = []
    seen = set()
    for page in pages:
        for asset in page:
            name = asset["name"]
            if name not in expected or name in seen:
                raise ValueError(f"unexpected or duplicate release asset {name}")
            seen.add(name)
            if row["draft"] and asset["state"] == "starter" and asset["size"] == 0:
                # GitHub leaves this empty placeholder after a failed upload.
                starters.append(asset["id"])
                continue
            size, checksum = expected[name]
            if asset["state"] != "uploaded" or asset["size"] != size:
                raise ValueError(f"release asset {name} has a different size or upload state")
            remote = asset.get("digest") or download_digest(f"{base}/releases/assets/{asset['id']}")
            if remote != checksum:
                raise ValueError(f"release asset {name} has a different SHA-256")
            missing.remove(name)
    if not row["draft"] and missing:
        raise ValueError("published release is missing: " + ", ".join(sorted(missing)))
    return missing, starters


def publish(repo, tag, commit, notes_file, out):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("expected a stable release tag")
    names = asset_names(tag)
    if {p.name for p in out.iterdir()} != names:
        raise ValueError("local artifacts do not match the complete expected release")
    expected = {}
    for name in names:
        path = out / name
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError(f"invalid local release asset {name}")
        with path.open("rb") as f:
            expected[name] = (path.stat().st_size, digest(f))

    base = "repos/" + repo
    notes = notes_file.read_text()
    verify_tag(base, tag, commit)
    row = find_release(base, tag)
    if row is None:
        mutate("release", "create", tag, "--repo", repo, "--draft", "--verify-tag",
               "--target", commit, "--title", f"Foreman {tag[1:]}", "--notes-file", str(notes_file))
        row = find_release(base, tag)
        if row is None:
            raise ValueError("release draft was not created")

    endpoint = f"{base}/releases/{row['id']}"
    missing, starters = inspect_release(base, row, tag, notes, expected)
    if row["draft"]:
        # No assets are modified until every existing completed upload matches.
        for asset_id in starters:
            mutate("api", "-X", "DELETE", f"{base}/releases/assets/{asset_id}")
        if missing:
            mutate("release", "upload", tag, "--repo", repo, *(str(out / n) for n in sorted(missing)))
        row = api(endpoint)
        missing, _ = inspect_release(base, row, tag, notes, expected)
        if missing:
            raise ValueError("draft is missing verified assets: " + ", ".join(sorted(missing)))
        verify_tag(base, tag, commit)
        if row["draft"]:
            mutate("release", "edit", tag, "--repo", repo, "--verify-tag", "--draft=false")
        row = api(endpoint)
        if row["draft"]:
            raise ValueError("release remains a draft")
        inspect_release(base, row, tag, notes, expected)
    verify_tag(base, tag, commit)
    print(f"Verified published release {tag} and all {len(expected)} assets")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("Usage: publish_release.py TAG COMMIT NOTES_FILE ASSET_DIRECTORY")
    try:
        publish(os.environ["GITHUB_REPOSITORY"], sys.argv[1], sys.argv[2],
                Path(sys.argv[3]), Path(sys.argv[4]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
