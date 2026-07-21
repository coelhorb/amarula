defmodule Amarula.Protocol.Signal.TcTokenStore do
  @moduledoc """
  Trusted-contact privacy token ("tctoken") store, ported from Baileys
  `Utils/tc-token-utils.ts` + the tctoken branches of `Socket/messages-send.ts`
  and `Socket/messages-recv.ts`.

  ## Why this exists

  WhatsApp gates a device's first messages to a contact behind a "trusted
  contact" token exchange — an anti-spam measure. Sending 1:1 without a token
  the recipient trusts gets the message accepted by the socket but rejected at
  the application layer with ack error **463** (`MessageAccountRestriction`):
  the frame goes out, the send looks like it "succeeded" up to that point, but
  no message is ever delivered. This is invisible unless the consumer inspects
  `send_text/3`'s `{:error, {:send_rejected, "463"}}` result.

  The fix has two halves, both driven from `ConversationSender` (attach) and
  `Amarula.Connection` (issue/recover) for 1:1 sends only — never groups:

    1. **Attach**: if we hold a valid (unexpired) token *for the recipient*
       (i.e. proof they've trusted us before), attach it to the outgoing
       `<message>` as a `<tctoken>` child.
    2. **Issue**: after a 1:1 send (success or 463), fire-and-forget an
       `issuePrivacyTokens` IQ that asks the server to vouch for us to that
       contact, and store whatever token(s) come back in the reply so a *future*
       send has one to attach. This never blocks or retries the message itself —
       retrying a 463'd send only compounds the restriction (see Baileys'
       `handleBadAck` comment).

  ## Expiry / reissue windows

  Tokens live in 7-day buckets; a token is expired once its bucket falls
  outside the last ~28 days (`TC_TOKEN_NUM_BUCKETS` buckets). We also track our
  own last-issued bucket (`sender_timestamp`) so we don't re-issue every single
  send — only once per bucket per contact (`should_issue_new?/2`).

  ## Storage

  One entry per contact under the `:tctoken` namespace (see `Amarula.Storage`),
  keyed by the *storage jid* — LID-resolved, matching how Signal sessions are
  keyed (`LidMappingFileStore.signal_address/2`), since WA Web stores tctoken
  state under the LID identity. Each entry is
  `%{token: binary(), timestamp: integer(), sender_timestamp: integer() | nil}`
  — `token`/`timestamp` are the peer's token *we hold*; `sender_timestamp` is
  purely local bookkeeping for the reissue dedupe.

  ## Simplifications vs. Baileys

  Baileys reads two AB test props from the server (`privacyTokenOn1to1`,
  `lidTrustedTokenIssueToLid`) via an `abt`/`props` IQ, each defaulting `true`
  and `false` respectively. Fetching + tracking those props is out of scope
  here — we use the documented defaults unconditionally (send-gate always on,
  issue-to-LID always off), which is the common case and what every account
  runs unless explicitly A/B-flighted otherwise.
  """

  alias Amarula.Conn
  alias Amarula.Protocol.Binary.{JID, Node, NodeUtils}
  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Amarula.Storage

  # 7-day buckets, ~28-day rolling window — mirrors Baileys' tc-token-utils.ts.
  @bucket_seconds 604_800
  @num_buckets 4

  @doc """
  The (unexpired) token bytes we hold for `jid`, or `nil` if we have none, it
  expired, or storage errors — any of which just means "don't attach", not a
  hard failure.
  """
  @spec valid_token(Conn.t(), String.t()) :: binary() | nil
  def valid_token(conn, jid) do
    case read(conn, storage_jid(conn, jid)) do
      %{token: token, timestamp: ts} when is_binary(token) and byte_size(token) > 0 ->
        if expired?(ts), do: nil, else: token

      _ ->
        nil
    end
  end

  @doc """
  True if we should fire a new `issuePrivacyTokens` for `jid` — we've never
  issued one, or the last issuance fell in an earlier bucket than the current
  one. Bucket-based, so a burst of sends to the same contact issues at most
  once per ~7 days.
  """
  @spec should_issue_new?(Conn.t(), String.t()) :: boolean()
  def should_issue_new?(conn, jid) do
    case read(conn, storage_jid(conn, jid)) do
      %{sender_timestamp: ts} when is_integer(ts) -> bucket(now()) > bucket(ts)
      _ -> true
    end
  end

  @doc """
  Build the `issuePrivacyTokens` IQ (Baileys `Socket/messages-send.ts`
  `issuePrivacyTokens`): `<iq to=s.whatsapp.net type=set xmlns=privacy>
  <tokens><token jid=.. t=.. type=trusted_contact/></tokens></iq>`.
  """
  @spec build_issue_iq(String.t(), integer()) :: Node.t()
  def build_issue_iq(jid, timestamp) do
    token =
      Node.create("token", %{
        "jid" => JID.jid_normalized_user(jid),
        "t" => Integer.to_string(timestamp),
        "type" => "trusted_contact"
      })

    Node.create(
      "iq",
      %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "privacy"},
      [Node.create("tokens", %{}, [token])]
    )
  end

  @doc """
  Store any `trusted_contact` tokens carried in an `issuePrivacyTokens` IQ
  result (`<tokens><token type=trusted_contact jid=.. t=..>bytes</token>...`),
  then record `sender_timestamp` for `issued_jid` so `should_issue_new?/2`
  dedupes future issuance — ported from Baileys' `storeTcTokensFromIqResult`
  plus the `.then()` bookkeeping in `messages-send.ts`. Best-effort: storage
  failures are logged, never raised (this always runs off the send's critical
  path).

  In practice the IQ result is often empty — the peer's actual token for us
  typically arrives later as its own `<notification type="privacy_token">`
  (see `store_notification/3`), not synchronously in this reply. Both paths
  funnel through the same token-parsing logic; only the bookkeeping differs.
  """
  @spec store_result(Conn.t(), Node.t() | nil, String.t(), integer()) :: :ok
  def store_result(conn, result_node, issued_jid, issued_at) do
    store_tokens(conn, result_node, issued_jid)
    record_issued(conn, issued_jid, issued_at)
    :ok
  end

  @doc """
  Store token(s) carried in an incoming `<notification type="privacy_token">`
  — ported from Baileys' `handlePrivacyTokenNotification`. This is the actual
  channel a peer's trusted-contact token for us arrives on. `fallback_jid`
  (the notification's `from`, or `sender_lid` when present) is used in place
  of the token node's own `jid` attr, which in a notification is *our own*
  device jid, not the sender's (mirrors Baileys' `fallbackJid || tokenNode.attrs.jid`
  precedence). Unlike `store_result/4`, this never touches `sender_timestamp`
  bookkeeping — it's someone else's token arriving, not proof we issued one.
  """
  @spec store_notification(Conn.t(), Node.t(), String.t()) :: :ok
  def store_notification(conn, node, fallback_jid) do
    store_tokens(conn, node, fallback_jid)
    :ok
  end

  defp store_tokens(_conn, nil, _fallback_jid), do: :ok

  defp store_tokens(conn, result_node, fallback_jid) do
    case NodeUtils.get_binary_node_child(result_node, "tokens") do
      nil ->
        :ok

      tokens_node ->
        tokens_node
        |> NodeUtils.get_binary_node_children("token")
        |> Enum.each(&store_token(conn, &1, fallback_jid))
    end
  end

  defp store_token(conn, %Node{attrs: attrs, content: content}, fallback_jid)
       when is_binary(content) do
    with "trusted_contact" <- Map.get(attrs, "type"),
         t when is_binary(t) <- Map.get(attrs, "t"),
         {ts, ""} <- Integer.parse(t),
         raw_jid when is_binary(raw_jid) <- fallback_jid || Map.get(attrs, "jid") do
      key = storage_jid(conn, raw_jid)
      existing = read(conn, key)

      # Never let a stale reply clobber a newer token for the same contact.
      unless is_map(existing) and Map.get(existing, :timestamp, 0) > ts do
        write(conn, key, Map.merge(existing || %{}, %{token: content, timestamp: ts}))
      end
    else
      _ -> :ok
    end
  end

  defp store_token(_conn, _token_node, _fallback_jid), do: :ok

  defp record_issued(conn, jid, issued_at) do
    key = storage_jid(conn, jid)
    existing = read(conn, key) || %{}
    write(conn, key, Map.put(existing, :sender_timestamp, issued_at))
  end

  # --- expiry / bucketing (mirrors tc-token-utils.ts) ---

  defp expired?(ts) when is_integer(ts), do: bucket(now()) - bucket(ts) >= @num_buckets
  defp expired?(_ts), do: true

  defp bucket(unix_ts), do: div(unix_ts, @bucket_seconds)

  defp now, do: System.system_time(:second)

  # --- storage (mirrors LidMappingFileStore's read/write pattern) ---

  # WA Web stores tctoken state under the account-level LID JID when one is
  # known, exactly like Signal sessions (LidMappingFileStore.signal_address/2).
  # Keep the server suffix: notification tokens arrive keyed by `@lid`, and
  # dropping it here made PN sends look under a different storage key.
  defp storage_jid(conn, jid) do
    user = JID.jid_normalized_user(jid)

    cond do
      JID.lid_user?(user) ->
        user

      lid_user = LidMappingFileStore.lid_for_pn(conn, user) ->
        JID.encode(%{user: lid_user, server: "lid"})

      true ->
        user
    end
  end

  defp read(%Conn{storage: scope, profile: profile}, key),
    do: read(scope, profile, key)

  defp read(scope, profile, key) do
    case Storage.fetch(scope, profile, :tctoken, key) do
      nil ->
        migrate_legacy_key(scope, profile, key)

      entry ->
        entry
    end
  end

  # Earlier versions resolved PN targets to a bare LID user (for example
  # `12345`) while notification handling stored the same contact under
  # `12345@lid`. Preserve any bare-LID entry on upgrade, then copy it to the
  # canonical JID key so later reads are consistent.
  defp migrate_legacy_key(scope, profile, key) do
    case JID.decode(key) do
      %{user: user, server: "lid"} ->
        case Storage.fetch(scope, profile, :tctoken, user) do
          nil ->
            nil

          entry ->
            :ok = Storage.put(scope, profile, :tctoken, key, entry)
            entry
        end

      _ ->
        nil
    end
  end

  defp write(%Conn{storage: scope, profile: profile}, key, value),
    do: Storage.put(scope, profile, :tctoken, key, value)
end
