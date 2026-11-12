defmodule DeepsplayWeb.TrustedProxiesTest do
  # Not async: the endpoint test sets the global ranges.
  use DeepsplayWeb.ConnCase, async: false

  alias DeepsplayWeb.TrustedProxies

  doctest TrustedProxies

  @proxy [{{10, 0, 0, 2}, 32}]

  # A request as Caddy forwards it: to port 4000 over HTTP, with the host the
  # browser used.
  defp forwarded(headers, remote_ip \\ {10, 0, 0, 2}) do
    conn = Plug.Test.conn(:get, "http://display.example.org:4000/live/websocket")

    Enum.reduce(headers, %{conn | remote_ip: remote_ip}, fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  describe "parse/1" do
    test "CIDR ranges, IPv6 and empty entries" do
      assert TrustedProxies.parse(" 172.16.0.0/12 ,, fd00::/8 ,") ==
               {:ok, [{{172, 16, 0, 0}, 12}, {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}]}

      assert TrustedProxies.parse("") == {:ok, []}
    end

    test "invalid entries" do
      for entry <- ["proxy.lan", "10.0.0.0/33", "::1/129", "10.0.0.0/x", "10.0.0/8"] do
        assert {:error, message} = TrustedProxies.parse("10.0.0.1, #{entry}")
        assert message =~ ~s("#{entry}")
      end
    end

    test "setup!/1 raises on an invalid value" do
      assert_raise ArgumentError, ~r/DEEPSPLAY_TRUSTED_PROXIES/, fn ->
        TrustedProxies.setup!("nope")
      end
    end
  end

  describe "rewrite/2" do
    test "takes scheme and default port from a trusted proxy" do
      conn = TrustedProxies.rewrite(forwarded([{"x-forwarded-proto", "https"}]), @proxy)
      assert {conn.scheme, conn.host, conn.port} == {:https, "display.example.org", 443}
    end

    test "never takes the port, which Caddy passes on from its clients" do
      conn =
        forwarded([{"x-forwarded-proto", "https"}, {"x-forwarded-port", "8443"}])
        |> TrustedProxies.rewrite(@proxy)

      assert {conn.scheme, conn.port} == {:https, 443}

      conn = TrustedProxies.rewrite(forwarded([{"x-forwarded-proto", "http"}]), @proxy)
      assert {conn.scheme, conn.port} == {:http, 80}
    end

    test "ignores the headers of anyone else" do
      conn = forwarded([{"x-forwarded-proto", "https"}], {10, 0, 0, 3})
      assert TrustedProxies.rewrite(conn, @proxy) == conn

      conn = forwarded([{"x-forwarded-proto", "https"}])
      assert TrustedProxies.rewrite(conn, []) == conn
    end

    test "never takes the host" do
      conn =
        forwarded([{"x-forwarded-proto", "https"}, {"x-forwarded-host", "evil.example"}])
        |> TrustedProxies.rewrite(@proxy)

      assert conn.host == "display.example.org"
    end

    test "leaves the request alone on missing, repeated or invalid headers" do
      for headers <- [
            [],
            [{"x-forwarded-proto", "ftp"}],
            [{"x-forwarded-proto", "https, http"}]
          ] do
        conn = forwarded(headers)
        assert TrustedProxies.rewrite(conn, @proxy) == conn
      end

      conn =
        forwarded([])
        |> Map.update!(:req_headers, &[{"x-forwarded-proto", "https"} | &1])
        |> Map.update!(:req_headers, &[{"x-forwarded-proto", "http"} | &1])

      assert TrustedProxies.rewrite(conn, @proxy) == conn
    end
  end

  describe "with the origin check of the LiveView socket" do
    # Phoenix logs each refused origin.
    @describetag :capture_log

    # A handler of its own: Phoenix caches the check_origin setting per handler.
    defp check(conn),
      do:
        Phoenix.Socket.Transport.check_origin(conn, __MODULE__, DeepsplayWeb.Endpoint,
          check_origin: :conn
        )

    test "a browser on https behind the proxy passes only with the rewrite" do
      conn =
        forwarded([{"x-forwarded-proto", "https"}, {"origin", "https://display.example.org"}])

      assert %{status: 403, halted: true} = check(conn)
      refute check(TrustedProxies.rewrite(conn, @proxy)).halted
    end

    test "another site still fails after the rewrite" do
      conn =
        forwarded([{"x-forwarded-proto", "https"}, {"origin", "https://evil.example"}])
        |> TrustedProxies.rewrite(@proxy)

      assert %{status: 403} = check(conn)
    end
  end

  describe "in the endpoint" do
    setup do
      previous = TrustedProxies.ranges()
      on_exit(fn -> :persistent_term.put({TrustedProxies, :proxies}, previous) end)
    end

    test "requests are rewritten before anything else sees them", %{conn: conn} do
      conn = put_req_header(conn, "x-forwarded-proto", "https")

      TrustedProxies.setup!(nil)
      assert get(conn, ~p"/status").scheme == :http

      # Test requests come from 127.0.0.1.
      TrustedProxies.setup!("127.0.0.1")
      assert %{scheme: :https, port: 443} = get(conn, ~p"/status")
    end
  end
end
