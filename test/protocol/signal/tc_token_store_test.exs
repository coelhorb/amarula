defmodule Amarula.Protocol.Signal.TcTokenStoreTest do
  use ExUnit.Case, async: true

  alias Amarula.Conn
  alias Amarula.Protocol.Signal.{LidMappingFileStore, TcTokenStore}
  alias Amarula.Storage

  @profile :tctoken_test
  @pn "15551234567@s.whatsapp.net"
  @lid "987654321@lid"

  # Mirrors TcTokenStore's own 7-day bucket / 4-bucket window.
  @bucket 604_800

  setup do
    dir = Path.join(System.tmp_dir!(), "amarula_tctoken_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    conn =
      Conn.new(%{
        profile: @profile,
        storage: {Amarula.Storage.File, root: dir}
      })

    :ok =
      LidMappingFileStore.store_mappings(conn, [{@lid, @pn}])
      |> then(fn {_count, _new} -> :ok end)

    {:ok, conn: conn}
  end

  test "finds a token stored under the mapped LID JID for a PN send", %{conn: conn} do
    token = "trusted-contact-token"

    :ok =
      Storage.put(conn.storage, @profile, :tctoken, @lid, %{
        token: token,
        timestamp: System.system_time(:second)
      })

    assert TcTokenStore.valid_token(conn, @pn) == token
  end

  test "a token older than the ~28-day window is not attached", %{conn: conn} do
    put_token(conn, %{token: "stale", timestamp: now() - 4 * @bucket})

    assert TcTokenStore.valid_token(conn, @pn) == nil
  end

  test "a token inside the window is attached", %{conn: conn} do
    put_token(conn, %{token: "fresh", timestamp: now() - 3 * @bucket})

    assert TcTokenStore.valid_token(conn, @pn) == "fresh"
  end

  describe "should_issue_new?/2" do
    test "true when we have never issued for this contact", %{conn: conn} do
      assert TcTokenStore.should_issue_new?(conn, @pn)
    end

    test "false again inside the same 7-day bucket", %{conn: conn} do
      put_token(conn, %{token: "t", timestamp: now(), sender_timestamp: now()})

      refute TcTokenStore.should_issue_new?(conn, @pn)
    end

    test "true once the last issuance falls in an earlier bucket", %{conn: conn} do
      put_token(conn, %{token: "t", timestamp: now(), sender_timestamp: now() - @bucket})

      assert TcTokenStore.should_issue_new?(conn, @pn)
    end
  end

  defp put_token(conn, entry),
    do: :ok = Storage.put(conn.storage, @profile, :tctoken, @lid, entry)

  defp now, do: System.system_time(:second)
end
