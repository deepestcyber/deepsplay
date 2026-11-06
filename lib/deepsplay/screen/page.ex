defmodule Deepsplay.Screen.Page do
  @moduledoc """
  One page of a `screen.toml`.
  """

  @enforce_keys [:path, :duration]
  defstruct [:path, :duration, weight: 1.0, uses: []]

  @type t :: %__MODULE__{
          path: String.t(),
          duration: pos_integer(),
          weight: float(),
          uses: [String.t()]
        }
end
