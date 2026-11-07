defmodule Deepsplay.Screen.Page do
  @moduledoc """
  One page of a manifest. `path` is the file in `pages/`; `query` is an
  optional query string passed on to the page, e.g. `"duration=5s"`;
  `description` says why the entry is in the rotation; `when` limits it to
  time windows (ADR 25), `nil` for always.
  """

  @enforce_keys [:path, :duration]
  defstruct [:path, :duration, query: nil, weight: 1.0, uses: [], description: nil, when: nil]

  @type t :: %__MODULE__{
          path: String.t(),
          query: String.t() | nil,
          duration: pos_integer(),
          weight: float(),
          uses: [String.t()],
          description: String.t() | nil,
          when: [Deepsplay.TimeWindow.t()] | nil
        }
end
