defmodule ForemanProtocol.RedactionTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Redaction

  test "replaces values, longest first, and skips short ones" do
    r = Redaction.prepare(["abcdef123", "abcdef123456", "on", nil])

    assert Redaction.redact(r, "x abcdef123456 y abcdef123 z on") ==
             "x [redacted] y [redacted] z on"
  end

  test "matches the lines of a multi-line value" do
    r = Redaction.prepare(["-----BEGIN-----\nsecretline1\n-----END-----"])
    assert Redaction.redact(r, "saw secretline1") == "saw [redacted]"
  end

  test "nothing to redact leaves text alone" do
    assert Redaction.redact(Redaction.prepare([]), "text") == "text"
  end

  test "secrets that overlap in the text are both covered" do
    r = Redaction.prepare(["AKIAEXAMPLE-12", "EXAMPLE-12-SECRETTAIL"])
    assert Redaction.redact(r, "key=AKIAEXAMPLE-12-SECRETTAIL end") == "key=[redacted] end"
  end

  test "a value that overlaps itself is covered" do
    r = Redaction.prepare(["abcabcabc"])
    assert Redaction.redact(r, "x abcabcabcabcabc y") == "x [redacted] y"
    assert Redaction.redact(r, "abcabcabc abcabcabc") == "[redacted] [redacted]"
  end

  test "redacts text that isn't UTF-8 without raising" do
    r = Redaction.prepare(["secret-value"])
    assert Redaction.redact(r, <<0xFF, "secret-value", 0xE2>>) == <<0xFF, "[redacted]", 0xE2>>
  end

  test "still accepts a plain list of values" do
    assert Redaction.redact(["secret-value"], "a secret-value b") == "a [redacted] b"
    assert Redaction.redact([], "a") == "a"
    assert Redaction.redact(Redaction.prepare(["secret-value"]), nil) == nil
  end

  test "a prepared set can be stored in ETS and used from another process" do
    r = Redaction.prepare(["secret-value"])
    table = :ets.new(:redaction_test, [:public])
    :ets.insert(table, {:r, r})
    [{:r, stored}] = :ets.lookup(table, :r)

    assert fn -> Redaction.redact(stored, "a secret-value b") end
           |> Task.async()
           |> Task.await() == "a [redacted] b"
  end

  test "max_length/1 is the longest value's size in bytes" do
    assert Redaction.max_length(Redaction.prepare(["abcdef", "pässwörd-ü"])) == 13
    assert Redaction.max_length(Redaction.prepare([])) == 0
  end

  test "redacting a log line with a realistic set of values is cheap" do
    pem =
      "-----BEGIN PRIVATE KEY-----\n" <>
        Enum.map_join(1..26, "\n", fn _ -> Base.encode64(:crypto.strong_rand_bytes(48)) end) <>
        "\n-----END PRIVATE KEY-----\n"

    values = for i <- 1..12, do: "value-#{i}-" <> Base.encode16(:crypto.strong_rand_bytes(12))
    r = Redaction.prepare([pem | values])
    line = "#12 [build 3/9] RUN npm ci --no-audit  0.4s\n"

    {us, _} = :timer.tc(fn -> for _ <- 1..5_000, do: Redaction.redact(r, line) end)
    assert us / 5_000 < 20, "#{Float.round(us / 5_000, 1)} µs per line"
  end
end
