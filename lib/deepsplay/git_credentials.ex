defmodule Deepsplay.GitCredentials do
  @moduledoc """
  Credentials for fetching private repositories (ADR 6, ADR 8).

  A configuration's `credential` names a host secret. It reaches git only
  through the environment and files readable by the server's user, never on
  the command line or in logs:

    * `https` repositories: the secret is a token, or `username:token`. A small
      `GIT_ASKPASS` script answers git's prompts from environment variables.
      Without a username, `x-access-token` is used (GitHub's convention).
    * `ssh` repositories: the secret is a private key (OpenSSH format). It is
      written to a file with mode 0600 and used through `GIT_SSH_COMMAND`.
      Host keys are trusted on first use: the first connection records the
      key in a `known_hosts` file, and a changed key later fails the fetch.

  Helper files live in `<cache_dir>/.credentials/`.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.Secrets

  @askpass """
  #!/bin/sh
  # Answers git's credential prompts from the environment (deepsplay).
  case "$1" in
    Username*) printf '%s\\n' "$DEEPSPLAY_GIT_USERNAME" ;;
    *) printf '%s\\n' "$DEEPSPLAY_GIT_PASSWORD" ;;
  esac
  """

  @doc """
  Returns the environment for git calls of a configuration: empty without a
  credential.

  ## Options

    * `:cache_dir` - defaults to the host configuration's
  """
  @spec env(Config.t(), keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def env(config, opts \\ [])

  def env(%Config{credential: nil}, _opts), do: {:ok, []}

  def env(%Config{credential: name, repo: repo}, opts) do
    with {:ok, secret} <- fetch_secret(name),
         {:ok, dir} <- credentials_dir(opts) do
      case RepoUrl.transport(repo) do
        {:ok, "ssh"} -> ssh_env(dir, name, secret)
        {:ok, _https_or_file} -> https_env(dir, secret)
        :error -> {:error, "unsupported repository URL"}
      end
    end
  end

  defp fetch_secret(name) do
    case Secrets.fetch(name) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, ~s(credential secret "#{name}" is not defined)}
    end
  end

  defp credentials_dir(opts) do
    cache_dir =
      Keyword.get_lazy(opts, :cache_dir, fn ->
        case Store.get() do
          {:ok, host_config} -> host_config.cache_dir
          {:error, _errors} -> nil
        end
      end)

    if cache_dir do
      dir = Path.join(cache_dir, ".credentials")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      {:ok, dir}
    else
      {:error, "host configuration unusable"}
    end
  end

  defp https_env(dir, secret) do
    {username, password} =
      case String.split(secret, ":", parts: 2) do
        [username, password] when username != "" -> {username, password}
        _token -> {"x-access-token", secret}
      end

    script = Path.join(dir, "askpass.sh")
    write_private(script, @askpass, 0o700)

    {:ok,
     [
       {"GIT_ASKPASS", script},
       {"DEEPSPLAY_GIT_USERNAME", username},
       {"DEEPSPLAY_GIT_PASSWORD", password}
     ]}
  end

  defp ssh_env(dir, name, secret) do
    key = Path.join(dir, "#{name}.key")
    known_hosts = Path.join(dir, "known_hosts")
    # ssh refuses keys without a final newline in some versions.
    write_private(key, String.trim_trailing(secret) <> "\n", 0o600)

    command =
      Enum.join(
        [
          "ssh",
          "-i #{quote_arg(key)}",
          "-o IdentitiesOnly=yes",
          "-o BatchMode=yes",
          "-o StrictHostKeyChecking=accept-new",
          "-o UserKnownHostsFile=#{quote_arg(known_hosts)}"
        ],
        " "
      )

    {:ok, [{"GIT_SSH_COMMAND", command}]}
  end

  # Written with restrictive permissions before any content lands in it.
  defp write_private(path, content, mode) do
    File.touch!(path)
    File.chmod!(path, mode)
    File.write!(path, content)
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
