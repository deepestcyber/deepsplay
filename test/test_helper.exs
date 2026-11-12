# The JavaScript tests of the page helper need Node; the backend tests need uv
# (and Python, which uv finds or installs); the MQTT broker tests need
# mosquitto and its tools, and openssl.
exclude =
  [
    node: ["node"],
    uv: ["uv"],
    mosquitto: ["mosquitto", "mosquitto_pub", "mosquitto_passwd", "openssl"]
  ]
  |> Enum.reject(fn {_tag, executables} -> Enum.all?(executables, &System.find_executable/1) end)
  |> Enum.map(fn {tag, _executable} -> tag end)

ExUnit.start(exclude: exclude)
