defmodule Deepsplay.HostConfig.Config do
  @moduledoc """
  One configuration from the host configuration: which repository and ref a
  screen shows, and which upstreams its pages may use.
  """

  @enforce_keys [:name, :repo, :ref]
  defstruct [:name, :repo, :ref, :credential, subdir: "", manifest: "screen.toml", upstreams: []]

  @type t :: %__MODULE__{
          name: String.t(),
          repo: String.t(),
          ref: String.t(),
          subdir: String.t(),
          manifest: String.t(),
          credential: String.t() | nil,
          upstreams: [String.t()]
        }
end
