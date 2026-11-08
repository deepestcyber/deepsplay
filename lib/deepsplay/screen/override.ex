defmodule Deepsplay.Screen.Override do
  @moduledoc """
  An override of a manifest (ADR 25): a page that interrupts the rotation
  while one of its time windows is active. The active override with the
  highest `priority` wins, the first of equal ones. `enabled: false`
  switches it off (ADR 29).
  """

  alias Deepsplay.TimeWindow

  @enforce_keys [:path, :when]
  defstruct [:path, :when, query: nil, priority: 0, description: nil, uses: [], enabled: true]

  @type t :: %__MODULE__{
          path: String.t(),
          query: String.t() | nil,
          when: [TimeWindow.t()],
          priority: integer(),
          description: String.t() | nil,
          uses: [String.t()],
          enabled: boolean()
        }
end
