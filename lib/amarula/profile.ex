defmodule Amarula.Profile do
  @moduledoc """
  Profile reads and writes: fetch a profile-picture URL, set/remove your (or a
  group's) picture, and set your status/bio. The consumer-facing half of Baileys'
  `profilePictureUrl` / `updateProfilePicture` / `removeProfilePicture` /
  `updateProfileStatus`.

  Each function builds an IQ via `Amarula.Protocol.Profile.Ops`, sends it through
  `Amarula.Connection.query_iq/3`, and parses the reply. Call them on this module:
  `picture_url/3`, `update_picture/3`, `remove_picture/2`, `update_status/2`.

  > #### Picture URL privacy token {: .info}
  > WhatsApp requires a per-contact privacy token (`tctoken`) to show you *another*
  > user's picture. `picture_url/3` attaches one automatically when we hold it —
  > never for your own account (with a token attached the server simply never
  > replies) and never for a group. With no token held the query still goes out
  > unadorned, so a contact you have not yet exchanged trust with can still return
  > `nil`; see `Amarula.Protocol.Signal.TcTokenStore` for how tokens are earned.
  """

  alias Amarula.Address
  alias Amarula.Connection
  alias Amarula.Protocol.Binary.JID
  alias Amarula.Protocol.Profile.Ops
  alias Amarula.Protocol.Signal.TcTokenStore

  @type conn :: GenServer.server()

  @doc """
  Fetch the profile-picture URL for `jid` (a user or group). `type` is `:preview`
  (small, default) or `:image` (full). Returns `{:ok, url}`, `{:ok, nil}` when there
  is no picture (or it is not visible to you), or `{:error, reason}`.

  A held trusted-contact token is attached automatically — see the module note.
  """
  @spec picture_url(conn(), String.t() | Address.t(), Ops.pic_type()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def picture_url(conn, jid, type \\ :preview) do
    addr = Address.parse!(jid)
    target = Address.to_jid!(addr)
    query = Ops.picture_url_query(target, type, picture_tctoken(conn, addr, target))

    with {:ok, reply} <- Connection.query_iq(conn, query) do
      {:ok, Ops.parse_url(reply)}
    end
  end

  # Baileys gates the picture tctoken on "user jid, and not ourselves"
  # (`Socket/chats.ts` `profilePictureUrl`). The self case is not an optimization:
  # WA Web has no tcToken for your own chat, and sending one makes the server
  # never answer the IQ at all — the caller would just time out.
  #
  # The cheap jid check comes first so a group lookup costs no extra round-trip
  # to the connection process (both helpers below are GenServer calls).
  defp picture_tctoken(conn, %Address{} = addr, target) do
    if JID.jid_user?(target) and not own_account?(conn, addr) do
      conn |> Connection.get_conn() |> TcTokenStore.token_children(target)
    else
      []
    end
  end

  @doc """
  Set your own profile picture (or a group's, if `jid` is a group you administer)
  from already-encoded JPEG bytes. WhatsApp expects a small square JPEG; the caller
  must size it (Amarula does not resize — see the module note). Returns `:ok` or
  `{:error, reason}`.
  """
  @spec update_picture(conn(), String.t() | Address.t(), binary()) :: :ok | {:error, term()}
  def update_picture(conn, jid, jpeg_bytes) do
    target = target_for(conn, jid)

    with {:ok, _reply} <- Connection.query_iq(conn, Ops.set_picture(target, jpeg_bytes)), do: :ok
  end

  @doc "Remove your own (or a group's) profile picture. Returns `:ok` or `{:error, reason}`."
  @spec remove_picture(conn(), String.t() | Address.t()) :: :ok | {:error, term()}
  def remove_picture(conn, jid) do
    target = target_for(conn, jid)

    with {:ok, _reply} <- Connection.query_iq(conn, Ops.remove_picture(target)), do: :ok
  end

  @doc "Set your own profile status/bio text. Returns `:ok` or `{:error, reason}`."
  @spec update_status(conn(), String.t()) :: :ok | {:error, term()}
  def update_status(conn, status) when is_binary(status) do
    with {:ok, _reply} <- Connection.query_iq(conn, Ops.set_status(status)), do: :ok
  end

  # Resolve the `target` attr for a picture write: `nil` when `jid` is our own
  # account (Baileys omits target for self), else the wire jid. Falls back to the
  # wire jid if creds aren't available yet (e.g. not logged in).
  defp target_for(conn, jid) do
    addr = Address.parse!(jid)
    if own_account?(conn, addr), do: nil, else: Address.to_jid!(addr)
  end

  # `get_auth_creds` returns a map; `me` defaults to `%{}` before login, so no
  # address matches and we fall back to a targeted IQ — no special-casing needed.
  defp own_account?(conn, %Address{} = addr) do
    me = conn |> Connection.get_auth_creds() |> Map.get(:me, %{})

    [Map.get(me, :id), Map.get(me, :lid)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Address.parse/1)
    |> Enum.any?(fn mine -> mine && Address.same_account?(mine, addr) end)
  end
end
