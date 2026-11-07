defmodule Deepsplay.HostConfig do
  @moduledoc """
  The host configuration: server settings and the configurations screens can
  select, read from a TOML file outside any repository (see ADR 5).

  Parsing collects every problem it finds instead of stopping at the first one,
  so an operator can fix the whole file in one go.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.RepoUrl
  alias Deepsplay.Secrets
  alias Deepsplay.Screen
  alias Deepsplay.TomlSchema

  @enforce_keys [:cache_dir, :default_config, :configs]
  defstruct [
    :cache_dir,
    :default_config,
    :configs,
    upstreams: %{},
    poll_interval: 30_000,
    keep_revisions: 3
  ]

  @type t :: %__MODULE__{
          cache_dir: String.t(),
          default_config: String.t(),
          poll_interval: pos_integer(),
          keep_revisions: non_neg_integer(),
          configs: %{String.t() => Config.t()},
          upstreams: %{String.t() => Upstream.t()}
        }

  @top_keys ~w(server config upstream)

  @upstream_methods ~w(GET HEAD POST PUT PATCH DELETE)

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
    * `:allow_local_paths` - whether configurations may use a local `path`.
      Defaults to the `:allow_local_paths` application setting (ADR 12).
    * `:secrets` - names of the defined secrets, which upstreams and
      credentials may refer to. Defaults to `Deepsplay.Secrets.names/0`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(toml, opts \\ []) when is_binary(toml) do
    transports = Keyword.get_lazy(opts, :transports, &allowed_transports/0)

    local_paths =
      Keyword.get_lazy(opts, :allow_local_paths, fn ->
        Application.get_env(:deepsplay, :allow_local_paths, false)
      end)

    case TomlElixir.decode(toml) do
      {:ok, data} ->
        secrets = Keyword.get_lazy(opts, :secrets, &Secrets.names/0)
        build(data, %{transports: transports, local_paths: local_paths, secrets: secrets})

      {:error, error} ->
        {:error, ["invalid TOML: #{Exception.message(error)}"]}
    end
  end

  @doc """
  Returns the git transports allowed in this environment.
  """
  @spec allowed_transports() :: [String.t()]
  def allowed_transports do
    Application.get_env(:deepsplay, :git_transports, ["https", "ssh"])
  end

  defp build(data, allowed) do
    unknown = TomlSchema.unknown_keys(data, @top_keys, "top level")
    {server, server_errors} = server(Map.get(data, "server"))
    {upstreams, upstream_errors} = upstreams(Map.get(data, "upstream", %{}), allowed.secrets)
    {configs, config_errors} = configs(Map.get(data, "config", []), allowed, Map.keys(upstreams))

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
           configs: Map.new(configs, &{&1.name, &1}),
           upstreams: upstreams
         }}

      errors ->
        {:error, errors}
    end
  end

  defp server(nil), do: {nil, ["[server] table is missing"]}

  defp server(server) when is_map(server),
    do: TomlSchema.fields(server, "server", @server_fields)

  defp server(_server), do: {nil, ["server must be a table"]}

  # Upstreams of the proxy (ADR 8). Invalid ones still count as defined, so a
  # configuration using one is not also reported.
  defp upstreams(upstreams, secrets) when is_map(upstreams) do
    {parsed, errors} =
      upstreams
      |> Enum.sort()
      |> Enum.map_reduce([], fn {name, table}, acc ->
        {upstream, errors} = upstream(name, table, secrets)
        {{name, upstream}, acc ++ errors}
      end)

    {Map.new(parsed), errors}
  end

  defp upstreams(_upstreams, _secrets), do: {%{}, ["upstream must be a table"]}

  defp upstream(name, table, secrets) when is_map(table) do
    ctx = "upstream.#{name}"

    {fields, errors} =
      TomlSchema.fields(table, ctx, [
        {"base_url", :base_url, &cast_base_url/1, []},
        {"methods", :methods, &cast_methods/1, default: ["GET"]},
        {"header", :header, &cast_header_name/1, default: nil},
        {"value", :value, :string, default: nil},
        {"query", :query, :string, default: nil},
        {"query_value", :query_value, :string, default: nil},
        {"cache_ttl", :cache_ttl, :duration, default: nil},
        {"timeout", :timeout, :duration, default: 15_000}
      ])

    errors =
      errors ++
        pair_errors(table, ctx, "header", "value") ++
        pair_errors(table, ctx, "query", "query_value") ++
        for template <- [fields.value, fields.query_value],
            is_binary(template),
            secret <- Secrets.references(template),
            secret not in secrets do
          ~s(#{ctx}: secret "#{secret}" is not defined)
        end

    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, name) do
      {struct!(Upstream, Map.put(fields, :name, name)), errors}
    else
      {nil, errors ++ ["#{ctx}: name must be lowercase letters, digits, \"-\" and \"_\""]}
    end
  end

  defp upstream(name, _table, _secrets), do: {nil, ["upstream.#{name} must be a table"]}

  defp pair_errors(table, ctx, a, b) do
    case {Map.has_key?(table, a), Map.has_key?(table, b)} do
      {true, false} -> [~s(#{ctx}: "#{a}" needs "#{b}")]
      {false, true} -> [~s(#{ctx}: "#{b}" needs "#{a}")]
      _both_or_none -> []
    end
  end

  defp cast_base_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, query: nil, fragment: nil, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(value, "/")}

      _other ->
        {:error, "must be an http or https URL without credentials, query or fragment"}
    end
  end

  defp cast_base_url(_value), do: {:error, "must be a string"}

  defp cast_methods(value) when is_list(value) and value != [] do
    if Enum.all?(value, &(&1 in @upstream_methods)),
      do: {:ok, value},
      else: {:error, "must be a list of: #{Enum.join(@upstream_methods, ", ")}"}
  end

  defp cast_methods(_value),
    do: {:error, "must be a list of: #{Enum.join(@upstream_methods, ", ")}"}

  defp cast_header_name(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9-]+$/, value),
      do: {:ok, value},
      else: {:error, "must be a header name"}
  end

  defp cast_header_name(_value), do: {:error, "must be a string"}

  defp configs(configs, allowed, upstreams) when is_list(configs) do
    {parsed, errors} =
      configs
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {config, index}, acc ->
        {config, errors} = config(config, index, allowed, upstreams)
        {config, acc ++ errors}
      end)

    parsed = Enum.reject(parsed, &is_nil/1)
    {parsed, errors ++ duplicate_errors(parsed)}
  end

  defp configs(_configs, _allowed, _upstreams) do
    {[], ["config must be an array of tables ([[config]])"]}
  end

  defp config(config, index, allowed, upstreams) when is_map(config) do
    ctx = config_context(config, index)
    {fields, errors} = TomlSchema.fields(config, ctx, config_fields(allowed))

    errors =
      errors ++
        source_errors(config, ctx) ++
        credential_errors(fields[:credential], ctx, allowed.secrets) ++
        for upstream <- fields[:upstreams] || [], upstream not in upstreams do
          ~s(#{ctx}: upstream "#{upstream}" is not defined)
        end

    case errors do
      [] -> {struct!(Config, fields), []}
      errors -> {nil, errors}
    end
  end

  defp config(_config, index, _allowed, _upstreams) do
    {nil, ["config ##{index} must be a table"]}
  end

  defp credential_errors(nil, _ctx, _secrets), do: []

  defp credential_errors(credential, ctx, secrets) do
    if credential in secrets,
      do: [],
      else: [~s(#{ctx}: credential secret "#{credential}" is not defined)]
  end

  # Content comes from a repository (repo + ref) or a local directory (path).
  defp source_errors(config, ctx) do
    case {Map.has_key?(config, "repo"), Map.has_key?(config, "ref"), Map.has_key?(config, "path")} do
      {_repo, _ref, true} ->
        for key <- ["repo", "ref", "credential"], Map.has_key?(config, key) do
          ~s(#{ctx}: "#{key}" cannot be combined with "path")
        end

      {true, true, false} ->
        []

      {false, false, false} ->
        [~s(#{ctx}: needs "repo" and "ref", or "path")]

      {true, false, false} ->
        ["#{ctx}.ref is missing"]

      {false, true, false} ->
        ["#{ctx}.repo is missing"]
    end
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

  defp config_fields(allowed) do
    [
      {"name", :name, &cast_name/1, []},
      {"repo", :repo, &cast_repo(&1, allowed.transports), default: nil},
      {"ref", :ref, :string, default: nil},
      {"path", :path, &cast_path(&1, allowed.local_paths), default: nil},
      {"subdir", :subdir, &cast_subdir/1, default: ""},
      {"manifest", :manifest, &cast_manifest/1, default: Screen.default_manifest()},
      {"credential", :credential, :string, default: nil},
      {"upstreams", :upstreams, :string_list, default: []},
      {"params", :params, :params, default: %{}}
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

  # Local directories are for development only (ADR 12).
  defp cast_path(value, allowed) when is_binary(value) do
    cond do
      not allowed -> {:error, "is only allowed in development"}
      Path.type(value) != :absolute -> {:error, "must be an absolute path"}
      true -> {:ok, Path.expand(value)}
    end
  end

  defp cast_path(_value, _allowed), do: {:error, "must be a string"}

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
