defmodule Deepsplay.ScreenFixture do
  @moduledoc """
  A content repository and a host configuration pointing at it, stored as the
  current host configuration for the duration of a test.

  Tests using it must not be async: the host configuration is global.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store

  @doc """
  Creates a repository in `tmp_dir` with `files` committed, and a host
  configuration with a `lobby` configuration (default) on it. Extra
  `[[config]]` TOML can be passed as `extra_config`.

  Returns `%{src:, url:, sha:, config:}`.
  """
  def setup_screen(tmp_dir, files, extra_config \\ "") do
    src = Path.join(tmp_dir, "src")
    url = GitFixture.init(src)
    sha = GitFixture.commit(src, files)

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{Path.join(tmp_dir, "cache")}"
      default_config = "lobby"

      [[config]]
      name = "lobby"
      repo = "#{url}"
      ref  = "main"

      #{extra_config}
      """)

    previous = Store.get()
    Store.put({:ok, host_config})
    Deepsplay.Status.clear()
    on_exit(fn -> Store.put(previous) end)

    %{src: src, url: url, sha: sha, config: host_config.configs["lobby"]}
  end
end
