defmodule ForemanAgent.Devcontainer.Features.OrderTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Features.{Order, Ref}

  defp oci(id, opts \\ []) do
    {:ok, ref} = Ref.parse(id)

    %{
      user_feature_id: id,
      options: Keyword.get(opts, :options, %{}),
      set: %{
        source: %{
          type: :oci,
          ref: ref,
          manifest_digest:
            Keyword.get(
              opts,
              :digest,
              "sha256:" <> Base.encode16(:crypto.hash(:sha256, id), case: :lower)
            ),
          user_feature_id: id
        }
      },
      depends_on: Keyword.get(opts, :depends_on, []),
      installs_after: Keyword.get(opts, :installs_after, []),
      aliases: Keyword.get(opts, :aliases),
      priority: Keyword.get(opts, :priority, 0)
    }
  end

  defp local(path, opts \\ []) do
    %{
      user_feature_id: "./" <> Path.basename(path),
      options: Keyword.get(opts, :options, %{}),
      set: %{
        source: %{
          type: :file_path,
          resolved_path: path,
          user_feature_id: "./" <> Path.basename(path)
        }
      },
      depends_on: Keyword.get(opts, :depends_on, []),
      installs_after: Keyword.get(opts, :installs_after, []),
      aliases: nil,
      priority: 0
    }
  end

  defp ids({:ok, nodes}), do: Enum.map(nodes, & &1.user_feature_id)

  describe "collate/2" do
    test "orders strings the way JavaScript's localeCompare does" do
      %{"strings" => strings, "signs" => signs} =
        "../../../fixtures/devcontainer/collation.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> JSON.decode!()

      pairs = for a <- strings, b <- strings, do: {a, b}

      for {{a, b}, expected} <- Enum.zip(pairs, signs) do
        actual =
          case Order.collate(a, b) do
            :lt -> -1
            :eq -> 0
            :gt -> 1
          end

        assert actual == expected,
               "#{inspect(a)} against #{inspect(b)}: expected #{expected}, got #{actual}"
      end
    end
  end

  describe "install_order/1" do
    test "features with nothing between them install in the order of their ids" do
      assert ids(
               Order.install_order([
                 oci("ghcr.io/o/features/b"),
                 oci("ghcr.io/o/features/a"),
                 oci("ghcr.io/a/features/z")
               ])
             ) ==
               ["ghcr.io/a/features/z", "ghcr.io/o/features/a", "ghcr.io/o/features/b"]
    end

    test "a feature installs after what it depends on" do
      b = oci("ghcr.io/o/features/b")
      a = oci("ghcr.io/o/features/a", depends_on: [b])

      assert ids(Order.install_order([a, b])) == ["ghcr.io/o/features/b", "ghcr.io/o/features/a"]
    end

    test "a hard dependency is the same feature with the same options" do
      wanted = oci("ghcr.io/o/features/b", options: %{"version" => "2"})
      a = oci("ghcr.io/o/features/a", depends_on: [wanted])

      # The b that's there has other options, so nothing satisfies a.
      assert Order.install_order([a, oci("ghcr.io/o/features/b", options: %{"version" => "1"})]) ==
               {:error, :circular, ["ghcr.io/o/features/a"]}

      assert ids(
               Order.install_order([
                 a,
                 oci("ghcr.io/o/features/b", options: %{"version" => "1"}),
                 wanted
               ])
             ) == [
               "ghcr.io/o/features/b",
               "ghcr.io/o/features/b",
               "ghcr.io/o/features/a"
             ]
    end

    test "a feature installs after a soft dependency that's being installed, at any version" do
      soft = oci("ghcr.io/o/features/common-utils")
      a = oci("ghcr.io/o/features/a", installs_after: [soft])

      assert ids(
               Order.install_order([
                 a,
                 oci("ghcr.io/o/features/common-utils:2", options: %{"x" => true})
               ])
             ) ==
               ["ghcr.io/o/features/common-utils:2", "ghcr.io/o/features/a"]
    end

    test "a soft dependency nobody installs doesn't hold a feature back" do
      a = oci("ghcr.io/o/features/a", installs_after: [oci("ghcr.io/o/features/common-utils")])

      assert ids(Order.install_order([a, oci("ghcr.io/o/features/b")])) ==
               ["ghcr.io/o/features/a", "ghcr.io/o/features/b"]
    end

    test "a soft dependency matches a feature that was renamed from it" do
      soft = oci("ghcr.io/o/features/new-name", aliases: ["new-name", "old-name"])
      a = oci("ghcr.io/o/features/a", installs_after: [soft])

      assert ids(Order.install_order([a, oci("ghcr.io/o/features/old-name")])) ==
               ["ghcr.io/o/features/old-name", "ghcr.io/o/features/a"]
    end

    test "local features compare by where they are" do
      first = local("/w/.devcontainer/first")
      second = local("/w/.devcontainer/second", installs_after: [local("/w/.devcontainer/first")])

      assert ids(Order.install_order([second, first])) == ["./first", "./second"]
    end

    test "features that wait on each other can't be ordered" do
      a = oci("ghcr.io/o/features/a", depends_on: [oci("ghcr.io/o/features/b")])
      b = oci("ghcr.io/o/features/b", depends_on: [oci("ghcr.io/o/features/a")])

      assert Order.install_order([a, b, oci("ghcr.io/o/features/c")]) ==
               {:error, :circular, ["ghcr.io/o/features/a", "ghcr.io/o/features/b"]}
    end

    test "a higher priority installs first among the features that are ready" do
      b = oci("ghcr.io/o/features/b", priority: 2)
      c = oci("ghcr.io/o/features/c", priority: 1)
      d = oci("ghcr.io/o/features/d", depends_on: [oci("ghcr.io/o/features/a")], priority: 3)

      # d has the highest priority but still waits for a.
      assert ids(Order.install_order([oci("ghcr.io/o/features/a"), b, c, d])) == [
               "ghcr.io/o/features/b",
               "ghcr.io/o/features/c",
               "ghcr.io/o/features/a",
               "ghcr.io/o/features/d"
             ]
    end
  end

  describe "prioritize/2" do
    test "gives the features an override names their place in it, first highest" do
      worklist = [
        oci("ghcr.io/o/features/a:1"),
        oci("ghcr.io/o/features/b"),
        oci("ghcr.io/o/features/c")
      ]

      overrides = [oci("ghcr.io/o/features/c"), oci("ghcr.io/o/features/a")]

      assert worklist
             |> Order.prioritize(overrides)
             |> Enum.map(&{&1.user_feature_id, &1.priority}) == [
               {"ghcr.io/o/features/a:1", 1},
               {"ghcr.io/o/features/b", 0},
               {"ghcr.io/o/features/c", 2}
             ]
    end
  end

  describe "equal?/2 and compare/2" do
    test "the same digest and options are the same feature, whatever tag named it" do
      a = oci("ghcr.io/o/features/a:1", digest: "sha256:aa")
      b = oci("ghcr.io/o/features/a:1.2", digest: "sha256:aa")

      assert Order.equal?(a, b)

      refute Order.equal?(
               a,
               oci("ghcr.io/o/features/a:1", digest: "sha256:aa", options: %{"x" => true})
             )

      refute Order.equal?(a, local("/w/.devcontainer/a"))
    end

    test "the same feature orders by tag, then options, then digest" do
      assert Order.compare(
               oci("ghcr.io/o/features/a:1", digest: "sha256:aa"),
               oci("ghcr.io/o/features/a:2", digest: "sha256:bb")
             ) == :lt

      assert Order.compare(
               oci("ghcr.io/o/features/a:1", digest: "sha256:aa", options: %{"x" => "b"}),
               oci("ghcr.io/o/features/a:1", digest: "sha256:aa", options: %{"x" => "a"})
             ) == :gt

      assert Order.compare(
               oci("ghcr.io/o/features/a:1", digest: "sha256:bb"),
               oci("ghcr.io/o/features/a:1", digest: "sha256:aa")
             ) == :gt
    end

    test "options compare by kind, by how many, by name, then by value" do
      option = fn a, b -> Order.compare(local("/w/x", options: a), local("/w/x", options: b)) end

      assert option.("a", "b") == :lt
      assert option.(false, true) == :lt
      assert option.(true, "a") == :lt
      assert option.(%{}, "a") == :lt
      assert option.(true, %{}) == :lt
      assert option.(%{"a" => 1}, %{"a" => 1, "b" => 2}) == :lt
      assert option.(%{"a" => "x"}, %{"b" => "x"}) == :lt
      assert option.(%{"a" => "x"}, %{"a" => "y"}) == :lt
      assert option.(%{"a" => true}, %{"a" => false}) == :gt
      # Values of different kinds are left alone, as the CLI leaves them.
      assert option.(%{"a" => true}, %{"a" => "true"}) == :eq
    end

    test "features of different kinds order by what the user called them" do
      assert Order.compare(local("/w/.devcontainer/zzz"), oci("ghcr.io/o/features/a")) == :lt
    end
  end
end
