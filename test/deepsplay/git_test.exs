defmodule Deepsplay.GitTest do
  use ExUnit.Case, async: true

  alias Deepsplay.Git

  test "returns output on success" do
    assert {:ok, "git version " <> _} = Git.run(["--version"])
  end

  test "returns status and output on failure" do
    assert {:error, {:exit, status, output}} = Git.run(["no-such-command"])
    assert status != 0
    assert output =~ "no-such-command"
  end

  @tag :tmp_dir
  test "runs without global config", %{tmp_dir: tmp_dir} do
    assert {:ok, _} = Git.run(["init", "--quiet", tmp_dir])
    assert {:error, {:exit, 1, ""}} = Git.run(["-C", tmp_dir, "config", "--get", "user.name"])
  end

  test "kills git on timeout" do
    # `git hash-object --stdin` waits for input that never comes.
    assert {:error, :timeout} = Git.run(["hash-object", "--stdin"], timeout: 200)
  end
end
