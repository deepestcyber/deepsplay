defmodule Deepsplay.Revisions do
  @moduledoc """
  Revisions per configuration: fetching and validating them, the current one
  with its manifest, and announcing new ones over PubSub.

  Each configuration keeps its own last good revision, because configurations
  on the same repository and ref can use different manifests and upstreams.
  """

  require Logger

  alias Deepsplay.GitCredentials
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.LocalWatcher
  alias Deepsplay.PageParams
  alias Deepsplay.Pages
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen
  alias Deepsplay.Status

  @pubsub Deepsplay.PubSub

  @typedoc """
  A configuration's current content. `sha` is the commit, or the version token
  of a local directory (ADR 12); `local` tells which.
  """
  @type current :: %{
          sha: String.t(),
          pages_dir: Path.t(),
          screen: Screen.t(),
          local: boolean(),
          added: [PageParams.added()],
          override_added: [{PageParams.added(), [String.t()]}],
          empty_added: PageParams.added(),
          param_warnings: [String.t()]
        }

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
    result =
      case GitCredentials.env(config) do
        {:ok, env} ->
          publish_opts =
            [
              validate: Screen.validator(config),
              remember_as: remember_key(config),
              git: [env: env]
            ] ++ opts

          RevisionStore.publish(config.repo, config.ref, publish_opts)

        {:error, message} ->
          {:error, {:config, message}}
      end

    case result do
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

    # A revision's manifest does not change; the proxy asks for it with every
    # request to a manifest upstream.
    options = Screen.options(config)

    case Pages.memo({:screen, root, sha, options}, fn -> Screen.load(root, options) end) do
      {:ok, screen} ->
        current = %{sha: sha, pages_dir: Screen.pages_dir(root), screen: screen, local: local}
        # Parameters added to each page of the rotation (ADR 16).
        context = param_context(config, current)
        {added, warnings} = PageParams.for_rotation(context)

        # Overrides and the page shown when nothing is active (ADR 25).
        override_added =
          for override <- screen.overrides,
              do: PageParams.for_override(context, override.path, override.query)

        empty_added =
          case screen.when_empty do
            {path, query} -> context |> PageParams.for_page(path, query, nil) |> elem(0)
            :black -> []
          end

        {:ok,
         Map.merge(current, %{
           added: added,
           override_added: override_added,
           empty_added: empty_added,
           param_warnings: warnings
         })}

      {:error, errors} ->
        {:error, errors}
    end
  end

  @doc """
  Upstreams declared in the manifest of the configuration's current revision
  (ADR 19).
  """
  @spec manifest_upstreams(Config.t()) :: %{String.t() => Deepsplay.HostConfig.Upstream.t()}
  def manifest_upstreams(%Config{} = config) do
    case current(config) do
      {:ok, current} -> current.screen.upstreams
      _none_or_error -> %{}
    end
  end

  @doc """
  The context for working out added page parameters (`Deepsplay.PageParams`).
  """
  @spec param_context(Config.t(), map()) :: PageParams.context()
  def param_context(config, current) do
    %{config: config, screen: current.screen, pages_dir: current.pages_dir, key: current.sha}
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
