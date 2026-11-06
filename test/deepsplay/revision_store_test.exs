defmodule Deepsplay.RevisionStoreTest do
  use ExUnit.Case, async: true

  alias Deepsplay.GitFixture
  alias Deepsplay.RevisionStore

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")
    url = GitFixture.init(src)
    cache = Path.join(tmp_dir, "cache")
    %{src: src, url: url, cache: cache, opts: [cache_dir: cache]}
  end

  defp repo_dir(ctx), do: RevisionStore.repo_dir(ctx.cache, ctx.url)

  describe "publish/3" do
    test "exports the commit to rev/<sha>/ without .git and remembers it", ctx do
      sha = GitFixture.commit(ctx.src, %{"index.html" => "<h1>hi</h1>", "a/b.txt" => "b"})

      assert {:ok, ^sha} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      {:ok, dir} = RevisionStore.revision_dir(ctx.url, sha, ctx.opts)
      assert File.read!(Path.join(dir, "index.html")) == "<h1>hi</h1>"
      assert File.read!(Path.join(dir, "a/b.txt")) == "b"
      refute File.exists?(Path.join(dir, ".git"))

      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == {:ok, sha}
      assert File.ls!(Path.join(repo_dir(ctx), "tmp")) == []
    end

    test "reuses an existing revision instead of exporting again", ctx do
      sha = GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, ^sha} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      {:ok, dir} = RevisionStore.revision_dir(ctx.url, sha, ctx.opts)
      File.write!(Path.join(dir, "marker"), "kept")

      assert {:ok, ^sha} = RevisionStore.publish(ctx.url, "main", ctx.opts)
      assert File.read!(Path.join(dir, "marker")) == "kept"
    end

    test "publishes a new revision when the branch moves, keeping the old one", ctx do
      old = GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, ^old} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      new = GitFixture.commit(ctx.src, %{"index.html" => "v2"})
      assert {:ok, ^new} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == {:ok, new}
      assert File.dir?(Path.join([repo_dir(ctx), "rev", old]))
    end

    test "resolves tags, full SHAs and branch names with slashes", ctx do
      first = GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      GitFixture.git!(ctx.src, ["tag", "v1"])
      GitFixture.git!(ctx.src, ["branch", "feature/x"])
      _second = GitFixture.commit(ctx.src, %{"index.html" => "v2"})

      assert {:ok, ^first} = RevisionStore.publish(ctx.url, "v1", ctx.opts)
      assert {:ok, ^first} = RevisionStore.publish(ctx.url, first, ctx.opts)
      assert {:ok, ^first} = RevisionStore.publish(ctx.url, "feature/x", ctx.opts)
      assert RevisionStore.last_good(ctx.url, "feature/x", ctx.opts) == {:ok, first}
    end

    test "serializes concurrent requests for the same revision", ctx do
      sha = GitFixture.commit(ctx.src, %{"index.html" => "v1"})

      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> RevisionStore.publish(ctx.url, "main", ctx.opts) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &(&1 == {:ok, sha}))
    end

    test "rejects a revision with symlinks and keeps the last good one", ctx do
      good = GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, ^good} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      bad = GitFixture.commit_symlink(ctx.src, "passwd", "/etc/passwd")

      assert {:error, {:rejected, ^bad, message}} =
               RevisionStore.publish(ctx.url, "main", ctx.opts)

      assert message =~ "symlinks: passwd"
      refute File.exists?(Path.join([repo_dir(ctx), "rev", bad]))
      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == {:ok, good}
      assert File.ls!(Path.join(repo_dir(ctx), "tmp")) == []
    end

    test "rejects a revision the validator refuses", ctx do
      sha = GitFixture.commit(ctx.src, %{"index.html" => "v1"})

      validate = fn dir ->
        if File.exists?(Path.join(dir, "screen.toml")), do: :ok, else: {:error, "no screen.toml"}
      end

      assert {:error, {:rejected, ^sha, "no screen.toml"}} =
               RevisionStore.publish(ctx.url, "main", [validate: validate] ++ ctx.opts)

      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == :error
    end

    test "reports an unknown ref", ctx do
      GitFixture.commit(ctx.src, %{"index.html" => "v1"})

      assert {:error, {:fetch, message}} = RevisionStore.publish(ctx.url, "nope", ctx.opts)
      assert message =~ "nope"
    end

    test "refuses invalid refs and disallowed transports without running git", ctx do
      for ref <- ["-x", "--upload-pack=evil", "a..b", "a b", ""] do
        assert {:error, {:config, _}} = RevisionStore.publish(ctx.url, ref, ctx.opts), ref
      end

      assert {:error, {:config, ~s(transport "file" is not allowed)}} =
               RevisionStore.publish(ctx.url, "main", [transports: ["https"]] ++ ctx.opts)

      refute File.exists?(ctx.cache)
    end

    test "never returns credentials from the URL in errors", ctx do
      url = "https://user:secret-token@127.0.0.1:1/repo.git"

      assert {:error, {:fetch, message}} =
               RevisionStore.publish(url, "main", [git: [timeout: 10_000]] ++ ctx.opts)

      refute message =~ "secret-token"
    end
  end

  describe "last_good/3" do
    test "is :error when nothing was published or the revision is gone", ctx do
      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == :error

      sha = GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, ^sha} = RevisionStore.publish(ctx.url, "main", ctx.opts)
      File.rm_rf!(Path.join([repo_dir(ctx), "rev", sha]))

      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == :error
    end
  end

  describe "prune/3" do
    test "keeps revisions in use plus the most recent others", ctx do
      shas =
        for n <- 1..5 do
          sha = GitFixture.commit(ctx.src, %{"index.html" => "v#{n}"})
          {:ok, ^sha} = RevisionStore.publish(ctx.url, "main", ctx.opts)
          sha
        end

      [s1, s2, s3, s4, s5] = shas

      assert :ok = RevisionStore.prune(ctx.url, [s5, s1], [keep: 2] ++ ctx.opts)

      kept = File.ls!(Path.join(repo_dir(ctx), "rev")) |> Enum.sort()
      assert kept == Enum.sort([s1, s3, s4, s5])
      refute s2 in kept
      assert RevisionStore.last_good(ctx.url, "main", ctx.opts) == {:ok, s5}
    end
  end

  describe "prune_repositories/2" do
    test "deletes directories of repositories no longer configured", ctx do
      GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, _} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      other_src = Path.join(ctx.tmp_dir, "other")
      other = GitFixture.init(other_src)
      GitFixture.commit(other_src, %{"index.html" => "x"})
      {:ok, _} = RevisionStore.publish(other, "main", ctx.opts)

      assert :ok = RevisionStore.prune_repositories([ctx.url], ctx.opts)

      assert File.dir?(repo_dir(ctx))
      refute File.exists?(RevisionStore.repo_dir(ctx.cache, other))
    end
  end

  describe "writer start" do
    test "empties tmp/", ctx do
      GitFixture.commit(ctx.src, %{"index.html" => "v1"})
      {:ok, _} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      leftover = Path.join([repo_dir(ctx), "tmp", "half-written"])
      File.write!(leftover, "x")

      Deepsplay.RevisionStore.Writer.stop(ctx.cache, Deepsplay.RepoUrl.key(ctx.url))
      {:ok, _} = RevisionStore.publish(ctx.url, "main", ctx.opts)

      refute File.exists?(leftover)
    end
  end
end
