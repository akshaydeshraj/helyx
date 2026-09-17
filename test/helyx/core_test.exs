defmodule Helyx.CoreTest do
  use ExUnit.Case, async: true

  alias Helyx.Test

  defp boot(plugins) do
    name = :"core_#{System.unique_integer([:positive])}"
    Helyx.Core.start_link(name: name, plugins: plugins)
  end

  test "boots with one plugin per single interface and any number per multi interface" do
    assert {:ok, _} = boot([Test.Provider, Test.SingleA, Test.MultiA, Test.MultiB])
  end

  test "exposes the registered plugins per interface" do
    name = :"core_#{System.unique_integer([:positive])}"
    plugins = [Test.Provider, Test.SingleA, Test.MultiB, Test.MultiA]
    {:ok, _} = start_supervised({Helyx.Core, name: name, plugins: plugins})

    assert Helyx.Core.plugins(name, Test.Single) == [Test.SingleA]
    assert Helyx.Core.plugins(name, Test.Multi) == [Test.MultiB, Test.MultiA]
    assert Helyx.Core.plugins(name, Helyx.Provider) == [Test.Provider]
  end

  test "rejects two plugins for a single interface" do
    assert {:error, {:mode_violation, Test.Single, [Test.SingleA, Test.SingleB]}} =
             boot([Test.Provider, Test.SingleA, Test.SingleB])
  end

  test "rejects two model context plugins" do
    assert {:error, {:mode_violation, Helyx.ModelContext, _}} =
             boot([Test.Provider, Test.ModelContext, Test.ModelContextTwin])
  end

  test "rejects two compaction plugins" do
    assert {:error, {:mode_violation, Helyx.Compaction, _}} =
             boot([Test.Provider, Test.Compaction, Test.CompactionTwin])
  end

  test "rejects a missing provider" do
    assert {:error, {:missing_plugin, Helyx.Provider}} = boot([Test.SingleA])
  end

  test "rejects a module that does not exist" do
    assert {:error, {:not_a_plugin, Test.Missing}} = boot([Test.Provider, Test.Missing])
  end

  test "rejects a module that implements no interface" do
    assert {:error, {:not_a_plugin, Test.NoInterface}} = boot([Test.Provider, Test.NoInterface])
  end
end
