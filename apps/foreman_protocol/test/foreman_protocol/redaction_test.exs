defmodule ForemanProtocol.RedactionTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Redaction

  test "replaces values, longest first, and skips short ones" do
    r = Redaction.prepare(["abcdef123", "abcdef123456", "on", nil])
    assert Redaction.redact(r, "x abcdef123456 y abcdef123 z on") == "x [redacted] y [redacted] z on"
  end

  test "matches the lines of a multi-line value" do
    r = Redaction.prepare(["-----BEGIN-----\nsecretline1\n-----END-----"])
    assert Redaction.redact(r, "saw secretline1") == "saw [redacted]"
  end

  test "nothing to redact leaves text alone" do
    assert Redaction.redact(Redaction.prepare([]), "text") == "text"
  end
end
