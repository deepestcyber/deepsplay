defmodule Deepsplay.RepoUrl do
  @moduledoc """
  Helpers for git repository URLs: which transport a URL uses, and a form of it
  that is safe to show.
  """

  @doc """
  Returns the git transport a repository URL uses.

  Recognizes `https://`, `ssh://`, scp-like `user@host:path` (ssh) and
  `file://`. Anything else, including plain local paths, is `:error`.

      iex> Deepsplay.RepoUrl.transport("git@github.com:example/screens.git")
      {:ok, "ssh"}

      iex> Deepsplay.RepoUrl.transport("/srv/repo.git")
      :error
  """
  @spec transport(String.t()) :: {:ok, String.t()} | :error
  def transport(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://") -> {:ok, "https"}
      String.starts_with?(url, "ssh://") -> {:ok, "ssh"}
      String.starts_with?(url, "file://") -> {:ok, "file"}
      scp_like?(url) -> {:ok, "ssh"}
      true -> :error
    end
  end

  @doc """
  Removes credentials from a repository URL, so it can be shown or logged.

      iex> Deepsplay.RepoUrl.redact("https://user:token@example.com/repo.git")
      "https://***@example.com/repo.git"
  """
  @spec redact(String.t()) :: String.t()
  def redact(url) when is_binary(url) do
    if String.contains?(url, "://") do
      case URI.parse(url) do
        %URI{userinfo: nil} -> url
        %URI{} = uri -> URI.to_string(%{uri | userinfo: "***"})
      end
    else
      url
    end
  end

  @doc """
  Removes credentials from every URL in a text, such as git's output.

      iex> Deepsplay.RepoUrl.redact_text("fatal: unable to access 'https://user:token@example.com/a.git/'")
      "fatal: unable to access 'https://***@example.com/a.git/'"
  """
  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    Regex.replace(~r{([a-z][a-z0-9+.-]*://)[^/\s@'"]+@}i, text, "\\1***@")
  end

  @doc """
  Derives a directory name for a repository URL: readable, unique per URL,
  and free of credentials.

      iex> Deepsplay.RepoUrl.key("https://github.com/example/lobby-screen.git")
      "github.com-example-lobby-screen-70b9789d"
  """
  @spec key(String.t()) :: String.t()
  def key(url) when is_binary(url) do
    hash =
      :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    readable =
      url
      |> redact()
      |> String.replace(~r{^[a-z][a-z0-9+.-]*://}i, "")
      |> String.replace(~r{^.*@}, "")
      |> String.replace_suffix(".git", "")
      |> String.replace(~r/[^A-Za-z0-9._]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 80)

    "#{readable}-#{hash}"
  end

  # `user@host:path`: no scheme, and a colon before the first slash.
  defp scp_like?(url) do
    not String.contains?(url, "://") and
      Regex.match?(~r/^[^\/:@]+@[^\/:]+:.+$/, url)
  end
end
