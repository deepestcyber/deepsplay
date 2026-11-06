defmodule Deepsplay.SecretsTest do
  # Not async: secrets and the application environment are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deepsplay.Secrets

  setup do
    previous = Application.get_env(:deepsplay, :secrets_path)

    on_exit(fn ->
      Application.put_env(:deepsplay, :secrets_path, previous)
      Secrets.put(%{})
    end)
  end

  test "parse/1 reads name = value pairs and rejects bad entries" do
    assert Secrets.parse(~s(weather_api = "abc"\ngit_token = "def"\n)) ==
             {:ok, %{"weather_api" => "abc", "git_token" => "def"}}

    assert {:error, [error]} = Secrets.parse(~s(Weather = "abc"\n))
    assert error =~ ~s(secret "Weather")
    assert {:error, [_]} = Secrets.parse(~s(count = 3\n))
    assert {:error, [error]} = Secrets.parse("x = ")
    assert error =~ "invalid TOML"
  end

  test "from_env/1 maps DEEPSPLAY_SECRET_<NAME> to lowercase names" do
    env = %{"DEEPSPLAY_SECRET_WEATHER_API" => "abc", "OTHER" => "x", "DEEPSPLAY_SECRET_" => "y"}
    assert Secrets.from_env(env) == %{"weather_api" => "abc"}
  end

  @tag :tmp_dir
  test "load/0 reads the file, lets the environment win, and warns about open files",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "secrets.toml")
    File.write!(path, ~s(weather_api = "from-file"\nother = "x"\n))
    File.chmod!(path, 0o644)
    Application.put_env(:deepsplay, :secrets_path, path)
    System.put_env("DEEPSPLAY_SECRET_WEATHER_API", "from-env")

    try do
      log = capture_log(fn -> assert {:ok, ["other", "weather_api"]} = Secrets.load() end)
      assert log =~ "readable by others"
      refute log =~ "from-file"
      assert Secrets.fetch("weather_api") == {:ok, "from-env"}

      File.chmod!(path, 0o600)
      refute capture_log(fn -> Secrets.load() end) =~ "readable by others"
    after
      System.delete_env("DEEPSPLAY_SECRET_WEATHER_API")
    end
  end

  test "load/0 reports a missing file" do
    Application.put_env(:deepsplay, :secrets_path, "/nonexistent/secrets.toml")
    assert {:error, [error]} = Secrets.load()
    assert error =~ "cannot read /nonexistent/secrets.toml"
  end

  test "expand/1 and references/1 handle {secret:name} templates" do
    Secrets.put(%{"a" => "1", "b" => "2"})

    assert Secrets.expand("Bearer {secret:a}") == {:ok, "Bearer 1"}
    assert Secrets.expand("{secret:a}-{secret:b}") == {:ok, "1-2"}
    assert Secrets.expand("plain") == {:ok, "plain"}
    assert Secrets.expand("{secret:c}") == {:error, ~s(secret "c" is not defined)}
    assert Secrets.references("x {secret:a} y {secret:b}") == ["a", "b"]
  end
end
