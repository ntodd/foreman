defmodule ForemanProtocol.JsoncTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Jsonc

  test "parses plain JSON" do
    assert {:ok, %{"a" => [1, 2]}} = Jsonc.decode(~s({"a": [1, 2]}))
  end

  test "strips line and block comments" do
    input = """
    {
      // the name
      "name": "x", /* inline */
      /* multi
         line */
      "n": 1
    }
    """

    assert {:ok, %{"name" => "x", "n" => 1}} = Jsonc.decode(input)
  end

  test "keeps comment-like text inside strings" do
    input =
      ~s({"url": "https://example.com/a//b", "glob": "/* not a comment */", "q": "say \\"//hi\\""})

    assert {:ok, decoded} = Jsonc.decode(input)
    assert decoded["url"] == "https://example.com/a//b"
    assert decoded["glob"] == "/* not a comment */"
    assert decoded["q"] == ~s(say "//hi")
  end

  test "allows trailing commas" do
    assert {:ok, %{"a" => [1, 2], "b" => %{"c" => 1}}} =
             Jsonc.decode(~s({"a": [1, 2,], "b": {"c": 1,},}))
  end

  test "keeps commas inside strings" do
    assert {:ok, %{"a" => "x,}"}} = Jsonc.decode(~s({"a": "x,}"}))
  end

  test "reports invalid input without echoing it" do
    assert {:error, message} = Jsonc.decode(~s({"secret": "hunter2" oops}))
    refute message =~ "hunter2"
  end

  test "accepts a leading UTF-8 BOM for decoding and key ordering" do
    json = <<0xEF, 0xBB, 0xBF>> <> ~s({"z": 1, "a": 2,})
    assert {:ok, %{"z" => 1, "a" => 2}} = Jsonc.decode(json)
    assert Jsonc.key_order(json, []) == ["z", "a"]
  end

  test "reports the original byte offset after a BOM, comment and trailing comma" do
    prefix = <<0xEF, 0xBB, 0xBF>> <> ~s({/*é*/"list": [1,], "value": )
    assert Jsonc.decode(prefix <> "@}") == {:error, "invalid JSON at byte #{byte_size(prefix)}"}
  end

  test "rejects a top level that is not an object" do
    assert {:error, _} = Jsonc.decode("[1]")
  end

  describe "key_order/2" do
    @ordered """
    {
      // written this way on purpose
      "z": 1,
      "a": {"PATH": "${HOME}/bin", "HOME": "/opt", "nested": {"y": 1, "x": 2}},
      "list": [{"b": 1, "a": 2}],
      "m": "text",
    }
    """

    test "is an object's keys in the order they're written" do
      assert Jsonc.key_order(@ordered, []) == ["z", "a", "list", "m"]
      assert Jsonc.key_order(@ordered, ["a"]) == ["PATH", "HOME", "nested"]
      assert Jsonc.key_order(@ordered, ["a", "nested"]) == ["y", "x"]
    end

    test "is empty for what isn't an object, isn't there, or isn't JSON" do
      assert Jsonc.key_order(@ordered, ["m"]) == []
      assert Jsonc.key_order(@ordered, ["list"]) == []
      assert Jsonc.key_order(@ordered, ["nope", "deeper"]) == []
      assert Jsonc.key_order("{oops", []) == []
      assert Jsonc.key_order("[1]", []) == []
    end
  end
end
