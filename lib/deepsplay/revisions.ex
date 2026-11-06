defmodule Deepsplay.Revisions do
  @moduledoc """
  Revisions per configuration: fetching and validating them, the current one
  with its manifest, and announcing new ones over PubSub.

  Each configuration keeps its own last good revision, because configurations
  on the same repository and ref can use different manifests and upstreams.
  """

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.LocalWatcher
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen
  alias Deepsplay.Status

  @pubsub Deepsplay.PubSub

  @typedoc """
  A configuration's current content. `sha` is the commit, or the version token
  of a local directory (ADR 12); `local` tells which.
  """
  @type current :: %{sha: String.t(), pages_dir: Path.t(), screen: Screen.t(), local: boolean()}

  @doc """
  Subscribes the caller to the configuration `name`. Messages are
  `{:revision_published, name, sha}` and `{:status_changed, name}` (see
  `Deepsplay.Status`).
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
        announce(config.name, sha)
        Status.update(config.name, %{error: nil, error_at: nil})
        {:ok, sha}

      {:error, error} ->
        message = RevisionStore.format_error(error)
        Logger.warning(~s(config "#{config.name}": #{message}))
        Status.update(config.name, %{error: message, error_at: DateTime.utc_now()})
        {:error, error}
    end
  end

  @doc """
  Returns the configuration's current revision with its manifest, from the
  cache only (no network).
  """
  @spec current(Config.t(), keyword()) :: {:ok, current()} | :none | {:error, [String.t()]}
  def current(config, opts \\ [])

  # A local directory is read live, with the watcher's version token.
  def current(%Config{path: path} = config, _opts) when is_binary(path) do
    case LocalWatcher.token(config.name) do
      {:ok, token} -> load(config, token, path, true)
      :error -> :none
    end
  end

  def current(%Config{} = config, opts) do
    with {:ok, sha} <- RevisionStore.last_good(config.repo, remember_key(config), opts),
         {:ok, rev_dir} <- RevisionStore.revision_dir(config.repo, sha, opts) do
      load(config, sha, rev_dir, false)
    else
      :error -> :none
      {:error, error} -> {:error, [RevisionStore.format_error(error)]}
    end
  end

  defp load(config, sha, dir, local) do
    root = Screen.root(dir, config)

    case Screen.load(root, manifest: config.manifest, upstreams: config.upstreams) do
      {:ok, screen} ->
        {:ok, %{sha: sha, pages_dir: Screen.pages_dir(root), screen: screen, local: local}}

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc """
  Announces a new revision (or version token) of the configuration `name` to
  its subscribers.
  """
  @spec announce(String.t(), String.t()) :: :ok | {:error, term()}
  def announce(name, sha) do
    Phoenix.PubSub.broadcast(@pubsub, topic(name), {:revision_published, name, sha})
  end

  @doc false
  # Revisions and status changes of a configuration share one topic.
  def topic(name), do: "revisions:" <> name

  # Configuration names are restricted to [a-z0-9_-], so the key is unique and
  # cannot collide with a ref name (refs cannot contain ":").
  defp remember_key(%Config{name: name}), do: "config:" <> name
end
