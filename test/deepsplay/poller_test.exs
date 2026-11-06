defmodule Deepsplay.PollerTest do
  # Not async: uses the global host configuration and status table.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Deepsplay.ScreenFixture

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Poller
  alias Deepsplay.Pollers
  alias Deepsplay.Revisions
  alias Deepsplay.Status

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => ~s([[page]]\npath = "a.html"\nduration = "1s"\n),
    "pages/a.html" => "v1"
  }

  # An interval long enough that only explicit checks run during a test.
  defp start_poller(config, opts \\ []) do
    opts =
      Keyword.merge(
        [url: config.repo, ref: config.ref, configs: [config], interval: 3_600_000, keep: 1],
        opts
      )

    pid = start_supervised!({Poller, opts})
    # The first check runs right after start; wait for it.
    _ = :sys.get_state(pid)
    pid
  end

  setup %{tmp_dir: tmp_dir} do
    ctx = setup_screen(tmp_dir, @files)
    Revisions.subscribe("lobby")
    ctx
  end

  test "publishes the current revision on start", %{config: config, sha: sha} do
    start_poller(config)

    assert_receive {:revision_published, "lobby", ^sha}
    assert {:ok, %{sha: ^sha}} = Revisions.current(config)

    status = Status.get("lobby")
    assert %DateTime{} = status.checked_at
    assert %DateTime{} = status.next_check_at
    assert status.error == nil
  end

  test "publishes a new commit, and nothing when the branch has not moved", ctx do
    poller = start_poller(ctx.config)
    assert_receive {:revision_published, "lobby", _}

    Poller.check_now(poller)
    refute_received {:revision_published, "lobby", _}

    new = GitFixture.commit(ctx.src, %{"pages/a.html" => "v2"})
    Poller.check_now(poller)

    assert_received {:revision_published, "lobby", ^new}
    assert {:ok, %{sha: ^new}} = Revisions.current(ctx.config)
  end

  test "does not retry a rejected revision until the branch moves", ctx do
    poller = start_poller(ctx.config)
    assert_receive {:revision_published, "lobby", good}

    GitFixture.commit(ctx.src, %{"screen.toml" => "[[page]]\n"})

    capture_log(fn -> Poller.check_now(poller) end)
    refute_received {:revision_published, "lobby", _}
    assert Status.get("lobby").error =~ "rejected"
    assert {:ok, %{sha: ^good}} = Revisions.current(ctx.config)

    # Same SHA again: no new attempt, the error stays.
    log = capture_log(fn -> Poller.check_now(poller) end)
    refute log =~ "rejected"
    assert Status.get("lobby").error =~ "rejected"

    fixed = GitFixture.commit(ctx.src, @files)
    Poller.check_now(poller)
    assert_received {:revision_published, "lobby", ^fixed}
    assert Status.get("lobby").error == nil
  end

  test "records check errors, backs off, and recovers", ctx do
    poller = start_poller(ctx.config)
    assert_receive {:revision_published, "lobby", _}

    File.rename!(ctx.src, ctx.src <> ".away")

    capture_log(fn -> Poller.check_now(poller) end)
    assert Status.get("lobby").error =~ "check failed"
    assert :sys.get_state(poller).failures == 1

    File.rename!(ctx.src <> ".away", ctx.src)
    Poller.check_now(poller)

    assert Status.get("lobby").error == nil
    assert :sys.get_state(poller).failures == 0
  end

  test "resolves a tag once and does not poll it", ctx do
    GitFixture.git!(ctx.src, ["tag", "v1"])
    config = %{ctx.config | ref: "v1"}

    poller = start_poller(config)

    assert_receive {:revision_published, "lobby", sha}
    assert sha == ctx.sha
    assert :sys.get_state(poller).timer == nil
    assert Status.get("lobby").next_check_at == nil
  end

  test "prunes old revisions after publishing", ctx do
    poller = start_poller(ctx.config, keep: 0)
    assert_receive {:revision_published, "lobby", first}

    second = GitFixture.commit(ctx.src, %{"pages/a.html" => "v2"})
    Poller.check_now(poller)
    assert_received {:revision_published, "lobby", ^second}

    {:ok, host_config} = Store.get()
    rev = Path.join(Deepsplay.RevisionStore.repo_dir(host_config.cache_dir, ctx.url), "rev")
    assert File.ls!(rev) == [second]
    refute first == second
  end

  test "child_specs/1 starts one poller per repository and ref", %{tmp_dir: tmp_dir} do
    setup_screen(tmp_dir, @files, """
    [[config]]
    name     = "kitchen"
    repo     = "file://#{Path.join(tmp_dir, "src")}"
    ref      = "main"

    [[config]]
    name = "hall"
    repo = "file://#{Path.join(tmp_dir, "src")}"
    ref  = "other"
    """)

    {:ok, host_config} = Store.get()

    names =
      for {Poller, opts} <- Pollers.child_specs(host_config) do
        {opts[:ref], Enum.map(opts[:configs], & &1.name)}
      end

    assert names == [{"main", ["kitchen", "lobby"]}, {"other", ["hall"]}]
  end

  test "delay/2 jitters and backs off up to 5 minutes" do
    for _ <- 1..100 do
      assert Poller.delay(30_000, 0) in 24_000..36_000
      assert Poller.delay(30_000, 2) in 96_000..144_000
      assert Poller.delay(30_000, 10) in 240_000..360_000
    end
  end
end
