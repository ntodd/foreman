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

  test "rejects a top level that is not an object" do
    assert {:error, _} = Jsonc.decode("[1]")
  end
end
