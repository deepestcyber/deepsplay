defmodule Deepsplay.Revisions do
  @moduledoc """
  Revisions per configuration: fetching and validating them, the current one
  with its manifest, and announcing new ones over PubSub.

  Each configuration keeps its own last good revision, because configurations
  on the same repository and ref can use different manifests and upstreams.
  """

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen

  @pubsub Deepsplay.PubSub

  @type current :: %{sha: String.t(), pages_dir: Path.t(), screen: Screen.t()}

  @doc """
  Subscribes the caller to new revisions of the configuration `name`. Messages
  are `{:revision_published, name, sha}`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(@pubsub, topic(name))

  @doc """
  Fetches the configuration's ref, validates the revision against its manifest
  and, if valid, remembers and announces it.
  """
  @spec refresh(Config.t(), keyword()) :: {:ok, String.t()} | {:error, RevisionStore.error()}
  def refresh(%Config{} = config, opts \\ []) do
    publish_opts =
      [validate: Screen.validator(config), remember_as: remember_key(config)] ++ opts

    case RevisionStore.publish(config.repo, config.ref, publish_opts) do
      {:ok, sha} ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(config.name),
          {:revision_published, config.name, sha}
        )

        {:ok, sha}

      {:error, error} ->
        Logger.warning(~s(config "#{config.name}": #{RevisionStore.format_error(error)}))
        {:error, error}
    end
  end

  @doc """
  Returns the configuration's current revision with its manifest, from the
  cache only (no network).
  """
  @spec current(Config.t(), keyword()) :: {:ok, current()} | :none | {:error, [String.t()]}
  def current(%Config{} = config, opts \\ []) do
    with {:ok, sha} <- RevisionStore.last_good(config.repo, remember_key(config), opts),
         {:ok, rev_dir} <- RevisionStore.revision_dir(config.repo, sha, opts) do
      root = Screen.root(rev_dir, config)

      case Screen.load(root, manifest: config.manifest, upstreams: config.upstreams) do
        {:ok, screen} -> {:ok, %{sha: sha, pages_dir: Screen.pages_dir(root), screen: screen}}
        {:error, errors} -> {:error, errors}
      end
    else
      :error -> :none
      {:error, error} -> {:error, [RevisionStore.format_error(error)]}
    end
  end

  @doc """
  Refreshes every configuration once, in the background. Called at startup
  unless the `:fetch_on_start` application setting is false.
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    with true <- Application.get_env(:deepsplay, :fetch_on_start, true),
         {:ok, host_config} <- Store.get() do
      for {_name, config} <- host_config.configs do
        Task.Supervisor.start_child(Deepsplay.TaskSupervisor, fn -> refresh(config) end)
      end
    end

    :ok
  end

  defp topic(name), do: "revisions:" <> name

  # Configuration names are restricted to [a-z0-9_-], so the key is unique and
  # cannot collide with a ref name (refs cannot contain ":").
  defp remember_key(%Config{name: name}), do: "config:" <> name
end
