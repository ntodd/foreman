defmodule ForemanAgent.IdentityDamageTest do
  # Identity.load runs when the connection starts; anything it raises
  # crash-loops the connection instead of logging and retrying.
  use ExUnit.Case, async: true

  alias ForemanAgent.Identity

  @moduletag :tmp_dir

  for {name, json} <- [
        {"a null private key", ~s({"agent_id": "a", "private_key": null})},
        {"a numeric private key", ~s({"agent_id": "a", "private_key": 1})},
        {"a numeric agent id",
         ~s({"agent_id": 1, "private_key": "#{Base.encode64(String.duplicate("k", 32))}"})},
        {"a key of the wrong length",
         ~s({"agent_id": "a", "private_key": "#{Base.encode64("short")}"})},
        {"an empty file", ""},
        {"a top-level array", ~s([1, 2])}
      ] do
    test "#{name} is an error, not a crash", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "identity.json"), unquote(json))
      assert {:error, _} = Identity.load(dir)
    end
  end

  test "a saved identity loads", %{tmp_dir: dir} do
    {_public, private} = ForemanProtocol.Auth.generate_keypair()
    identity = %Identity{agent_id: "a1", private_key: private}
    :ok = Identity.save(dir, identity)
    assert {:ok, ^identity} = Identity.load(dir)
  end
end
