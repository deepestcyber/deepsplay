defmodule Deepsplay.Screen.Page do
  @moduledoc """
  One page of a manifest. `path` is the file in `pages/`; `query` is an
  optional query string passed on to the page, e.g. `"duration=5s"`.
  """

  @enforce_keys [:path, :duration]
  defstruct [:path, :duration, query: nil, weight: 1.0, uses: []]

  @type t :: %__MODULE__{
          path: String.t(),
          query: String.t() | nil,
          duration: pos_integer(),
          weight: float(),
          uses: [String.t()]
        }
end
