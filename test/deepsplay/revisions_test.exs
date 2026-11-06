defmodule Deepsplay.RevisionsTest do
  # Not async: uses the global host configuration.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Deepsplay.ScreenFixture

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Revisions
  alias Deepsplay.Screen

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => ~s(title = "Lobby"\n[[page]]\npath = "a.html"\nduration = "1s"\n),
    "rotations/random.toml" =>
      ~s(rotation = "random"\n[[page]]\npath = "a.html"\nduration = "2s"\n),
    "pages/a.html" => "a"
  }

  test "refresh/1 publishes, remembers and announces a valid revision", %{tmp_dir: tmp_dir} do
    %{sha: sha, config: config} = setup_screen(tmp_dir, @files)
    Revisions.subscribe("lobby")

    assert Revisions.current(config) == :none
    assert {:ok, ^sha} = Revisions.refresh(config)
    assert_receive {:revision_published, "lobby", ^sha}

    assert {:ok, %{sha: ^sha, screen: %Screen{title: "Lobby"}, pages_dir: pages_dir}} =
             Revisions.current(config)

    assert File.read!(Path.join(pages_dir, "a.html")) == "a"
  end

  test "refresh/1 keeps the last good revision when a new one is invalid", %{tmp_dir: tmp_dir} do
    %{src: src, sha: good, config: config} = setup_screen(tmp_dir, @files)
    {:ok, ^good} = Revisions.refresh(config)

    GitFixture.commit(src, %{"screen.toml" => "[[page]]\n"})

    log = capture_log(fn -> assert {:error, {:rejected, _, _}} = Revisions.refresh(config) end)
    assert log =~ ~s(config "lobby": revision)
    assert {:ok, %{sha: ^good}} = Revisions.current(config)
  end

  test "configurations on the same repository keep separate revisions", %{tmp_dir: tmp_dir} do
    %{src: src, config: lobby} =
      setup_screen(tmp_dir, @files, """
      [[config]]
      name     = "kitchen"
      repo     = "file://#{Path.join(tmp_dir, "src")}"
      ref      = "main"
      manifest = "rotations/random.toml"
      """)

    {:ok, host_config} = Store.get()
    kitchen = host_config.configs["kitchen"]

    {:ok, first} = Revisions.refresh(lobby)
    {:ok, ^first} = Revisions.refresh(kitchen)

    # A revision valid for lobby but not for kitchen.
    second = GitFixture.commit(src, %{"rotations/random.toml" => "broken = ["})

    assert {:ok, ^second} = Revisions.refresh(lobby)
    capture_log(fn -> assert {:error, {:rejected, ^second, _}} = Revisions.refresh(kitchen) end)

    assert {:ok, %{sha: ^second}} = Revisions.current(lobby)
    assert {:ok, %{sha: ^first, screen: %Screen{rotation: :random}}} = Revisions.current(kitchen)
  end
end
