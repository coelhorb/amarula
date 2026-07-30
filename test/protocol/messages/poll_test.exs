defmodule Amarula.Protocol.Messages.PollTest do
  use ExUnit.Case, async: true

  alias Amarula.Protocol.Messages.{MessageEncoder, Poll, PollCrypto}
  alias Amarula.Protocol.Proto

  describe "MessageEncoder.poll/3" do
    test "single-select → v3, sets a 32-byte secret" do
      {msg, secret} = MessageEncoder.poll("Lunch?", ["Pizza", "Sushi"])
      assert byte_size(secret) == 32

      assert %Proto.Message.PollCreationMessage{name: "Lunch?", selectableOptionsCount: 1} =
               msg.pollCreationMessageV3

      assert Enum.map(msg.pollCreationMessageV3.options, & &1.optionName) == ["Pizza", "Sushi"]
      assert msg.messageContextInfo.messageSecret == secret
    end

    test "multi-select → v1" do
      {msg, _} = MessageEncoder.poll("Pick", ["A", "B", "C"], selectable: 2)
      assert msg.pollCreationMessage
      refute msg.pollCreationMessageV3
    end

    test "announcement → v2" do
      {msg, _} = MessageEncoder.poll("Q", ["A"], announcement: true)
      assert msg.pollCreationMessageV2
    end

    test "honors a provided secret" do
      s = :crypto.strong_rand_bytes(32)
      {_msg, secret} = MessageEncoder.poll("Q", ["A"], message_secret: s)
      assert secret == s
    end

    test "rejects out-of-range selectable" do
      assert_raise ArgumentError, fn -> MessageEncoder.poll("Q", ["A", "B"], selectable: 5) end
    end
  end

  describe "vote decrypt + tally (round-trip)" do
    test "decrypts a vote encrypted with the poll secret and tallies it" do
      {poll_msg, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      poll_id = "POLL123"
      creator = "10000000001@s.whatsapp.net"
      voter = "10000000009@s.whatsapp.net"

      # The voter selected "Dogs" → its SHA-256 hash.
      dogs_hash = :crypto.hash(:sha256, "Dogs")
      vote = %Proto.Message.PollVoteMessage{selectedOptions: [dogs_hash]}
      plaintext = Proto.Message.PollVoteMessage.encode(vote)

      enc = encrypt_vote(plaintext, secret, poll_id, creator, voter)

      ctx = %{
        message_secret: secret,
        poll_msg_id: poll_id,
        poll_creator_jid: creator,
        voter_jid: voter
      }

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx)
      assert decoded.selectedOptions == [dogs_hash]

      tally = Poll.tally(poll_msg, [{voter, decoded}])
      assert [%{name: "Cats", voters: []}, %{name: "Dogs", voters: [^voter]}] = tally
    end

    test "bad secret → decrypt error" do
      {_poll, secret} = MessageEncoder.poll("Q", ["A"], selectable: 1)
      enc = encrypt_vote("x", secret, "ID", "c@s", "v@s")

      ctx = %{
        message_secret: :crypto.strong_rand_bytes(32),
        poll_msg_id: "ID",
        poll_creator_jid: "c@s",
        voter_jid: "v@s"
      }

      assert {:error, _} = PollCrypto.decrypt_vote(enc, ctx)
    end
  end

  describe "vote identities are account-level (#48)" do
    # The existing round-trips above encrypt and decrypt with the SAME jid strings,
    # so they pass for any consistent pair — correct or not. These derive the
    # recipient's side independently, the way a real peer does: a recipient never
    # sees our device, so it keys on the account-level jid (Baileys derives every
    # poll identity through `jidNormalizedUser`).
    @poll_id "POLL123"
    @creator "10000000001@s.whatsapp.net"
    @voter_account "10000000009@s.whatsapp.net"
    # `Amarula.own_address/1` carries THIS companion's device — the form that was
    # reaching the key derivation.
    @voter_device "10000000009:29@s.whatsapp.net"

    defp ctx(secret, creator, voter) do
      %{
        message_secret: secret,
        poll_msg_id: @poll_id,
        poll_creator_jid: creator,
        voter_jid: voter
      }
    end

    defp vote_for(secret, creator, voter, option) do
      hash = :crypto.hash(:sha256, option)
      {PollCrypto.encrypt_vote([hash], ctx(secret, creator, voter)), hash}
    end

    test "a vote encrypted with our device-bearing jid is readable by a recipient" do
      # THE REGRESSION. Encrypt as the sender does (device-bearing `own_address`),
      # decrypt as a recipient does (account-level). These must agree.
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      {enc, dogs} = vote_for(secret, @creator, @voter_device, "Dogs")

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, @voter_account))
      assert decoded.selectedOptions == [dogs]
    end

    test "and the reverse: a peer's account-level vote is readable if we hold a device form" do
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      {enc, dogs} = vote_for(secret, @creator, @voter_account, "Dogs")

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, @voter_device))
      assert decoded.selectedOptions == [dogs]
    end

    test "a device-bearing creator is normalized too (both identities key the vote)" do
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      creator_device = "10000000001:7@s.whatsapp.net"
      {enc, dogs} = vote_for(secret, creator_device, @voter_account, "Dogs")

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, @voter_account))
      assert decoded.selectedOptions == [dogs]
    end

    test "an agent segment is stripped as well" do
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      {enc, dogs} = vote_for(secret, @creator, "10000000009_1@s.whatsapp.net", "Dogs")

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, @voter_account))
      assert decoded.selectedOptions == [dogs]
    end

    test "the whole path: MessageEncoder.poll_vote/5 with a device-bearing voter" do
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      poll_key = %Proto.MessageKey{remoteJid: "g@g.us", id: @poll_id, fromMe: false}

      message = MessageEncoder.poll_vote(poll_key, @creator, @voter_device, secret, ["Dogs"])

      assert {:ok, decoded} =
               PollCrypto.decrypt_vote(
                 message.pollUpdateMessage.vote,
                 ctx(secret, @creator, @voter_account)
               )

      assert decoded.selectedOptions == [:crypto.hash(:sha256, "Dogs")]
    end

    test "PN and LID stay distinct — normalization must not conflate identities" do
      # Device/agent are spellings of one identity; PN vs LID are two identities.
      # Stripping must not accidentally make these interchangeable.
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      {enc, _} = vote_for(secret, @creator, "10000000009@lid", "Dogs")

      assert {:error, _} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, @voter_account))
    end

    test "an undecodable jid is kept as-is rather than blanked" do
      # "" would derive a plausible-but-wrong key on both sides and silently agree,
      # hiding a caller's bad input. Keeping the original keeps the mismatch visible.
      {_poll, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      {enc, dogs} = vote_for(secret, @creator, "not-a-jid", "Dogs")

      assert {:ok, decoded} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, "not-a-jid"))
      assert decoded.selectedOptions == [dogs]
      assert {:error, _} = PollCrypto.decrypt_vote(enc, ctx(secret, @creator, ""))
    end
  end

  describe "MessageEncoder.poll_vote/5 (send a vote)" do
    test "builds a pollUpdateMessage whose vote our own decrypt + tally recovers" do
      {poll_msg, secret} = MessageEncoder.poll("Best?", ["Cats", "Dogs"], selectable: 1)
      poll_key = %Proto.MessageKey{remoteJid: "g@g.us", id: "POLL123", fromMe: true}
      creator = "10000000001@s.whatsapp.net"
      voter = "10000000009@s.whatsapp.net"

      message = MessageEncoder.poll_vote(poll_key, creator, voter, secret, ["Dogs"])

      update = message.pollUpdateMessage
      assert update.pollCreationMessageKey == poll_key
      assert is_integer(update.senderTimestampMs)

      # Decrypt the vote we just built with the production receive path.
      ctx = %{
        message_secret: secret,
        poll_msg_id: poll_key.id,
        poll_creator_jid: creator,
        voter_jid: voter
      }

      assert {:ok, decoded} = PollCrypto.decrypt_vote(update.vote, ctx)
      assert decoded.selectedOptions == [Poll.option_hash("Dogs")]

      tally = Poll.tally(poll_msg, [{voter, decoded}])
      assert [%{name: "Cats", voters: []}, %{name: "Dogs", voters: [^voter]}] = tally
    end

    test "encrypt_vote round-trips multiple selections" do
      secret = :crypto.strong_rand_bytes(32)

      ctx = %{
        message_secret: secret,
        poll_msg_id: "ID",
        poll_creator_jid: "c@s.whatsapp.net",
        voter_jid: "v@s.whatsapp.net"
      }

      hashes = Enum.map(["A", "B"], &Poll.option_hash/1)
      enc = PollCrypto.encrypt_vote(hashes, ctx)

      assert {:ok, %{selectedOptions: ^hashes}} = PollCrypto.decrypt_vote(enc, ctx)
    end

    test "round-trips with LID jids, and a jid-form mismatch fails (#2158)" do
      lid_ctx = %{
        message_secret: :crypto.strong_rand_bytes(32),
        poll_msg_id: "PID",
        poll_creator_jid: "111@lid",
        voter_jid: "222@lid"
      }

      hashes = [Poll.option_hash("Yes")]
      enc = PollCrypto.encrypt_vote(hashes, lid_ctx)

      # Same LID jids decrypt fine — the cipher is jid-form agnostic.
      assert {:ok, %{selectedOptions: ^hashes}} = PollCrypto.decrypt_vote(enc, lid_ctx)

      # Decrypting with the PN form of the voter (a different string) derives the
      # wrong key — this is the #2158 trap, and it fails cleanly, not a crash.
      pn_voter = %{lid_ctx | voter_jid: "222@s.whatsapp.net"}
      assert {:error, :decrypt_failed} = PollCrypto.decrypt_vote(enc, pn_voter)
    end
  end

  # Inverse of PollCrypto.decrypt_vote — encrypt a vote for the round-trip test.
  defp encrypt_vote(plaintext, secret, poll_id, creator, voter) do
    sign = poll_id <> creator <> voter <> "Poll Vote" <> <<1>>
    key0 = :crypto.mac(:hmac, :sha256, <<0::256>>, secret)
    key = :crypto.mac(:hmac, :sha256, key0, sign)
    iv = :crypto.strong_rand_bytes(12)
    aad = "#{poll_id}\0#{voter}"
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
    %Proto.Message.PollEncValue{encPayload: ct <> tag, encIv: iv}
  end
end
