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
    upstreams: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          repo: String.t() | nil,
          ref: String.t() | nil,
          path: String.t() | nil,
          subdir: String.t(),
          manifest: String.t(),
          credential: String.t() | nil,
          upstreams: [String.t()]
        }

  @doc """
  Returns true if the configuration serves a local directory (ADR 12).
  """
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{path: path}), do: path != nil
end
