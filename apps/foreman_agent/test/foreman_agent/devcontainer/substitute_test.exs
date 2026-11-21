defmodule ForemanAgent.Devcontainer.SubstituteTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Substitute

  @context %{
    local_workspace_folder: "/foo/bar",
    container_workspace_folder: "/baz/blue",
    env: %{"baz" => "somevalue"}
  }

  describe "local/2" do
    test "replaces env and localEnv from the local environment" do
      assert Substitute.local(%{"foo" => "bar${env:baz}bar"}, @context) ==
               {:ok, %{"foo" => "barsomevaluebar"}}

      assert Substitute.local("bar${localEnv:baz:default}bar", @context) ==
               {:ok, "barsomevaluebar"}
    end

    test "a variable that isn't set is its default, or empty" do
      context = %{@context | env: %{}}

      assert Substitute.local("bar${localEnv:baz:default}bar", context) == {:ok, "bardefaultbar"}

      assert Substitute.local("bar${localEnv:baz:default:a:b:c}bar", context) ==
               {:ok, "bardefaultbar"}

      assert Substitute.local("bar${localEnv:baz}bar", context) == {:ok, "barbar"}
    end

    test "replaces the workspace folders and their basenames" do
      assert Substitute.local("bar${localWorkspaceFolder}bar", @context) ==
               {:ok, "bar/foo/barbar"}

      assert Substitute.local("${localWorkspaceFolderBasename}", @context) == {:ok, "bar"}

      assert Substitute.local("bar${containerWorkspaceFolder}bar", @context) ==
               {:ok, "bar/baz/bluebar"}

      assert Substitute.local("${containerWorkspaceFolderBasename}", @context) == {:ok, "blue"}
    end

    test "the container workspace folder is substituted itself first" do
      context = %{
        @context
        | local_workspace_folder: "/foo/red",
          container_workspace_folder: "/baz/${localWorkspaceFolderBasename}"
      }

      assert Substitute.local("bar${containerWorkspaceFolder}bar", context) ==
               {:ok, "bar/baz/redbar"}
    end

    test "walks lists and nested maps, and leaves other values and variables alone" do
      value = %{
        "a" => ["${localEnv:baz}", 1, true, nil],
        "b" => %{"c" => "${containerEnv:PATH} ${nope}"}
      }

      assert Substitute.local(value, @context) ==
               {:ok,
                %{
                  "a" => ["somevalue", 1, true, nil],
                  "b" => %{"c" => "${containerEnv:PATH} ${nope}"}
                }}
    end

    test "keeps a folder variable that has no folder" do
      assert Substitute.local("${containerWorkspaceFolder}", %{env: %{}}) ==
               {:ok, "${containerWorkspaceFolder}"}
    end

    test "an environment variable with no name is an error" do
      assert Substitute.local(%{"x" => "${localEnv}"}, @context) ==
               {:error,
                "'${localEnv}' can not be resolved because no environment variable name is given."}
    end
  end

  describe "container_env/2" do
    test "replaces containerEnv from the container's environment" do
      assert Substitute.container_env(%{"p" => "${containerEnv:PATH}:/x"}, %{"PATH" => "/bin"}) ==
               {:ok, %{"p" => "/bin:/x"}}

      assert Substitute.container_env("bar${containerEnv:baz:default}bar", %{}) ==
               {:ok, "bardefaultbar"}

      assert Substitute.container_env("${localEnv:baz}", %{"baz" => "x"}) ==
               {:ok, "${localEnv:baz}"}
    end
  end

  describe "devcontainer_id/2" do
    test "replaces devcontainerId with the id of the labels" do
      assert Substitute.devcontainer_id(%{"v" => "vol-${devcontainerId}"}, ["a=b"]) ==
               %{"v" => "vol-1mqafr5h2iu6dhh3k1m4vtnuhml2uiec4s7bntt1v0f25ao63i1n"}
    end

    test "the id is the devcontainer CLI's, whatever order the labels come in" do
      assert Substitute.id_for_labels(["foreman.env_id=6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"]) ==
               "14hc2hhi4si9uhg5b17vg8229jse4p8fbbo5k69le7ui78mrrdj5"

      assert Substitute.id_for_labels(["c=d", "a=b"]) ==
               "1e2sfmkjt1sga649hgk0s5f3u6nlqhlv9al481r91s7gkeo32p3o"

      assert Substitute.id_for_labels(["a=b", "c=d"]) == Substitute.id_for_labels(["c=d", "a=b"])
    end
  end
end
