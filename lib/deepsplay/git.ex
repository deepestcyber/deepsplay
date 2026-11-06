defmodule Deepsplay.Git do
  @moduledoc """
  Runs the `git` command-line tool (ADR 6).

  Every call runs isolated from user and system git configuration, without
  prompts and hooks, with only the allowed transports, and with a timeout.
  Output is returned with credentials removed from URLs.
  """

  alias Deepsplay.HostConfig
  alias Deepsplay.RepoUrl

  @default_timeout 60_000

  @type error :: {:exit, non_neg_integer(), String.t()} | :timeout | :git_not_found

  @doc """
  Runs `git` with `args`.

  ## Options

    * `:cd` - working directory
    * `:env` - extra environment variables, as `{name, value}` string pairs
    * `:timeout` - in milliseconds; defaults to the `:git_timeout` application
      setting, or #{@default_timeout}
    * `:transports` - allowed transports; defaults to
      `Deepsplay.HostConfig.allowed_transports/0`
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, error()}
  def run(args, opts \\ []) do
    case System.find_executable("git") do
      nil -> {:error, :git_not_found}
      git -> exec(git, args, opts)
    end
  end

  defp exec(git, args, opts) do
    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Application.get_env(:deepsplay, :git_timeout, @default_timeout)
      end)

    transports = Keyword.get_lazy(opts, :transports, &HostConfig.allowed_transports/0)

    env =
      [
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_ALLOW_PROTOCOL", Enum.join(transports, ":")},
        {"LC_ALL", "C"}
      ] ++ Keyword.get(opts, :env, [])

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-c", "core.hooksPath=/dev/null" | args],
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ] ++ if(cd = opts[:cd], do: [cd: cd], else: [])

    port = Port.open({:spawn_executable, git}, port_opts)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, deadline, [])
  end

  defp collect(port, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, [acc | data])

      {^port, {:exit_status, 0}} ->
        {:ok, output(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, output(acc)}}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp output(acc), do: acc |> IO.iodata_to_binary() |> RepoUrl.redact_text()

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)])
      nil -> :ok
    end

    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Formats a git error for logs, the status page and the fallback page.
  """
  @spec format_error(error()) :: String.t()
  def format_error({:exit, status, output}),
    do: "git exited with status #{status}: #{String.trim(output)}"

  def format_error(:timeout), do: "git timed out"
  def format_error(:git_not_found), do: "git executable not found"
end
