# The JavaScript tests of the page helper need Node; the backend tests need uv
# (and Python, which uv finds or installs).
exclude =
  [node: "node", uv: "uv"]
  |> Enum.reject(fn {_tag, executable} -> System.find_executable(executable) end)
  |> Enum.map(fn {tag, _executable} -> tag end)

ExUnit.start(exclude: exclude)
