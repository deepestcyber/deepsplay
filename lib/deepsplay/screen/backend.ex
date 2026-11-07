defmodule Deepsplay.Screen.Backend do
  @moduledoc """
  The backend of a manifest (ADR 26): a Python process installed with `uv`
  from `dir` (relative to the root, with `pyproject.toml` and `uv.lock`) and
  started with `command`, where `{port}` stands for its port. `health` is an
  optional path that answers `2xx` once it is ready; `secrets` names the
  secrets it wants.

  Read only for configurations that allow backends (`backend = true` in the
  host configuration); otherwise the `[backend]` table is ignored with a
  warning.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.TomlSchema

  @enforce_keys [:dir, :command]
  defstruct [:dir, :command, health: nil, secrets: []]

  @type t :: %__MODULE__{
          dir: String.t(),
          command: [String.t(), ...],
          health: String.t() | nil,
          secrets: [String.t()]
        }

  @fields [
    {"dir", :dir, :relative_path, []},
    {"command", :command, &__MODULE__.cast_command/1, []},
    {"health", :health, &__MODULE__.cast_health/1, default: nil},
    {"secrets", :secrets, :string_list, default: []}
  ]

  @doc """
  Reads the `[backend]` table of a manifest below `root` for `config`.
  Returns the backend (or `nil`), errors and warnings.
  """
  @spec parse(term(), Path.t(), Config.t()) :: {t() | nil, [String.t()], [String.t()]}
  def parse(nil, _root, _config), do: {nil, [], []}

  def parse(_table, _root, %Config{backend: false}),
    do: {nil, [], ["[backend] is ignored: backends are not allowed for this configuration"]}

  def parse(table, root, config) when is_map(table) do
    {fields, errors} = TomlSchema.fields(table, "backend", @fields)

    errors =
      errors ++
        dir_errors(fields.dir, root) ++
        for secret <- fields.secrets || [], secret not in config.backend_secrets do
          ~s(backend: secret "#{secret}" is not allowed for this configuration)
        end

    case errors do
      [] -> {struct!(__MODULE__, fields), [], []}
      errors -> {nil, errors, []}
    end
  end

  def parse(_table, _root, _config), do: {nil, ["backend must be a table"], []}

  defp dir_errors(nil, _root), do: []

  defp dir_errors(dir, root) do
    full = Path.join(root, dir)

    cond do
      hd(Path.split(dir)) == "pages" ->
        [~s(backend.dir "#{dir}" must not be inside pages/)]

      not File.dir?(full) ->
        [~s(backend.dir "#{dir}" is not a directory)]

      true ->
        for file <- ["pyproject.toml", "uv.lock"], not File.regular?(Path.join(full, file)) do
          ~s(backend.dir "#{dir}" has no #{file})
        end
    end
  end

  @doc false
  def cast_command([_ | _] = command) do
    if Enum.all?(command, &(is_binary(&1) and &1 != "")),
      do: {:ok, command},
      else: {:error, "must be a list of non-empty strings"}
  end

  def cast_command(_value),
    do: {:error, ~s(must be a list of strings, e.g. ["uvicorn", "app:app"])}

  @doc false
  def cast_health("/" <> _rest = path), do: {:ok, path}
  def cast_health(_value), do: {:error, ~s(must be a path starting with "/")}
end
