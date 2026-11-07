defmodule Deepsplay.PollersReconcileTest do
  # Not async: switches pollers on for the test and uses the global registry.
  use ExUnit.Case, async: false

  alias Deepsplay.HostConfig
  alias Deepsplay.Pollers

  @moduletag :tmp_dir

  defp host_config(tmp_dir, names, extra \\ "") do
    configs =
      for name <- names do
        dir = Path.join(tmp_dir, name)
        File.mkdir_p!(Path.join(dir, "pages"))
        File.write!(Path.join(dir, "screen.toml"), ~s([[page]]\npath = "a.html"\n))
        File.write!(Path.join(dir, "pages/a.html"), "a")

        "[[config]]\nname = \"#{name}\"\npath = \"#{dir}\"\n#{if name == "b", do: extra, else: ""}\n"
      end

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{tmp_dir}/cache"
      default_config = "#{hd(names)}"

      #{Enum.join(configs)}
      """)

    {:ok, host_config}
  end

  setup do
    previous = Application.get_env(:deepsplay, :start_pollers)
    Application.put_env(:deepsplay, :start_pollers, true)
    on_exit(fn -> Application.put_env(:deepsplay, :start_pollers, previous) end)

    sup =
      start_supervised!(%{
        id: :sup,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]}
      })

    %{sup: sup}
  end

  defp running(sup),
    do: sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  test "starts new, stops unused, restarts changed and keeps unchanged children", %{
    sup: sup,
    tmp_dir: tmp_dir
  } do
    old = host_config(tmp_dir, ["a", "b"])

    assert Pollers.reconcile({:error, []}, old, sup).started == [
             {Deepsplay.LocalWatcher, "a"},
             {Deepsplay.LocalWatcher, "b"}
           ]

    [{_id, b_pid, _type, _modules}] =
      Enum.filter(Supervisor.which_children(sup), &(elem(&1, 0) == {Deepsplay.LocalWatcher, "b"}))

    new = host_config(tmp_dir, ["b", "c"])

    assert Pollers.reconcile(old, new, sup) == %{
             stopped: [{Deepsplay.LocalWatcher, "a"}],
             started: [{Deepsplay.LocalWatcher, "c"}]
           }

    assert running(sup) == [{Deepsplay.LocalWatcher, "b"}, {Deepsplay.LocalWatcher, "c"}]
    # "b" kept running.
    assert Enum.any?(Supervisor.which_children(sup), &(elem(&1, 1) == b_pid))

    changed = host_config(tmp_dir, ["b", "c"], ~s(description = "now described"))

    assert Pollers.reconcile(new, changed, sup) == %{
             stopped: [{Deepsplay.LocalWatcher, "b"}],
             started: [{Deepsplay.LocalWatcher, "b"}]
           }

    assert Pollers.reconcile(changed, {:error, ["broken"]}, sup).started == []
    assert running(sup) == []
  end
end
