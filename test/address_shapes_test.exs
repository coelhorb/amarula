defmodule Amarula.AddressShapesTest do
  @moduledoc """
  A systematic sweep of every hostile address shape (`Amarula.AddressFixtures`)
  through the boundaries the #41 / #46–#51 bugs each lived at — so a future shape
  that slips one of them fails here, not silently on the wire. #52.
  """
  use ExUnit.Case, async: true

  alias Amarula.{Address, AddressFixtures}
  alias Amarula.Protocol.Binary.JID

  describe "resolvable shapes parse and normalize to their account level" do
    for {label, jid, kind, account_jid} <- AddressFixtures.resolvable() do
      test "#{label}: parses to #{kind}, normalizes to #{account_jid}" do
        assert %Address{kind: unquote(kind)} = Address.parse(unquote(jid))

        # The MessageKey / reply-handle boundary (`key_jid/1` → `jid_normalized_user`)
        # must strip device + agent — the #46/#48 fixes.
        assert JID.jid_normalized_user(unquote(jid)) == unquote(account_jid)
      end
    end
  end

  describe "device / agent suffixes never change the account (#41, #51)" do
    test "a PN with a device or agent is same_account? its clean form" do
      clean = Address.parse(AddressFixtures.pn())
      assert Address.same_account?(Address.parse(AddressFixtures.pn_with_device()), clean)
      assert Address.same_account?(Address.parse(AddressFixtures.pn_with_agent()), clean)
    end

    test "a LID with a device is same_account? its clean form" do
      clean = Address.parse(AddressFixtures.lid())
      assert Address.same_account?(Address.parse(AddressFixtures.lid_with_device()), clean)
    end
  end

  describe "unresolvable servers are nil today — documents the #50 contract" do
    for {label, jid} <- AddressFixtures.unresolvable() do
      test "#{label}: Address.parse/1 is nil; jid_normalized_user passes it through" do
        assert Address.parse(unquote(jid)) == nil

        # `key_jid/1` relies on the non-empty normalization: an unresolvable jid
        # rides through untouched rather than crashing a send.
        assert JID.jid_normalized_user(unquote(jid)) == unquote(jid)
      end
    end
  end
end
