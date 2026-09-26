defmodule Helyx.ProviderTest do
  use ExUnit.Case, async: true

  # `Helyx.Provider.turn/1` reads `function_exported?/3`, which needs the
  # module loaded. In a session, Core start loads it, because it calls `id/0`.
  setup do
    Code.ensure_loaded!(Helyx.Test.Provider)
    Code.ensure_loaded!(Helyx.Test.Harness)
    :ok
  end

  test "a provider with no turn/0 gets a local turn" do
    refute function_exported?(Helyx.Test.Provider, :turn, 0)
    assert Helyx.Provider.turn(Helyx.Test.Provider) == {:ok, :local}
  end

  test "a provider whose turn/0 returns :external gets an external turn" do
    assert Helyx.Provider.turn(Helyx.Test.Harness) == {:ok, :external}
  end
end
