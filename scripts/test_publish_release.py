"""Local release API fixture. Run with python3 scripts/test_publish_release.py."""

import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import publish_release as release


class ReleaseReplayTest(unittest.TestCase):
    tag = "v1.2.3"
    commit = "a" * 40
    repo = "ntodd/foreman"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name) / "out"
        self.out.mkdir()
        self.notes = Path(tmp.name) / "notes.md"
        self.notes.write_text("Release notes\n")
        for name in release.asset_names(self.tag):
            (self.out / name).write_bytes(name.encode())
        self.remote = []
        self.assets = []
        self.mutations = []
        self.remote_commit = self.commit
        self.annotated = True
        self.leave_draft = False
        # How many reads of the release list still miss a draft just created.
        self.lag = 0
        self.unlisted = 0
        self.clock = 0.0
        self.sleeps = []
        for target, name, impl in ((release, "api", self.api), (release, "mutate", self.mutate),
                                   (release.time, "sleep", self.sleep),
                                   (release.time, "monotonic", lambda: self.clock)):
            stub = patch.object(target, name, impl)
            stub.start()
            self.addCleanup(stub.stop)

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.clock += seconds

    def api(self, endpoint, *args):
        base = "repos/ntodd/foreman/"
        self.assertTrue(endpoint.startswith(base))
        path = endpoint[len(base):]
        if path == "git/ref/tags/" + self.tag:
            if not self.annotated:
                return {"object": {"type": "commit", "sha": self.remote_commit}}
            return {"object": {"type": "tag", "sha": "b" * 40}}
        if path == "git/tags/" + "b" * 40:
            return {"object": {"type": "commit", "sha": self.remote_commit}}
        if path == "releases?per_page=100":
            self.assertEqual(args, ("--paginate", "--slurp"))
            if self.unlisted:
                self.unlisted -= 1
                return [[], []]
            return [[], self.remote]
        if path == "releases/1":
            return self.remote[0]
        if path == "releases/1/assets?per_page=100":
            self.assertEqual(args, ("--paginate", "--slurp"))
            return [self.assets[:2], self.assets[2:]]
        self.fail(f"unexpected API call {path}")

    def mutate(self, *args):
        self.mutations.append(args)
        if args[:3] == ("release", "create", self.tag):
            self.assertIn("--draft", args)
            self.assertIn("--verify-tag", args)
            self.remote.append(dict(id=1, tag_name=self.tag, draft=True, prerelease=False,
                                    name="Foreman 1.2.3", body=self.notes.read_text()))
            self.unlisted = self.lag
        elif args[:3] == ("release", "upload", self.tag):
            self.assertNotIn("--clobber", args)
            for path in self.out.iterdir():
                if str(path) in args:
                    self.assertFalse(any(a["name"] == path.name for a in self.assets))
                    data = path.read_bytes()
                    self.assets.append(dict(id=len(self.assets) + 1, name=path.name, state="uploaded",
                                            size=len(data), digest="sha256:" + hashlib.sha256(data).hexdigest()))
        elif args[:3] == ("release", "edit", self.tag):
            self.assertIn("--verify-tag", args)
            if not self.leave_draft:
                self.remote[0]["draft"] = False
        elif args[:3] == ("api", "-X", "DELETE"):
            asset_id = int(args[3].split("/")[-1])
            self.assets = [a for a in self.assets if a["id"] != asset_id]
        else:
            self.fail(f"unexpected mutation {args}")
        # The remote applied the change, but every acknowledgement was lost.
        return 1

    def publish(self):
        release.publish(self.repo, self.tag, self.commit, self.notes, self.out)

    def test_lost_acknowledgements_then_replay(self):
        self.annotated = False
        self.publish()
        self.assertEqual(len(self.assets), 10)
        self.assertFalse(self.remote[0]["draft"])
        self.mutations.clear()
        self.publish()
        self.assertEqual(self.mutations, [])

    def test_resume_matching_partial_draft(self):
        self.publish()
        self.remote[0]["draft"] = True
        self.assets.pop()
        self.assets[-1].update(state="starter", size=0, digest=None)
        self.mutations.clear()
        self.publish()
        self.assertEqual(len(self.assets), 10)
        self.assertFalse(self.remote[0]["draft"])
        self.assertEqual([call[1] for call in self.mutations], ["-X", "upload", "edit"])

    def test_mismatches_fail_before_any_mutation(self):
        self.publish()
        asset = self.assets[0].copy()
        for draft in (True, False):
            for change in (dict(digest="sha256:" + "0" * 64), dict(name="unexpected"),
                           dict(size=0), dict(state="broken")):
                with self.subTest(draft=draft, change=change):
                    self.remote[0]["draft"] = draft
                    self.assets[0] = dict(asset, **change)
                    self.mutations.clear()
                    with self.assertRaises(ValueError):
                        self.publish()
                    self.assertEqual(self.mutations, [])
        self.assets[0] = asset
        self.remote[0]["draft"] = False
        self.assets.pop()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.publish()
        self.assertEqual(self.mutations, [])

    def test_fallback_hashes_asset_contents(self):
        self.publish()
        self.mutations.clear()
        asset = self.assets[0]
        correct = asset.pop("digest")
        with patch.object(release, "download_digest", return_value=correct) as download:
            self.publish()
            download.assert_called_once_with(f"repos/{self.repo}/releases/assets/{asset['id']}")
        with patch.object(release, "download_digest", return_value="sha256:" + "0" * 64):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                self.publish()
        self.assertEqual(self.mutations, [])

    def test_fallback_stream_preserves_control_bytes(self):
        root = self.out.parent
        gh = root / "gh"
        gh.write_text(
            '#!/bin/sh\n'
            'case " $* " in *" --allow-escape-sequences "*) cat "$TEST_ASSET" ;; *) exit 1 ;; esac\n'
        )
        gh.chmod(0o755)
        blob = root / "asset.bin"
        blob.write_bytes(bytes(range(256)) * 4097)
        env = {"PATH": str(root) + os.pathsep + os.environ["PATH"], "TEST_ASSET": str(blob)}
        with patch.dict(os.environ, env):
            self.assertEqual(release.download_digest("repos/example/repo/releases/assets/1"),
                             "sha256:" + hashlib.sha256(blob.read_bytes()).hexdigest())

    def test_moved_tag_and_edited_release(self):
        self.publish()
        self.mutations.clear()
        self.remote_commit = "c" * 40
        with self.assertRaisesRegex(ValueError, "commit"):
            self.publish()
        self.remote_commit = self.commit
        self.remote[0]["body"] = "Other release"
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.publish()
        self.assertEqual(self.mutations, [])

    def test_draft_listed_a_moment_after_it_is_created(self):
        # The list trails a new draft by a second or two. One read straight
        # after creating it failed every release (#440).
        self.lag = 2
        self.publish()
        self.assertEqual(len(self.assets), 10)
        self.assertFalse(self.remote[0]["draft"])
        self.assertEqual([call[1] for call in self.mutations], ["create", "upload", "edit"])
        self.assertEqual(len(self.sleeps), 2)

    def test_draft_that_never_lists_fails_after_a_bounded_wait(self):
        self.lag = 10 ** 6
        with self.assertRaisesRegex(ValueError, "release draft was not created"):
            self.publish()
        self.assertEqual([call[1] for call in self.mutations], ["create"])
        self.assertGreaterEqual(self.clock, 10)
        self.assertLessEqual(self.clock, 120)

    def test_existing_release_is_not_waited_for(self):
        self.publish()
        self.sleeps.clear()
        self.publish()
        self.assertEqual(self.sleeps, [])

    def test_incomplete_publish_does_not_report_success(self):
        self.leave_draft = True
        with self.assertRaisesRegex(ValueError, "draft"):
            self.publish()


if __name__ == "__main__":
    unittest.main()
