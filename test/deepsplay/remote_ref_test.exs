defmodule Deepsplay.RemoteRefTest do
  use ExUnit.Case, async: true

  alias Deepsplay.GitFixture
  alias Deepsplay.RemoteRef

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")
    url = GitFixture.init(src)
    sha = GitFixture.commit(src, %{"a" => "1"})
    %{src: src, url: url, sha: sha}
  end

  test "resolves a branch", %{url: url, sha: sha} do
    assert RemoteRef.resolve(url, "main") == {:ok, %{sha: sha, kind: :branch}}
  end

  test "does not confuse a branch with a longer one ending the same way", ctx do
    GitFixture.git!(ctx.src, ["branch", "feature/main"])
    GitFixture.commit(ctx.src, %{"a" => "2"})
    GitFixture.git!(ctx.src, ["branch", "-f", "feature/main"])

    assert {:ok, %{sha: sha}} = RemoteRef.resolve(ctx.url, "main")
    assert sha == GitFixture.head(ctx.src)
  end

  test "resolves annotated and lightweight tags to the commit", %{src: src, url: url, sha: sha} do
    GitFixture.git!(src, ["tag", "--annotate", "v1", "--message", "v1"])
    GitFixture.git!(src, ["tag", "light"])

    assert RemoteRef.resolve(url, "v1") == {:ok, %{sha: sha, kind: :tag}}
    assert RemoteRef.resolve(url, "light") == {:ok, %{sha: sha, kind: :tag}}
  end

  test "returns a full SHA without asking the remote" do
    sha = String.duplicate("a", 40)
    assert RemoteRef.resolve("file:///nonexistent", sha) == {:ok, %{sha: sha, kind: :sha}}
  end

  test "reports a missing ref and an unreachable repository", %{url: url} do
    assert RemoteRef.resolve(url, "nope") == {:error, ~s(ref "nope" not found)}
    assert {:error, message} = RemoteRef.resolve("file:///nonexistent/repo", "main")
    assert message =~ "git exited"
  end
end
