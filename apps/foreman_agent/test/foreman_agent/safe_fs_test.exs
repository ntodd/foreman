defmodule ForemanAgent.SafeFSTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.SafeFS

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(Path.join(root, ".devcontainer"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "agent private key")
    %{root: root, outside: outside}
  end

  describe "resolve/2" do
    test "resolves a regular file inside the root", %{root: root} do
      File.write!(Path.join(root, ".devcontainer/devcontainer.json"), "{}")

      assert {:ok, path} = SafeFS.resolve(root, ".devcontainer/devcontainer.json")
      assert path == Path.join(root, ".devcontainer/devcontainer.json")
    end

    test "follows symlinks that stay inside the root", %{root: root} do
      File.write!(Path.join(root, "real.json"), "{}")
      File.ln_s!("../real.json", Path.join(root, ".devcontainer/devcontainer.json"))

      assert {:ok, path} = SafeFS.resolve(root, ".devcontainer/devcontainer.json")
      assert path == Path.join(root, "real.json")
    end

    test "refuses symlinks that leave the root", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret"), Path.join(root, ".devcontainer/devcontainer.json"))
      assert {:error, :escapes_root} = SafeFS.resolve(root, ".devcontainer/devcontainer.json")

      File.ln_s!(outside, Path.join(root, "linkdir"))
      assert {:error, :escapes_root} = SafeFS.resolve(root, "linkdir/secret")
    end

    test "refuses relative escapes", %{root: root} do
      assert {:error, :escapes_root} = SafeFS.resolve(root, "../outside/secret")
      assert {:error, :escapes_root} = SafeFS.resolve(root, ".devcontainer/../../outside/secret")
    end

    test "refuses symlink loops", %{root: root} do
      File.ln_s!("b", Path.join(root, "a"))
      File.ln_s!("a", Path.join(root, "b"))
      assert {:error, :too_many_links} = SafeFS.resolve(root, "a")
    end

    test "reports missing files", %{root: root} do
      assert {:error, :enoent} = SafeFS.resolve(root, ".devcontainer/missing.json")
    end
  end

  describe "read/3" do
    test "reads files inside the root with a size cap", %{root: root} do
      File.write!(Path.join(root, "a.json"), "{}")
      assert {:ok, "{}"} = SafeFS.read(root, "a.json", max_bytes: 10)

      File.write!(Path.join(root, "big.json"), String.duplicate("x", 11))
      assert {:error, :too_large} = SafeFS.read(root, "big.json", max_bytes: 10)
    end

    test "never reads through an escaping symlink", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret"), Path.join(root, "a.json"))
      assert {:error, :escapes_root} = SafeFS.read(root, "a.json", max_bytes: 1000)
    end
  end

  describe "ensure_dir/2" do
    test "creates nested directories", %{root: root} do
      assert {:ok, dir} = SafeFS.ensure_dir(root, ".devcontainer/.foreman")
      assert File.dir?(dir)
    end

    test "replaces a symlink at a path the agent owns instead of following it", %{
      root: root,
      outside: outside
    } do
      File.ln_s!(outside, Path.join(root, ".devcontainer/.foreman"))

      assert {:ok, dir} = SafeFS.ensure_dir(root, ".devcontainer/.foreman")
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(dir)
      assert File.read!(Path.join(outside, "secret")) == "agent private key"
    end

    test "refuses when a parent is a symlink", %{root: root, outside: outside} do
      File.rm_rf!(Path.join(root, ".devcontainer"))
      File.ln_s!(outside, Path.join(root, ".devcontainer"))

      assert {:error, :symlink_in_path} = SafeFS.ensure_dir(root, ".devcontainer/.foreman")
      refute File.exists?(Path.join(outside, ".foreman"))
    end

    test "follows a parent symlink that stays inside the root", %{root: root} do
      File.rm_rf!(Path.join(root, ".devcontainer"))
      File.mkdir_p!(Path.join(root, "tools/devcontainer"))
      File.ln_s!("tools/devcontainer", Path.join(root, ".devcontainer"))

      assert {:ok, dir} = SafeFS.ensure_dir(root, ".devcontainer/.foreman")
      assert dir == Path.join(Path.expand(root), "tools/devcontainer/.foreman")
      assert File.dir?(dir)
    end

    test "replaces a regular file in the way", %{root: root} do
      File.write!(Path.join(root, ".devcontainer/.foreman"), "x")
      assert {:ok, dir} = SafeFS.ensure_dir(root, ".devcontainer/.foreman")
      assert File.dir?(dir)
    end
  end

  describe "write_atomic/3" do
    test "writes with the given mode and replaces atomically", %{root: root} do
      path = Path.join(root, "secrets.env")
      assert :ok = SafeFS.write_atomic(path, "A=1", 0o600)
      assert File.read!(path) == "A=1"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert :ok = SafeFS.write_atomic(path, "A=2", 0o600)
      assert File.read!(path) == "A=2"
      assert Path.wildcard(Path.join(root, ".secrets.env.*")) == []
    end

    test "replaces a symlink rather than writing through it", %{root: root, outside: outside} do
      path = Path.join(root, "github-token")
      File.ln_s!(Path.join(outside, "secret"), path)

      assert :ok = SafeFS.write_atomic(path, "token", 0o600)
      assert File.read!(Path.join(outside, "secret")) == "agent private key"
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(path)
    end
  end

  describe "append_line/3" do
    test "appends a line once", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git/info"))
      assert :ok = SafeFS.append_line(root, ".git/info/exclude", "/.devcontainer/.foreman/")
      assert :ok = SafeFS.append_line(root, ".git/info/exclude", "/.devcontainer/.foreman/")
      assert File.read!(Path.join(root, ".git/info/exclude")) == "/.devcontainer/.foreman/\n"
    end

    test "refuses to append through a symlink", %{root: root, outside: outside} do
      File.mkdir_p!(Path.join(root, ".git/info"))
      File.ln_s!(Path.join(outside, "secret"), Path.join(root, ".git/info/exclude"))

      assert {:error, _} = SafeFS.append_line(root, ".git/info/exclude", "x")
      assert File.read!(Path.join(outside, "secret")) == "agent private key"
    end
  end
end
