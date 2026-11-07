defmodule Deepsplay.PageParamsTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.PageParams
  alias Deepsplay.Screen
  alias Deepsplay.Screen.Page

  doctest PageParams

  @moduletag :tmp_dir

  @theme """
  const T = Deepsplay.helper("theme", `
  [params.theme]
  type    = "enum"
  values  = ["default", "dc", "neon"]
  default = "default"

  [params.duration]
  type = "duration"
  from = "duration"
  `)
  """

  defp block(toml),
    do: ~s(<script type="application/toml" id="deepsplay-page">\n#{toml}\n</script>)

  setup %{tmp_dir: dir} do
    files = %{
      "shared/theme.js" => @theme,
      "a.html" => block(~s(uses = ["theme"]\n[params.speed]\ntype = "number"\nmin = 1)),
      "own-duration.html" =>
        block(~s(uses = ["theme"]\n[params.duration]\ntype = "duration"\ndefault = "3s")),
      "plain.html" => "<h1>no block</h1>"
    }

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    config = %Config{name: "lobby", path: "/x", params: %{"theme" => "neon", "speed" => "fast"}}

    screen = %Screen{
      params: %{"theme" => "dc", "unused" => "1"},
      pages: [
        %Page{path: "a.html", query: "speed=5", duration: 30_000},
        %Page{path: "plain.html", duration: 10_000}
      ]
    }

    %{context: %{config: config, screen: screen, pages_dir: dir, key: "rev1"}}
  end

  test "adds declared parameters by precedence, not those the page sets", %{context: context} do
    assert {added, [], declared} = PageParams.for_page(context, "a.html", "speed=5", 30_000)

    # theme from the configuration (beats the manifest), duration provided;
    # speed is in the page's own query.
    assert added == [{"duration", "30s"}, {"theme", "neon"}]
    assert Enum.sort(declared) == ["duration", "speed", "theme"]
  end

  test "an invalid value is skipped with a warning, the next level counts", %{context: context} do
    assert {added, warnings, _} = PageParams.for_page(context, "a.html", nil, 1_500)

    refute List.keymember?(added, "speed", 0)
    assert {"duration", "1500ms"} in added
    assert warnings == [~s(configuration value speed="fast" is invalid for a.html)]

    context = put_in(context.config.params["theme"], "plaid")
    assert {added, warnings, _} = PageParams.for_page(context, "a.html", "speed=2", nil)
    assert added == [{"theme", "dc"}]
    assert warnings == [~s(configuration value theme="plaid" is invalid for a.html)]
  end

  test "pinned pages (no display time) get no duration", %{context: context} do
    assert {added, [], _} = PageParams.for_page(context, "a.html", "speed=2", nil)
    assert added == [{"theme", "neon"}]
  end

  test "a page's own definition replaces the helper's, without from", %{context: context} do
    assert {added, [], _} = PageParams.for_page(context, "own-duration.html", nil, 30_000)
    assert added == [{"theme", "neon"}]
  end

  test "undocumented pages and missing files get nothing", %{context: context} do
    assert PageParams.for_page(context, "plain.html", nil, 10_000) == {[], [], []}
    assert PageParams.for_page(context, "missing.html", nil, 10_000) == {[], [], []}
  end

  test "for_rotation/1 adds per page and warns about undeclared defaults", %{context: context} do
    assert {[a, plain], warnings} = PageParams.for_rotation(context)

    assert a == [{"duration", "30s"}, {"theme", "neon"}]
    assert plain == []

    assert warnings == [
             ~s(default parameter "unused" from the manifest is not declared by any page)
           ]
  end

  test "merge_query/2" do
    assert PageParams.merge_query(nil, []) == nil
    assert PageParams.merge_query("a=1", []) == "a=1"
    assert PageParams.merge_query(nil, [{"theme", "neon"}]) == "theme=neon"
    assert PageParams.merge_query("a=1", [{"t", "x y"}]) == "a=1&t=x+y"
  end
end
