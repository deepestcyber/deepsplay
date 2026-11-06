defmodule Deepsplay.RevisionFileTest do
  use ExUnit.Case, async: true

  alias Deepsplay.RevisionFile

  doctest RevisionFile

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir_p!(Path.join(root, "a"))
    File.write!(Path.join(root, "index.html"), "i")
    File.write!(Path.join(root, "a/b.css"), "b")
    File.write!(Path.join(tmp_dir, "secret"), "s")
    File.ln_s!(Path.join(tmp_dir, "secret"), Path.join(root, "link"))
    File.ln_s!(tmp_dir, Path.join(root, "dirlink"))
    %{root: root}
  end

  test "resolves regular files", %{root: root} do
    assert RevisionFile.resolve(root, "index.html") == {:ok, Path.join(root, "index.html")}
    assert RevisionFile.resolve(root, ["a", "b.css"]) == {:ok, Path.join(root, "a/b.css")}
  end

  test "rejects traversal, empty and odd segments", %{root: root} do
    for path <- ["../secret", "a/../../secret", "/etc/passwd", "", "a//b.css", "./index.html"] do
      assert RevisionFile.resolve(root, path) == :error, path
    end

    assert RevisionFile.resolve(root, []) == :error
    assert RevisionFile.resolve(root, ["a\\b.css"]) == :error
  end

  test "rejects hidden files and directories", %{root: root} do
    File.write!(Path.join(root, ".env"), "x")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "x")

    assert RevisionFile.resolve(root, ".env") == :error
    assert RevisionFile.resolve(root, ".git/config") == :error
    assert RevisionFile.hidden?(".git/config")
    refute RevisionFile.hidden?("a/b.css")
  end

  test "rejects symlinks, directories and missing files", %{root: root} do
    assert RevisionFile.resolve(root, "link") == :error
    assert RevisionFile.resolve(root, "dirlink/secret") == :error
    assert RevisionFile.resolve(root, "a") == :error
    assert RevisionFile.resolve(root, "missing.html") == :error
  end

  test "sha?/1" do
    assert RevisionFile.sha?(String.duplicate("a", 40))
    assert RevisionFile.sha?(String.duplicate("0", 64))
    refute RevisionFile.sha?(String.duplicate("a", 39))
    refute RevisionFile.sha?(String.duplicate("A", 40))
    refute RevisionFile.sha?("main")
  end
end
