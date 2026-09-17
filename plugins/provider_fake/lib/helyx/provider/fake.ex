defmodule Helyx.Provider.Fake do
  @moduledoc """
  A provider that replays scripted responses. For tests and demos.

  The `echo` model streams the last user message back, one word per delta.
  Any other model name replays responses registered with `script/3`, one
  response per call, in order. A response is a list of text deltas.

      :ok = Helyx.Provider.Fake.script(core, "greeter", [["Hello", " there"]])
      {:ok, session} = Helyx.Session.start(core, model: "fake/greeter")

  Scripts live in an Agent that Core starts with the plugin, so each Core
  instance has its own scripts.
  """

  @behaviour Helyx.Provider

  @impl true
  def id, do: "fake"

  @doc "Starts the scripts Agent under Core. Core calls this with `core: name`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    core = Keyword.fetch!(opts, :core)
    %{id: __MODULE__, start: {Agent, :start_link, [fn -> %{} end, [name: scripts(core)]]}}
  end

  @doc "Registers the responses a scripted model replays, one per call."
  @spec script(Helyx.Core.name(), String.t(), [[String.t()]]) :: :ok
  def script(core, model, responses) when is_list(responses) do
    Agent.update(scripts(core), &Map.put(&1, model, responses))
  end

  @impl true
  def stream("echo", %Helyx.Context{messages: messages}, _opts) do
    text =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))
      |> Helyx.Message.text()

    {:ok, deltas_to_stream(words(text))}
  end

  def stream(model, _context, opts) do
    core = Keyword.fetch!(opts, :core)

    Agent.get_and_update(scripts(core), fn state ->
      case Map.get(state, model) do
        [response | rest] -> {{:ok, deltas_to_stream(response)}, Map.put(state, model, rest)}
        _ -> {{:error, {:no_script, model}}, state}
      end
    end)
  end

  defp deltas_to_stream(deltas) do
    Stream.concat(
      Enum.map(deltas, &{:text_delta, &1}),
      [{:done, %{stop_reason: :end_turn, usage: %{}}}]
    )
  end

  # Splits "hello there" into ["hello", " there"], keeping the spaces.
  defp words(text) do
    Regex.scan(~r/\s*\S+/, text) |> List.flatten()
  end

  defp scripts(core), do: Module.concat(core, __MODULE__)
end
