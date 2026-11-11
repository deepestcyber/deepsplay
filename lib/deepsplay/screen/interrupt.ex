defmodule Deepsplay.Screen.Interrupt do
  @moduledoc """
  An interrupt of a manifest (ADR 32): a page shown on all screens of a
  configuration when it is triggered over HTTP, for at most `duration`
  milliseconds. Its `priority` decides against overrides and other
  interrupts on the screen. `enabled: false` switches it off (ADR 29).
  """

  @enforce_keys [:name, :path, :duration]
  defstruct [
    :name,
    :path,
    :duration,
    query: nil,
    priority: 0,
    description: nil,
    uses: [],
    enabled: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          query: String.t() | nil,
          duration: pos_integer(),
          priority: integer(),
          description: String.t() | nil,
          uses: [String.t()],
          enabled: boolean()
        }
end
