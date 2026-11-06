defmodule DeepsplayWeb.Presence do
  @moduledoc """
  Tracks connected screens for the status page. Each screen shell is tracked
  under the `"screens"` topic with its configuration, revision and current
  page.
  """

  use Phoenix.Presence, otp_app: :deepsplay, pubsub_server: Deepsplay.PubSub

  @topic "screens"

  @doc "The topic screens are tracked under."
  def topic, do: @topic
end
