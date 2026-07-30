defmodule Amarula.Protocol.Messages.PollCrypto do
  @moduledoc """
  Decrypt poll votes, ported from Baileys `decryptPollVote`
  (`src/Utils/process-message.ts`).

  A vote's `encPayload`/`encIv` are AES-256-GCM encrypted under a key derived from
  the poll's `message_secret` and the ids of the poll, its creator, and the voter:

      sign   = poll_msg_id ++ poll_creator_jid ++ voter_jid ++ "Poll Vote" ++ <<1>>
      key0   = HMAC-SHA256(key=<<0::256>>, data=message_secret)   # key is 32 zero bytes
      dec_key= HMAC-SHA256(key=key0, data=sign)
      aad    = "<poll_msg_id>\\0<voter_jid>"
      plain  = AES-256-GCM-decrypt(encPayload, key=dec_key, iv=encIv, aad)
             → Proto.Message.PollVoteMessage (selectedOptions = SHA-256 option hashes)

  GCM tag is the trailing 16 bytes of `encPayload`.
  """

  alias Amarula.Protocol.Binary.JID
  alias Amarula.Protocol.Proto

  @gcm_tag_len 16

  @type context :: %{
          message_secret: binary(),
          poll_msg_id: String.t(),
          poll_creator_jid: String.t(),
          voter_jid: String.t()
        }

  @doc """
  Decrypt a poll vote (`enc` = `%Proto.Message.PollEncValue{}` or a map with
  `:encPayload`/`:encIv`). Returns `{:ok, %PollVoteMessage{}}` (its
  `selectedOptions` are SHA-256 hashes of the chosen option names — match against
  `Poll.tally/3`), or `{:error, reason}`.

  > #### Jid forms must match the sender's {: .warning}
  >
  > The key is derived from `poll_creator_jid` and `voter_jid`, so they must match
  > **the identities the voter keyed on**. Device and agent segments are stripped
  > for you (see below), but the **PN/LID choice is not** — it can't be: they are
  > different identities, not different spellings of one. In a **LID group** the
  > voter keys on their **LID** (the `participant` on the vote message), not their
  > PN; passing the PN (or vice-versa) derives the wrong key and decryption fails
  > (`{:error, :decrypt_failed}`) — the root of Baileys #2158. Use the author jid as
  > it appears on the vote's `key.participant` (resolve LID↔PN with
  > `Amarula.Contacts.pn_for_lid/2` only if you need to *compare* identities — not
  > to build this context).

  > #### Identities are normalized to account level {: .info}
  >
  > `poll_creator_jid` and `voter_jid` are reduced to their account-level form
  > (device and agent stripped) before deriving the key, on **both** this and
  > `encrypt_vote/2` — matching Baileys' `jidNormalizedUser`, which it applies to
  > every identity feeding `decryptPollVote`. A device-bearing jid would otherwise
  > derive a key nobody else can reproduce: `Amarula.own_address/1` carries this
  > companion's device, so votes encrypted with it silently never counted (#48).
  """
  @spec decrypt_vote(map(), context()) :: {:ok, struct()} | {:error, term()}
  def decrypt_vote(%{encPayload: payload, encIv: iv}, ctx)
      when is_binary(payload) and is_binary(iv) do
    ctx = normalize_ctx(ctx)
    dec_key = vote_key(ctx)
    aad = "#{ctx.poll_msg_id}\0#{ctx.voter_jid}"

    ct_len = byte_size(payload) - @gcm_tag_len
    <<ciphertext::binary-size(^ct_len), tag::binary-size(@gcm_tag_len)>> = payload

    case :crypto.crypto_one_time_aead(:aes_256_gcm, dec_key, iv, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) ->
        {:ok, Proto.Message.PollVoteMessage.decode(plaintext)}

      :error ->
        {:error, :decrypt_failed}
    end
  rescue
    e -> {:error, e}
  end

  def decrypt_vote(_enc, _ctx), do: {:error, :no_payload}

  @doc """
  Encrypt a poll vote — the inverse of `decrypt_vote/2`. `selected_option_hashes`
  is the list of `sha256(option_name)` for the options being voted for. Returns
  `%Proto.Message.PollEncValue{encPayload: ct<>tag, encIv: iv}` ready to wrap in a
  `pollUpdateMessage`. Uses the same key derivation + AAD as the receive side —
  including the account-level normalization described on `decrypt_vote/2` — so a
  vote we send is reproducible by any recipient, not just by us.
  """
  @spec encrypt_vote([binary()], context()) :: Proto.Message.PollEncValue.t()
  def encrypt_vote(selected_option_hashes, ctx) when is_list(selected_option_hashes) do
    ctx = normalize_ctx(ctx)
    dec_key = vote_key(ctx)
    aad = "#{ctx.poll_msg_id}\0#{ctx.voter_jid}"
    iv = :crypto.strong_rand_bytes(12)

    plaintext =
      Proto.Message.PollVoteMessage.encode(%Proto.Message.PollVoteMessage{
        selectedOptions: selected_option_hashes
      })

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, dec_key, iv, plaintext, aad, @gcm_tag_len, true)

    %Proto.Message.PollEncValue{encPayload: ciphertext <> tag, encIv: iv}
  end

  # Reduce both identities to account level, so a device-bearing jid on either side
  # can't desync the sender's key from the recipient's. Applied symmetrically to
  # encrypt and decrypt — the whole point is that both ends derive the same thing.
  #
  # Baileys does the same on its (decrypt-only) side: every identity reaching
  # `decryptPollVote` comes from `jidNormalizedUser(meId)` or a `getKeyAuthor` value
  # already normalized at decode. It has NO vote-sending path, so there is no
  # upstream encrypt side to mirror — this is the form recipients reproduce.
  #
  # PN vs LID is deliberately NOT touched: those are two distinct identities for one
  # person, not two spellings, so picking between them needs the chat's addressing
  # mode and belongs to the caller (see the warning on `decrypt_vote/2`).
  defp normalize_ctx(ctx) do
    %{
      ctx
      | poll_creator_jid: account_jid(ctx.poll_creator_jid),
        voter_jid: account_jid(ctx.voter_jid)
    }
  end

  # `jid_normalized_user/1` yields "" for a jid it can't decode; a silently blank
  # identity would derive a plausible-looking but wrong key, so keep the original and
  # let the mismatch be the caller's visible input error instead.
  defp account_jid(jid) when is_binary(jid) do
    case JID.jid_normalized_user(jid) do
      "" -> jid
      normalized -> normalized
    end
  end

  # HMAC chain. Baileys `hmacSign(buffer, key)` = HMAC(key, buffer), so:
  #   key0   = HMAC(key=<32 zero bytes>, data=message_secret)
  #   decKey = HMAC(key=key0, data=sign)
  defp vote_key(ctx) do
    sign = ctx.poll_msg_id <> ctx.poll_creator_jid <> ctx.voter_jid <> "Poll Vote" <> <<1>>
    key0 = :crypto.mac(:hmac, :sha256, <<0::256>>, ctx.message_secret)
    :crypto.mac(:hmac, :sha256, key0, sign)
  end
end
