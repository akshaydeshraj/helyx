defmodule Helyx.CoreTest do
  use ExUnit.Case, async: true

  alias Helyx.Test

  @interfaces [Test.Single, Test.Multi, Test.Required]

  defp boot(plugins, opts \\ []) do
    name = :"core_#{System.unique_integer([:positive])}"
    Helyx.Core.start_link([name: name, plugins: plugins] ++ opts)
  end

  test "boots with one plugin per single interface and any number per multi interface" do
    assert {:ok, _} =
             boot([Test.SingleA, Test.MultiA, Test.MultiB, Test.RequiredA],
               interfaces: @interfaces
             )
  end

  test "exposes the registered plugins per interface" do
    name = :"core_#{System.unique_integer([:positive])}"
    plugins = [Test.SingleA, Test.MultiB, Test.MultiA, Test.RequiredA]

    {:ok, _} =
      start_supervised({Helyx.Core, name: name, plugins: plugins, interfaces: @interfaces})

    assert Helyx.Core.plugins(name, Test.Single) == [Test.SingleA]
    assert Helyx.Core.plugins(name, Test.Multi) == [Test.MultiB, Test.MultiA]
    assert Helyx.Core.plugins(name, Test.Required) == [Test.RequiredA]
  end

  test "rejects two plugins for a single interface" do
    assert {:error, {:mode_violation, Test.Single, [Test.SingleA, Test.SingleB]}} =
             boot([Test.SingleA, Test.SingleB, Test.RequiredA], interfaces: @interfaces)
  end

  test "rejects a missing plugin for a required interface" do
    assert {:error, {:missing_plugin, Test.Required}} =
             boot([Test.SingleA], interfaces: @interfaces)
  end

  test "rejects a module that implements no interface" do
    assert {:error, {:not_a_plugin, Test.NoInterface}} =
             boot([Test.NoInterface, Test.RequiredA], interfaces: @interfaces)
  end

  test "rejects a module that is not an interface in the interface list" do
    assert {:error, {:not_an_interface, Test.NoInterface}} =
             boot([Test.RequiredA], interfaces: [Test.NoInterface])
  end

  test "checks a plugin's interface even when it is not in the interface list" do
    assert {:error, {:mode_violation, Test.Single, [Test.SingleA, Test.SingleB]}} =
             boot([Test.SingleA, Test.SingleB], interfaces: [])
  end

  test "requires a provider by default" do
    assert {:error, {:missing_plugin, Helyx.Provider}} = boot([])
    assert {:ok, _} = boot([Test.Provider])
  end
end
