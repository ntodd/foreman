defmodule ForemanProtocol.ConnectTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.{Command, Connect}

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  @describe %{
    "label" => "Orca",
    "actions" => [
      %{"id" => "desktop", "label" => "Pair a desktop", "confirm" => "Orca restarts."},
      %{"id" => "mobile", "label" => "Pair a phone"}
    ]
  }

  describe "name?/1" do
    test "takes short lowercase names" do
      assert Connect.name?("orca")
      assert Connect.name?("my-tool2")
    end

    test "refuses anything that could be a path or an option" do
      for name <- ["", "-x", "../orca", "a/b", "Orca", "orca.sh", String.duplicate("a", 33), nil],
          do: refute(Connect.name?(name), inspect(name))
    end
  end

  describe "cast_hook/2" do
    test "keeps the name, label and actions" do
      assert {:ok, hook} = Connect.cast_hook("orca", @describe)

      assert hook == %{
               "name" => "orca",
               "label" => "Orca",
               "actions" => [
                 %{"id" => "desktop", "label" => "Pair a desktop", "confirm" => "Orca restarts."},
                 %{"id" => "mobile", "label" => "Pair a phone", "confirm" => nil}
               ]
             }
    end

    test "ignores fields it doesn't know, so hooks can grow" do
      describe = Map.put(@describe, "icon", "boat")
      assert {:ok, hook} = Connect.cast_hook("orca", describe)
      refute Map.has_key?(hook, "icon")
    end

    test "refuses what doesn't fit" do
      long = String.duplicate("x", 61)
      action = %{"id" => "desktop", "label" => "Pair"}

      for {describe, why} <- [
            {%{"actions" => [action]}, "no label"},
            {%{"label" => long, "actions" => [action]}, "long label"},
            {%{"label" => "Orca", "actions" => []}, "no actions"},
            {%{"label" => "Orca", "actions" => List.duplicate(action, 5)}, "too many actions"},
            {%{"label" => "Orca", "actions" => [%{action | "id" => "Desk top"}]}, "bad id"},
            {%{"label" => "Orca", "actions" => [action, action]}, "duplicate ids"},
            {%{"label" => "Orca", "actions" => [Map.put(action, "confirm", 3)]}, "bad confirm"},
            {%{"label" => "Or\nca", "actions" => [action]}, "control characters"},
            {"Orca", "not an object"}
          ] do
        assert {:error, _} = Connect.cast_hook("orca", describe), why
      end

      assert {:error, _} = Connect.cast_hook("../x", @describe)
    end
  end

  describe "cast_hooks/1" do
    test "keeps the valid hooks from a stored list, sorted by name" do
      {:ok, orca} = Connect.cast_hook("orca", @describe)
      {:ok, zed} = Connect.cast_hook("zed", @describe)

      assert Connect.cast_hooks([zed, %{"name" => "bad"}, orca, "junk"]) == [orca, zed]
    end

    test "takes at most eight" do
      hooks =
        for n <- 1..10 do
          {:ok, hook} = Connect.cast_hook("hook-#{n}", @describe)
          hook
        end

      assert length(Connect.cast_hooks(hooks)) == 8
    end

    test "reads anything else as no hooks" do
      assert Connect.cast_hooks(nil) == []
      assert Connect.cast_hooks(%{"orca" => @describe}) == []
    end
  end

  describe "action?/3" do
    test "whether a hook offers an action" do
      {:ok, orca} = Connect.cast_hook("orca", @describe)

      assert Connect.action?([orca], "orca", "mobile")
      refute Connect.action?([orca], "orca", "tablet")
      refute Connect.action?([orca], "other", "mobile")
    end
  end

  describe "cast_offer/1" do
    test "keeps the value, whether to show it as a QR code, and a note" do
      offer = %{"value" => "orca://pair?code=abc", "qr" => true, "note" => "Scan it."}
      assert Connect.cast_offer(offer) == {:ok, offer}
    end

    test "defaults qr and note" do
      assert Connect.cast_offer(%{"value" => "abc"}) ==
               {:ok, %{"value" => "abc", "qr" => false, "note" => nil}}
    end

    test "refuses what doesn't fit" do
      for {offer, why} <- [
            {%{}, "no value"},
            {%{"value" => ""}, "empty value"},
            {%{"value" => String.duplicate("x", 2049)}, "long value"},
            # Counted in bytes: a QR code holds bytes.
            {%{"value" => String.duplicate("界", 700)}, "long in bytes"},
            {%{"value" => "a\nb"}, "control characters"},
            {%{"value" => "abc", "qr" => "yes"}, "bad qr"},
            {%{"value" => "abc", "note" => String.duplicate("x", 301)}, "long note"},
            {[], "not an object"}
          ] do
        assert {:error, _} = Connect.cast_offer(offer), why
      end
    end
  end

  describe "cast_error/1" do
    test "a failed run's own explanation, if it printed one" do
      assert Connect.cast_error(%{"error" => "no pairing offer after 120s"}) ==
               {:ok, "no pairing offer after 120s"}
    end

    test "nothing else counts as one" do
      for bad <- [%{}, %{"error" => ""}, %{"error" => "a\nb"}, %{"error" => 3}, "x"],
          do: assert(:error = Connect.cast_error(bad), inspect(bad))
    end
  end

  describe "env.connect" do
    test "names the hook and the action" do
      assert {:ok, cmd} =
               Command.new("env.connect", %{
                 "env_id" => @env_id,
                 "slug" => "storefront-2",
                 "hook" => "orca",
                 "action" => "desktop"
               })

      assert cmd.payload.hook == "orca"
      assert cmd.payload.action == "desktop"
    end

    test "refuses a hook name that isn't one" do
      assert {:error, _} =
               Command.new("env.connect", %{
                 "env_id" => @env_id,
                 "slug" => "storefront-2",
                 "hook" => "../../bin/sh",
                 "action" => "desktop"
               })
    end
  end
end
