defmodule Amarula.Protocol.Socket.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias Amarula.Protocol.Socket.WebSocketClient

  describe "build_headers/3" do
    test "adds Origin and User-Agent when headers carries neither" do
      headers = WebSocketClient.build_headers([], "https://web.whatsapp.com", "Mozilla/5.0")

      assert {"Origin", "https://web.whatsapp.com"} in headers
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 2
    end

    test "accepts headers given as a map" do
      headers =
        WebSocketClient.build_headers(
          %{"X-Custom" => "1"},
          "https://web.whatsapp.com",
          "Mozilla/5.0"
        )

      assert {"X-Custom", "1"} in headers
      assert {"Origin", "https://web.whatsapp.com"} in headers
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 3
    end

    test "an explicit Origin/User-Agent in headers wins, case-insensitively" do
      headers =
        WebSocketClient.build_headers(
          [{"origin", "https://custom.example.com"}, {"user-agent", "CustomAgent/1.0"}],
          "https://web.whatsapp.com",
          "Mozilla/5.0"
        )

      assert {"origin", "https://custom.example.com"} in headers
      assert {"user-agent", "CustomAgent/1.0"} in headers
      refute {"Origin", "https://web.whatsapp.com"} in headers
      refute {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 2
    end

    test "matches an atom header key case-insensitively too" do
      headers =
        WebSocketClient.build_headers(
          [{:"User-Agent", "CustomAgent/1.0"}],
          "https://web.whatsapp.com",
          "Mozilla/5.0"
        )

      assert {:"User-Agent", "CustomAgent/1.0"} in headers
      refute {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 2
    end

    test "unrelated caller headers are preserved alongside the computed ones" do
      headers =
        WebSocketClient.build_headers(
          [{"X-Custom", "value"}],
          "https://web.whatsapp.com",
          "Mozilla/5.0"
        )

      assert {"X-Custom", "value"} in headers
      assert {"Origin", "https://web.whatsapp.com"} in headers
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 3
    end

    test "tolerates a malformed headers value" do
      assert [{"Origin", _}, {"User-Agent", _}] =
               WebSocketClient.build_headers(:garbage, "https://web.whatsapp.com", "Mozilla/5.0")
    end
  end
end
