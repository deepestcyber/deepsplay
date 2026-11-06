defmodule Deepsplay.HostConfig do
  @moduledoc """
  The host configuration: server settings and the configurations screens can
  select, read from a TOML file outside any repository (see ADR 5).

  Parsing collects every problem it finds instead of stopping at the first one,
  so an operator can fix the whole file in one go.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RepoUrl
  alias Deepsplay.Screen
  alias Deepsplay.TomlSchema

  @enforce_keys [:cache_dir, :default_config, :configs]
  defstruct [
    :cache_dir,
    :default_config,
    :configs,
    poll_interval: 30_000,
    keep_revisions: 3
  ]

  @type t :: %__MODULE__{
          cache_dir: String.t(),
          default_config: String.t(),
          poll_interval: pos_integer(),
          keep_revisions: non_neg_integer(),
          configs: %{String.t() => Config.t()}
        }

  @top_keys ~w(server config upstream)

  @server_fields [
    {"cache_dir", :cache_dir, :string, []},
    {"default_config", :default_config, :string, []},
    {"poll_interval", :poll_interval, :duration, default: 30_000},
    {"keep_revisions", :keep_revisions, :non_neg_integer, default: 3}
  ]

  @doc """
  Reads and parses the host configuration file at `path`.

  See `parse/2` for options.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def load(path, opts \\ []) do
    case File.read(path) do
      {:ok, toml} ->
        parse(toml, opts)

      {:error, reason} ->
        {:error, ["cannot read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  @doc """
  Parses a host configuration from a TOML string.

  ## Options

    * `:transports` - git transports a repository URL may use. Defaults to the
      `:git_transports` application setting (see ADR 6).
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(toml, opts \\ []) when is_binary(toml) do
    transports = Keyword.get_lazy(opts, :transports, &allowed_transports/0)

    case TomlElixir.decode(toml) do
      {:ok, data} -> build(data, transports)
      {:error, error} -> {:error, ["invalid TOML: #{Exception.message(error)}"]}
    end
  end

  @doc """
  Returns the git transports allowed in this environment.
  """
  @spec allowed_transports() :: [String.t()]
  def allowed_transports do
    Application.get_env(:deepsplay, :git_transports, ["https", "ssh"])
  end

  defp build(data, transports) do
    unknown = TomlSchema.unknown_keys(data, @top_keys, "top level")
    {server, server_errors} = server(Map.get(data, "server"))
    {upstreams, upstream_errors} = upstream_names(Map.get(data, "upstream", %{}))
    {configs, config_errors} = configs(Map.get(data, "config", []), transports, upstreams)

    errors =
      unknown ++
        server_errors ++
        upstream_errors ++ config_errors ++ default_errors(server, declared_names(data))

    case errors do
      [] ->
        {:ok,
         %__MODULE__{
           cache_dir: Path.expand(server.cache_dir),
           default_config: server.default_config,
           poll_interval: server.poll_interval,
           keep_revisions: server.keep_revisions,
           configs: Map.new(configs, &{&1.name, &1})
         }}

      errors ->
        {:error, errors}
    end
  end

  defp server(nil), do: {nil, ["[server] table is missing"]}

  defp server(server) when is_map(server),
    do: TomlSchema.fields(server, "server", @server_fields)

  defp server(_server), do: {nil, ["server must be a table"]}

  # Upstream tables are only checked for their names here; their contents are
  # read by the upstream proxy (ADR 8).
  defp upstream_names(upstreams) when is_map(upstreams) do
    errors =
      for {name, value} <- upstreams, not is_map(value) do
        "upstream.#{name} must be a table"
      end

    {Map.keys(upstreams), errors}
  end

  defp upstream_names(_upstreams), do: {[], ["upstream must be a table"]}

  defp configs(configs, transports, upstreams) when is_list(configs) do
    {parsed, errors} =
      configs
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {config, index}, acc ->
        {config, errors} = config(config, index, transports, upstreams)
        {config, acc ++ errors}
      end)

    parsed = Enum.reject(parsed, &is_nil/1)
    {parsed, errors ++ duplicate_errors(parsed)}
  end

  defp configs(_configs, _transports, _upstreams) do
    {[], ["config must be an array of tables ([[config]])"]}
  end

  defp config(config, index, transports, upstreams) when is_map(config) do
    ctx = config_context(config, index)
    {fields, errors} = TomlSchema.fields(config, ctx, config_fields(transports))

    errors =
      errors ++
        for upstream <- fields[:upstreams] || [], upstream not in upstreams do
          ~s(#{ctx}: upstream "#{upstream}" is not defined)
        end

    case errors do
      [] -> {struct!(Config, fields), []}
      errors -> {nil, errors}
    end
  end

  defp config(_config, index, _transports, _upstreams) do
    {nil, ["config ##{index} must be a table"]}
  end

  defp config_context(%{"name" => name}, _index) when is_binary(name), do: ~s(config "#{name}")
  defp config_context(_config, index), do: "config ##{index}"

  defp duplicate_errors(configs) do
    configs
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> ~s(config name "#{name}" is defined more than once) end)
    |> Enum.sort()
  end

  # Names of all declared configurations, including invalid ones, so a broken
  # configuration is not also reported as a missing default.
  defp declared_names(%{"config" => configs}) when is_list(configs) do
    for %{"name" => name} <- configs, is_binary(name), do: name
  end

  defp declared_names(_data), do: []

  defp default_errors(nil, _names), do: []
  defp default_errors(%{default_config: nil}, _names), do: []

  defp default_errors(%{default_config: default}, names) do
    if default in names do
      []
    else
      [~s(server.default_config "#{default}" does not match any config)]
    end
  end

  defp config_fields(transports) do
    [
      {"name", :name, &cast_name/1, []},
      {"repo", :repo, &cast_repo(&1, transports), []},
      {"ref", :ref, :string, []},
      {"subdir", :subdir, &cast_subdir/1, default: ""},
      {"manifest", :manifest, &cast_manifest/1, default: Screen.default_manifest()},
      {"credential", :credential, :string, default: nil},
      {"upstreams", :upstreams, :string_list, default: []}
    ]
  end

  defp cast_name(value) when is_binary(value) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]{0,63}$/, value) do
      {:ok, value}
    else
      {:error,
       "must be 1 to 64 characters of lowercase letters, digits, \"-\" and \"_\", " <>
         "starting with a letter or digit"}
    end
  end

  defp cast_name(_value), do: {:error, "must be a string"}

  defp cast_repo(value, transports) when is_binary(value) do
    case RepoUrl.transport(value) do
      {:ok, transport} ->
        if transport in transports do
          {:ok, value}
        else
          {:error, "uses transport \"#{transport}\", allowed: #{Enum.join(transports, ", ")}"}
        end

      :error ->
        {:error, "must be an https, ssh or scp-like (user@host:path) URL"}
    end
  end

  defp cast_repo(_value, _transports), do: {:error, "must be a string"}

  defp cast_subdir(""), do: {:ok, ""}
  defp cast_subdir(value), do: TomlSchema.cast(:relative_path, value)

  # Manifests are never delivered, so they must not live in pages/ (ADR 10).
  defp cast_manifest(value) do
    with {:ok, path} <- TomlSchema.cast(:relative_path, value) do
      if hd(Path.split(path)) == Screen.pages_dir_name(),
        do: {:error, ~s(must not be inside "#{Screen.pages_dir_name()}/")},
        else: {:ok, path}
    end
  end
end
