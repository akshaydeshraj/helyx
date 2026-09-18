defmodule Helyx.SessionFile do
  @moduledoc """
  The session file: append-only JSON lines, one entry per line, per ADR 0001.

  A session lives at `<dir>/<project slug>/<session id>.jsonl`, where the
  slug is derived from the working directory. Every entry has an `id`, a
  `parent_id`, a `ts`, and a `type`. The first entry is the header, `type`
  `"session"`, and carries the format version, the working directory, and
  the model. Only completed messages are appended, never streamed partials.

  `resume/2` picks the most recently started session for a working
  directory, repairs a torn last line by truncating to the end of the last
  line that parses, and restores the transcript as written. Answering open
  tool calls is the session's job, not the file's.
  """

  alias Helyx.Message

  @version 1

  @enforce_keys [:path]
  defstruct [:path, :leaf]

  @type t :: %__MODULE__{path: Path.t(), leaf: String.t() | nil}

  defmodule Resumed do
    @moduledoc "What `resume/2` restores: the file, the session id, the model, and the transcript."
    @enforce_keys [:file, :session_id, :model, :messages]
    defstruct [:file, :session_id, :model, :messages]

    @type t :: %__MODULE__{
            file: Helyx.SessionFile.t(),
            session_id: String.t(),
            model: String.t(),
            messages: [Message.t()]
          }
  end

  @typedoc "Why a session cannot be created or resumed."
  @type error ::
          :not_found
          | File.posix()
          | {:unknown_version, term()}
          | {:invalid_file, String.t()}
          | {:repair_failed, File.posix()}
          | {:create_failed, File.posix() | :invalid_utf8}

  @doc "Creates the file for a new session and writes the header."
  @spec create(Path.t(), String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def create(dir, session_id, cwd, model) do
    # A cwd or model that is not UTF-8 cannot reach JSON, and the mkdir
    # failing is the caller's configuration, not a crash.
    with :ok <- valid_utf8(cwd, model),
         project = project_dir(dir, cwd),
         :ok <- File.mkdir_p(project) do
      header = %{"type" => "session", "version" => @version, "cwd" => cwd, "model" => model}
      {:ok, append(%__MODULE__{path: Path.join(project, session_id <> ".jsonl")}, header)}
    else
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  rescue
    # The header write failing right after the mkdir succeeded.
    error in File.Error -> {:error, {:create_failed, error.reason}}
  end

  defp valid_utf8(cwd, model) do
    if Message.valid_utf8?(cwd) and Message.valid_utf8?(model) do
      :ok
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Resumes the most recently started session for a working directory.

  Returns the file handle, the session id, the current model, and the
  transcript in file order.
  """
  @spec resume(Path.t(), String.t()) :: {:ok, Resumed.t()} | {:error, error()}
  def resume(dir, cwd) do
    with {:ok, path, header} <- most_recent(project_dir(dir, cwd), cwd),
         :ok <- check_version(header),
         {:ok, raw} <- File.read(path),
         {entries, kept, rest} = parse(raw),
         :ok <- check_entries(entries),
         model = current_model(header, entries),
         messages = for(%{"type" => "message"} = entry <- entries, do: decode_message(entry)),
         # The repair write comes last, after every check passed, so a
         # file this function rejects is never mutated.
         :ok <- repair(path, kept, rest) do
      {:ok,
       %Resumed{
         file: %__MODULE__{path: path, leaf: List.last(entries)["id"]},
         session_id: Path.basename(path, ".jsonl"),
         model: model,
         messages: messages
       }}
    end
  rescue
    # The file is on-disk data anyone can edit. An entry with a shape this
    # module never writes is rejected, not raised at the caller.
    error -> {:error, {:invalid_file, Exception.message(error)}}
  end

  @doc "Appends a model change entry recording a model ref switch."
  @spec append_model_change(t(), String.t()) :: t()
  def append_model_change(%__MODULE__{} = file, model) when is_binary(model) do
    append(file, %{"type" => "model_change", "model" => model})
  end

  @doc "Appends one completed message to the file."
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = file, %Message{} = message) do
    append(file, encode_message(message))
  end

  # Internals

  defp encode_message(%Message{role: role} = message) do
    encoded =
      %{
        "type" => "message",
        "role" => Atom.to_string(role),
        "content" => Enum.map(message.content, &encode_block/1),
        "model" => message.model,
        "stop_reason" => message.stop_reason && encode_stop_reason(message.stop_reason),
        "tool_call_id" => message.tool_call_id,
        "tool_name" => message.tool_name,
        "usage" => map_size(message.usage) > 0 && message.usage
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false] end)

    if role == :tool_result, do: Map.put(encoded, "is_error", message.is_error), else: encoded
  end

  defp encode_block(%Message.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: nil}),
    do: %{"type" => "thinking", "thinking" => thinking}

  defp encode_block(%Message.Thinking{thinking: thinking, signature: signature}),
    do: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}

  defp encode_block(%Message.ToolCall{id: id, name: name, arguments: arguments}) do
    %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
  end

  defp encode_block(%Message.Image{mime_type: mime_type, data: data}) do
    %{"type" => "image", "mime_type" => mime_type, "data" => data}
  end

  # A field value this format does not know misses its decode clause; the
  # rescue in resume/2 turns that into a rejected file.
  defp decode_message(entry) do
    %Message{
      role: decode_role(entry["role"]),
      content: Enum.map(entry["content"], &decode_block/1),
      model: optional_string(entry["model"]),
      stop_reason: entry["stop_reason"] && decode_stop_reason(entry["stop_reason"]),
      tool_call_id: optional_string(entry["tool_call_id"]),
      tool_name: optional_string(entry["tool_name"]),
      is_error: decode_is_error(entry["is_error"]),
      usage: decode_usage(entry["usage"])
    }
  end

  defp decode_role("user"), do: :user
  defp decode_role("assistant"), do: :assistant
  defp decode_role("tool_result"), do: :tool_result

  # The format owns this closed set, enforced on both sides. The decode
  # clauses intern the atoms in this module, so a fresh VM that has loaded
  # no provider still decodes a saved file; a stop reason outside the set
  # has no encode clause, so the writer fails loudly instead of appending
  # an entry that a later resume would reject. A new stop reason is a
  # format change.
  defp decode_stop_reason("end_turn"), do: :end_turn
  defp decode_stop_reason("tool_use"), do: :tool_use
  defp decode_stop_reason("max_tokens"), do: :max_tokens

  defp encode_stop_reason(:end_turn), do: "end_turn"
  defp encode_stop_reason(:tool_use), do: "tool_use"
  defp encode_stop_reason(:max_tokens), do: "max_tokens"

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: value

  defp decode_is_error(nil), do: false
  defp decode_is_error(value) when is_boolean(value), do: value

  defp decode_usage(nil), do: %{}
  defp decode_usage(value) when is_map(value), do: value

  defp decode_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Message.Text{text: text}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking, "signature" => signature})
       when is_binary(thinking) and is_binary(signature),
       do: %Message.Thinking{thinking: thinking, signature: signature}

  defp decode_block(%{"type" => "thinking", "thinking" => thinking} = block)
       when is_binary(thinking) and not is_map_key(block, "signature"),
       do: %Message.Thinking{thinking: thinking}

  defp decode_block(%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args})
       when is_binary(id) and is_binary(name) and is_map(args) do
    %Message.ToolCall{id: id, name: name, arguments: args}
  end

  defp decode_block(%{"type" => "image", "mime_type" => mime_type, "data" => data})
       when is_binary(mime_type) and is_binary(data) do
    %Message.Image{mime_type: mime_type, data: data}
  end

  defp check_version(%{"version" => @version}), do: :ok
  defp check_version(header), do: {:error, {:unknown_version, header["version"]}}

  # The writer only produces a header on line one, then messages and model
  # changes, every one with an id, every model a string. Anything else is
  # on-disk corruption, never silently dropped, and never laundered by a
  # later entry that overrides it.
  defp check_entries([%{"type" => "session", "id" => id, "model" => model} | rest])
       when is_binary(id) and is_binary(model) do
    case Enum.find(rest, &(not valid_entry?(&1))) do
      nil -> :ok
      bad -> {:error, {:invalid_file, "entry the writer never produces: #{inspect(bad["type"])}"}}
    end
  end

  defp check_entries(_entries), do: {:error, {:invalid_file, "the first entry is not a header"}}

  defp valid_entry?(%{"type" => "message", "id" => id}), do: is_binary(id)

  defp valid_entry?(%{"type" => "model_change", "id" => id, "model" => model}),
    do: is_binary(id) and is_binary(model)

  defp valid_entry?(_entry), do: false

  # The last model change wins, else the header's model. Both are strings:
  # check_entries validated every entry before this runs.
  defp current_model(header, entries) do
    Enum.reduce(entries, header["model"], fn
      %{"type" => "model_change"} = entry, _acc -> entry["model"]
      _entry, acc -> acc
    end)
  end

  # The most recently started session whose header matches the working
  # directory. Two directories can share a slug, so the header decides.
  defp most_recent(project_dir, cwd) do
    candidates =
      for path <- Path.wildcard(Path.join(project_dir, "*.jsonl")),
          {:ok, header} <- [read_header(path)],
          header["cwd"] == cwd do
        {header["ts"], path, header}
      end

    case Enum.max_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> {:error, :not_found}
      {_ts, path, header} -> {:ok, path, header}
    end
  end

  # The fun form of File.open closes the handle on every path.
  defp read_header(path) do
    with {:ok, line} when is_binary(line) <-
           File.open(path, [:read, :binary], &IO.binread(&1, :line)),
         {:ok, %{"type" => "session"} = header} <- JSON.decode(line) do
      {:ok, header}
    else
      _ -> :error
    end
  end

  # Splits the file into the leading run of lines that parse as entries
  # and the remainder, for `repair/3` to judge.
  defp parse(raw) do
    lines = String.split(raw, "\n")

    entries =
      lines
      |> Stream.map(&JSON.decode/1)
      |> Enum.take_while(&match?({:ok, %{"type" => _}}, &1))
      |> Enum.map(&elem(&1, 1))

    {kept, rest} = Enum.split(lines, length(entries))
    {entries, kept, rest}
  end

  # A clean file is the entries plus one "" chunk from the final newline. A
  # torn append is a prefix of `entry\n`, so it can only be one trailing
  # chunk with no newline: an entry that survived whole gets its newline
  # back, a partial one is truncated away in place. An append and an
  # in-place truncate cannot lose the kept entries the way a full rewrite
  # could if it crashed mid-write. A bad line mid-file never comes from a
  # torn append, and truncating there would delete good entries after it,
  # so it is a malformed file. A repair that cannot write is an environment
  # failure, not a malformed file.
  defp repair(_path, _kept, [""]), do: :ok

  defp repair(path, _kept, []), do: repaired(File.write(path, "\n", [:append]))

  defp repair(path, kept, [_torn]) do
    # Every kept line plus its newline.
    repaired(truncate(path, IO.iodata_length(kept) + length(kept)))
  end

  defp repair(_path, kept, _rest),
    do: {:error, {:invalid_file, "unparsable line #{length(kept) + 1}"}}

  defp repaired(:ok), do: :ok
  defp repaired({:error, reason}), do: {:error, {:repair_failed, reason}}

  defp truncate(path, keep_bytes) do
    opened =
      File.open(path, [:read, :write, :binary], fn io ->
        with {:ok, _position} <- :file.position(io, keep_bytes), do: :file.truncate(io)
      end)

    with {:ok, result} <- opened, do: result
  end

  defp append(%__MODULE__{path: path, leaf: leaf} = file, entry) do
    id = Helyx.Id.new()

    entry =
      Map.merge(entry, %{
        "id" => id,
        "parent_id" => leaf,
        "ts" => DateTime.to_iso8601(DateTime.utc_now())
      })

    File.write!(path, [JSON.encode!(entry), "\n"], [:append])
    %{file | leaf: id}
  end

  # The slug keeps the tail of the path, the distinctive end, and stays
  # under the filesystem name limit: 100 characters are 100 bytes because
  # the regex collapses every non-ASCII byte to "-". Collisions are fine:
  # the header `cwd` decides which sessions belong to a directory.
  defp project_dir(dir, cwd) do
    Path.join(dir, cwd |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.slice(-100, 100))
  end
end
