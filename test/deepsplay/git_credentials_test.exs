defmodule Deepsplay.GitCredentialsTest do
  # Not async: secrets are global.
  use ExUnit.Case, async: false

  alias Deepsplay.GitCredentials
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.Secrets

  @moduletag :tmp_dir

  setup do
    Secrets.put(%{
      "token" => "t0k3n",
      "user_token" => "deploy-bot:t0k3n",
      "deploy_key" =>
        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
    })

    on_exit(fn -> Secrets.put(%{}) end)
  end

  defp config(repo, credential),
    do: %Config{name: "x", repo: repo, ref: "main", credential: credential}

  test "no credential, no environment", %{tmp_dir: dir} do
    assert GitCredentials.env(config("https://e.com/a.git", nil), cache_dir: dir) == {:ok, []}
  end

  test "https: an askpass script answers from the environment", %{tmp_dir: dir} do
    {:ok, env} = GitCredentials.env(config("https://e.com/a.git", "token"), cache_dir: dir)
    env = Map.new(env)

    assert env["DEEPSPLAY_GIT_USERNAME"] == "x-access-token"
    assert env["DEEPSPLAY_GIT_PASSWORD"] == "t0k3n"

    script = env["GIT_ASKPASS"]
    refute File.read!(script) =~ "t0k3n"
    assert Bitwise.band(File.stat!(script).mode, 0o777) == 0o700

    run = fn prompt ->
      {out, 0} = System.cmd(script, [prompt], env: Map.to_list(Map.delete(env, "GIT_ASKPASS")))
      String.trim(out)
    end

    assert run.("Username for 'https://e.com': ") == "x-access-token"
    assert run.("Password for 'https://x-access-token@e.com': ") == "t0k3n"
  end

  test "https: a username can be given as username:token", %{tmp_dir: dir} do
    {:ok, env} = GitCredentials.env(config("https://e.com/a.git", "user_token"), cache_dir: dir)
    assert {"DEEPSPLAY_GIT_USERNAME", "deploy-bot"} in env
    assert {"DEEPSPLAY_GIT_PASSWORD", "t0k3n"} in env
  end

  test "ssh: a private key file and trust on first use", %{tmp_dir: dir} do
    {:ok, [{"GIT_SSH_COMMAND", command}]} =
      GitCredentials.env(config("git@e.com:org/a.git", "deploy_key"), cache_dir: dir)

    key = Path.join([dir, ".credentials", "deploy_key.key"])
    assert File.read!(key) =~ "END OPENSSH PRIVATE KEY-----\n"
    assert Bitwise.band(File.stat!(key).mode, 0o777) == 0o600
    assert command =~ "-i '#{key}'"
    assert command =~ "StrictHostKeyChecking=accept-new"
    assert command =~ "UserKnownHostsFile='#{Path.join([dir, ".credentials", "known_hosts"])}'"
    assert command =~ "BatchMode=yes"
  end

  test "a missing secret is an error", %{tmp_dir: dir} do
    assert GitCredentials.env(config("https://e.com/a.git", "nope"), cache_dir: dir) ==
             {:error, ~s(credential secret "nope" is not defined)}
  end
end
