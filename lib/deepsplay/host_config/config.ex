defmodule Deepsplay.HostConfig.Config do
  @moduledoc """
  One configuration from the host configuration: what a screen shows, and
  which upstreams its pages may use.

  Content comes either from a git repository (`repo` and `ref`) or, in
  development only, from a local directory (`path`, ADR 12).
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :repo,
    :ref,
    :path,
    :credential,
    subdir: "",
    manifest: "screen.toml",
    upstreams: [],
    params: %{},
    repo_upstreams: true,
    repo_upstream_hosts: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          repo: String.t() | nil,
          ref: String.t() | nil,
          path: String.t() | nil,
          subdir: String.t(),
          manifest: String.t(),
          credential: String.t() | nil,
          upstreams: [String.t()],
          params: %{String.t() => String.t()},
          repo_upstreams: boolean(),
          repo_upstream_hosts: [String.t()]
        }

  @doc """
  Returns true if manifests of this configuration may declare an upstream for
  `host` (ADR 19).
  """
  @spec repo_upstream_host?(t(), String.t()) :: boolean()
  def repo_upstream_host?(%__MODULE__{repo_upstreams: false}, _host), do: false
  def repo_upstream_host?(%__MODULE__{repo_upstream_hosts: []}, _host), do: true

  def repo_upstream_host?(%__MODULE__{repo_upstream_hosts: patterns}, host) do
    host = String.downcase(host)

    Enum.any?(patterns, fn
      "*." <> domain -> String.ends_with?(host, "." <> domain)
      name -> host == name
    end)
  end

  @doc """
  Returns true if the configuration serves a local directory (ADR 12).
  """
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{path: path}), do: path != nil
end
