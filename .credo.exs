# One Credo run from the root covers the plugins too; they have no config of
# their own.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "plugins/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        disabled: [
          # In Helyx.Core the alias for Helyx.Core.Plugins would expand inside
          # Module.concat(name, Plugins) and silently rename the registry.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
