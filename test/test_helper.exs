# The JavaScript tests of the page helper need Node.
exclude = if System.find_executable("node"), do: [], else: [:node]
ExUnit.start(exclude: exclude)
