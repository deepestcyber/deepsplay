defmodule Deepsplay.PageDocTest do
  use ExUnit.Case, async: true

  alias Deepsplay.PageDoc
  alias Deepsplay.PageDoc.Param

  @cases "test/support/fixtures/params_cases.json" |> File.read!() |> Jason.decode!()

  describe "shared parameter cases (same as deepsplay.js)" do
    for c <- @cases do
      @case c
      test @case["name"] do
        {params, _warnings} = PageDoc.params(@case["toml"])
        assert Param.values(params, @case["query"]) == @case["expect"]
      end
    end
  end

  describe "from_html/1" do
    test "finds the block, in either attribute order, and uses <title>" do
      html = """
      <!doctype html><html><head>
      <title>Game &amp; Life</title>
      <script id='deepsplay-page' type="application/toml">
      description = "Cells."
      uses = ["theme"]
      [params.cells]
      type = "int"
      default = 90
      description = "Cells along the shorter side."
      [[variants]]
      label = "Large"
      query = "?cells=40"
      </script>
      <script src="/lib/v1/deepsplay.js"></script>
      </head></html>
      """

      assert {:ok, doc} = PageDoc.from_html(html)
      assert doc.title == "Game & Life"
      assert doc.description == "Cells."
      assert doc.uses == ["theme"]
      assert doc.page == true
      assert doc.variants == [%{label: "Large", query: "cells=40"}]
      assert doc.warnings == []

      assert %Param{type: "int", default: 90, description: "Cells along the shorter side."} =
               doc.params["cells"]
    end

    test "an explicit title wins over <title>" do
      html =
        ~s(<title>T</title><script type="application/toml" id="deepsplay-page">title = "Mine"</script>)

      assert {:ok, %PageDoc{title: "Mine"}} = PageDoc.from_html(html)
    end

    test "page = false marks a fragment" do
      html = ~s(<script type="application/toml" id="deepsplay-page">page = false</script>)
      assert {:ok, %PageDoc{page: false}} = PageDoc.from_html(html)
    end

    test "no block, or another script, is :none" do
      assert PageDoc.from_html("<html><script>let a = 1</script></html>") == :none

      assert PageDoc.from_html(~s(<script type="application/toml" id="other">x = 1</script>)) ==
               :none
    end
  end

  describe "parse/2 warnings" do
    test "invalid TOML keeps the fallback title" do
      assert %PageDoc{title: "T", params: %{}, warnings: [warning]} =
               PageDoc.parse("[params", "T")

      assert warning =~ "invalid TOML"
    end

    test "unknown keys and wrong types are reported, the rest is kept" do
      doc =
        PageDoc.parse("""
        colour = "red"
        uses = "theme"
        page = "no"
        variants = [{label = "x"}]

        [params.ok]
        type = "int"
        default = 1

        [params.weird]
        type = "weird"

        [params.lim]
        type = "int"
        min = "a"
        size = 3
        from = "screen"
        """)

      assert Map.keys(doc.params) == ["lim", "ok"]
      assert doc.uses == []
      assert doc.page == true

      assert doc.warnings == [
               "uses must be a list of strings",
               "page must be true or false",
               ~s(parameter "lim": invalid min, ignored),
               ~s(parameter "lim": unknown from "screen"),
               ~s(parameter "lim": unknown key "size"),
               ~s(parameter "weird": unknown type "weird"),
               "variant #1 needs exactly a label and a query (strings)",
               ~s(unknown key "colour")
             ]
    end
  end

  describe "read/1" do
    @tag :tmp_dir
    test "reads a file, or reports it", %{tmp_dir: dir} do
      path = Path.join(dir, "a.html")

      File.write!(
        path,
        ~s(<script type="application/toml" id="deepsplay-page">description = "A"</script>)
      )

      assert {:ok, %PageDoc{description: "A"}} = PageDoc.read(path)
      assert {:error, message} = PageDoc.read(Path.join(dir, "missing.html"))
      assert message =~ "cannot read missing.html"
    end
  end
end
