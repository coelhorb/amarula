defmodule Amarula.Protocol.Signal.TcTokenStoreTest do
  use ExUnit.Case, async: true

  alias Amarula.Conn
  alias Amarula.Protocol.Signal.{LidMappingFileStore, TcTokenStore}
  alias Amarula.Storage

  @profile :tctoken_test
  @pn "15551234567@s.whatsapp.net"
  @lid "987654321@lid"

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

  test "migrates a legacy bare-LID token key", %{conn: conn} do
    token = "legacy-trusted-contact-token"

    :ok =
      Storage.put(conn.storage, @profile, :tctoken, "987654321", %{
        token: token,
        timestamp: System.system_time(:second)
      })

    assert TcTokenStore.valid_token(conn, @pn) == token

    assert %{token: ^token} = Storage.fetch(conn.storage, @profile, :tctoken, @lid)
  end
end
