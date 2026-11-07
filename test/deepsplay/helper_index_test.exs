defmodule Deepsplay.HelperIndexTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HelperIndex
  alias Deepsplay.PageDoc
  alias Deepsplay.PageDoc.Param

  @moduletag :tmp_dir

  @theme """
  // Theme helper
  const T = Deepsplay.helper("theme", `
  description = "Colours and fonts."

  [params.theme]
  type    = "enum"
  values  = ["default", "neon"]
  default = "default"

  [params.duration]
  type = "duration"
  from = "duration"
  `)
  if (T.theme !== "default") document.write("…")
  """

  defp write(dir, files) do
    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    dir
  end

  describe "build/1" do
    test "finds helper registrations in JavaScript files below pages/", %{tmp_dir: dir} do
      write(dir, %{
        "shared/theme/theme.js" => @theme,
        "shared/clock.mjs" => ~s{Deepsplay.helper('clock', `[params.tz]\ntype = "string"`)},
        "other.js" => "console.log('no helper here')"
      })

      index = HelperIndex.build(dir)

      assert Map.keys(index.helpers) == ["clock", "theme"]
      assert index.warnings == []

      theme = index.helpers["theme"]
      assert theme.file == "shared/theme/theme.js"
      assert theme.description == "Colours and fonts."
      assert theme.warnings == []
      assert %Param{type: "enum", default: "default"} = theme.params["theme"]
      assert %Param{type: "duration", from: "duration"} = theme.params["duration"]
    end

    test "the first registration of a name counts", %{tmp_dir: dir} do
      write(dir, %{
        "a/theme.js" => @theme,
        "b/theme.js" => ~s{Deepsplay.helper("theme", `[params.other]\ntype = "int"`)}
      })

      index = HelperIndex.build(dir)

      assert index.helpers["theme"].file == "a/theme.js"

      assert index.warnings == [
               ~s(helper "theme" in b/theme.js is ignored; a/theme.js registers it first)
             ]
    end

    test "keeps definition warnings with the helper", %{tmp_dir: dir} do
      write(dir, %{"h.js" => ~s{Deepsplay.helper("h", `[params.x]\ntype = "weird"`)}})

      assert HelperIndex.build(dir).helpers["h"].warnings == [
               ~s(parameter "x": unknown type "weird")
             ]
    end

    test "skips hidden files and symlinks", %{tmp_dir: dir} do
      write(dir, %{".hidden/theme.js" => @theme})
      File.ln_s!(Path.join(dir, ".hidden/theme.js"), Path.join(dir, "link.js"))

      assert HelperIndex.build(dir).helpers == %{}
    end
  end

  describe "params_for/2" do
    setup %{tmp_dir: dir} do
      write(dir, %{
        "theme.js" => @theme,
        "extra.js" =>
          ~s{Deepsplay.helper("extra", `[params.theme]\ntype = "string"\n[params.speed]\ntype = "number"`)}
      })

      %{index: HelperIndex.build(dir)}
    end

    test "combines the page's parameters with its helpers', with origins", %{index: index} do
      doc = PageDoc.parse(~s(uses = ["theme"]\n[params.cells]\ntype = "int"))

      assert {params, []} = HelperIndex.params_for(doc, index)
      assert Map.keys(params) == ["cells", "duration", "theme"]
      assert {%Param{type: "int"}, :page} = params["cells"]
      assert {%Param{type: "enum"}, {:helper, "theme"}} = params["theme"]
    end

    test "the page wins over a helper, an earlier helper over a later one", %{index: index} do
      doc =
        PageDoc.parse(
          ~s(uses = ["theme", "extra"]\n[params.duration]\ntype = "duration"\ndefault = "3s")
        )

      assert {params, warnings} = HelperIndex.params_for(doc, index)

      assert {%Param{default: 3000}, :page} = params["duration"]
      assert {%Param{type: "enum"}, {:helper, "theme"}} = params["theme"]
      assert {%Param{type: "number"}, {:helper, "extra"}} = params["speed"]

      assert warnings == [
               ~s(parameter "duration" of helper "theme" is replaced by the page's),
               ~s(parameter "theme" of helper "extra" is replaced by helper "theme")
             ]
    end

    test "unknown helpers are warnings", %{index: index} do
      doc = PageDoc.parse(~s(uses = ["nope"]))
      assert HelperIndex.params_for(doc, index) == {%{}, [~s(uses unknown helper "nope")]}
    end
  end
end
