# Fallback for `mix assets.setup` in the image build (see docs/deployment.md,
# "Releasing"): downloads the Tailwind executable through the GitHub API
# instead of github.com/.../releases/download/..., which has failed with
# "504 Gateway Time-out" while the API kept working.
#
# Run with `mix run --no-compile --no-start docker/fetch_tailwind.exs`. It
# puts the executable where the tailwind package expects it, so a following
# `tailwind.install --if-missing` skips the download. A GitHub token in
# /run/secrets/github_token (a build secret) avoids the API's rate limit for
# anonymous requests.

{:ok, _apps} = Application.ensure_all_started(:req)

version = Tailwind.configured_version()
asset = "tailwindcss-" <> Tailwind.configured_target()
bin_path = Tailwind.bin_path()

auth =
  case File.read("/run/secrets/github_token") do
    {:ok, token} when byte_size(token) > 0 -> [auth: {:bearer, String.trim(token)}]
    _none -> []
  end

api = "https://api.github.com/repos/tailwindlabs/tailwindcss"

release =
  Req.get!("#{api}/releases/tags/v#{version}", auth ++ [retry: :transient, http_errors: :raise]).body

url =
  case Enum.find(release["assets"] || [], &(&1["name"] == asset)) do
    %{"url" => url} -> url
    nil -> raise "Tailwind #{version} has no asset #{asset}"
  end

binary =
  Req.get!(
    url,
    auth ++
      [
        headers: [accept: "application/octet-stream"],
        retry: :transient,
        receive_timeout: 120_000,
        redirect_log_level: false,
        http_errors: :raise
      ]
  ).body

File.mkdir_p!(Path.dirname(bin_path))
File.write!(bin_path, binary)
File.chmod!(bin_path, 0o755)
IO.puts("Tailwind #{version} (#{asset}) fetched through the GitHub API to #{bin_path}")
