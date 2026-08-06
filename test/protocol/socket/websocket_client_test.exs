defmodule Amarula.Protocol.Socket.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias Amarula.Protocol.Socket.WebSocketClient

  describe "with_origin_and_agent/3" do
    test "adds Origin and User-Agent when headers carries neither" do
      headers =
        WebSocketClient.with_origin_and_agent([], "https://web.whatsapp.com", "Mozilla/5.0")

      assert {"Origin", "https://web.whatsapp.com"} in headers
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 2
    end

    test "an explicit Origin/User-Agent in headers wins, case-insensitively" do
      headers =
        WebSocketClient.with_origin_and_agent(
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

    test "unrelated caller headers are preserved alongside the computed ones" do
      headers =
        WebSocketClient.with_origin_and_agent(
          [{"X-Custom", "value"}],
          "https://web.whatsapp.com",
          "Mozilla/5.0"
        )

      assert {"X-Custom", "value"} in headers
      assert {"Origin", "https://web.whatsapp.com"} in headers
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert length(headers) == 3
    end
  end
end
