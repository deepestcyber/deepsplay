defmodule Deepsplay.PageHelperJsTest do
  # Runs the JavaScript tests of the built page helper (priv/lib/deepsplay.js,
  # built by the test alias) with Node, against the same parameter cases as
  # Deepsplay.PageDocTest. Excluded when Node is not installed.
  use ExUnit.Case, async: true

  @moduletag :node

  test "deepsplay.js passes the shared cases and API checks" do
    {output, status} = System.cmd("node", ["test/js/deepsplay_test.mjs"], stderr_to_stdout: true)
    assert status == 0, output
  end
end
