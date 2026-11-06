defmodule Deepsplay.RepoUrlTest do
  use ExUnit.Case, async: true

  alias Deepsplay.RepoUrl

  doctest RepoUrl

  test "transport/1" do
    assert RepoUrl.transport("https://example.com/a.git") == {:ok, "https"}
    assert RepoUrl.transport("ssh://git@example.com/a.git") == {:ok, "ssh"}
    assert RepoUrl.transport("git@example.com:org/a.git") == {:ok, "ssh"}
    assert RepoUrl.transport("file:///srv/a.git") == {:ok, "file"}
    assert RepoUrl.transport("http://example.com/a.git") == :error
    assert RepoUrl.transport("./a.git") == :error
  end

  test "redact/1 removes user info from URLs with a scheme" do
    assert RepoUrl.redact("https://token@example.com/a.git") == "https://***@example.com/a.git"
    assert RepoUrl.redact("https://example.com/a.git") == "https://example.com/a.git"
    assert RepoUrl.redact("git@example.com:org/a.git") == "git@example.com:org/a.git"
  end
end
