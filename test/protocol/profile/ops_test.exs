defmodule Amarula.Protocol.Profile.OpsTest do
  use ExUnit.Case, async: true

  alias Amarula.Protocol.Binary.{Node, NodeUtils}
  alias Amarula.Protocol.Profile.Ops

  # Fake placeholder jids only (no real numbers — repo PII rule).
  @target "15550009999@s.whatsapp.net"

  defp child(%Node{content: [c | _]}), do: c

  describe "picture_url_query/2" do
    test "builds a w:profile:picture get with target + picture url query (preview default)" do
      iq = Ops.picture_url_query(@target)
      assert iq.tag == "iq"
      assert NodeUtils.get_attr(iq, "xmlns") == "w:profile:picture"
      assert NodeUtils.get_attr(iq, "type") == "get"
      assert NodeUtils.get_attr(iq, "target") == @target

      picture = child(iq)
      assert picture.tag == "picture"
      assert NodeUtils.get_attr(picture, "type") == "preview"
      assert NodeUtils.get_attr(picture, "query") == "url"
    end

    test "honors :image type" do
      iq = Ops.picture_url_query(@target, :image)
      assert NodeUtils.get_attr(child(iq), "type") == "image"
    end

    test "with no tctoken the <picture> node stays childless" do
      assert Ops.picture_url_query(@target, :preview, []) == Ops.picture_url_query(@target)
      assert child(Ops.picture_url_query(@target)).content == nil
    end

    # Baileys shipped the tctoken as a SIBLING of <picture> and corrected it to
    # nested in v7.0.0-rc14 (#2607). A sibling makes the server ignore the token,
    # so the picture comes back empty — indistinguishable from "no picture".
    test "the tctoken nests INSIDE <picture>, not beside it" do
      tctoken = Node.create("tctoken", %{"t" => "1770000000"}, <<4, 1, 33>>)
      iq = Ops.picture_url_query(@target, :image, [tctoken])

      assert [%Node{tag: "picture"} = picture] = iq.content
      assert picture.content == [tctoken]
      assert NodeUtils.get_attr(picture, "type") == "image"
      assert NodeUtils.get_attr(picture, "query") == "url"

      refute NodeUtils.get_binary_node_child(iq, "tctoken"),
             "tctoken must not be a sibling of <picture>"
    end

    test "the nested tctoken carries its issue timestamp as the `t` attr" do
      tctoken = Node.create("tctoken", %{"t" => "1770000000"}, <<4, 1, 33>>)
      iq = Ops.picture_url_query(@target, :preview, [tctoken])

      assert %Node{content: [nested]} = child(iq)
      assert nested.tag == "tctoken"
      assert NodeUtils.get_attr(nested, "t") == "1770000000"
      assert nested.content == <<4, 1, 33>>
    end
  end

  describe "set_picture/2 and remove_picture/1 target handling" do
    test "a specific jid carries target=jid" do
      iq = Ops.set_picture(@target, <<0xFF, 0xD8, 0xFF>>)
      assert NodeUtils.get_attr(iq, "type") == "set"
      assert NodeUtils.get_attr(iq, "target") == @target

      picture = child(iq)
      assert picture.tag == "picture"
      assert NodeUtils.get_attr(picture, "type") == "image"
      assert picture.content == <<0xFF, 0xD8, 0xFF>>
    end

    test "self (nil target) OMITS the target attr (server never replies if present)" do
      iq = Ops.set_picture(nil, <<1, 2, 3>>)
      refute Map.has_key?(iq.attrs, "target")
    end

    test "remove_picture has no content and respects target" do
      assert Ops.remove_picture(@target).content == nil
      assert NodeUtils.get_attr(Ops.remove_picture(@target), "target") == @target
      refute Map.has_key?(Ops.remove_picture(nil).attrs, "target")
    end
  end

  describe "set_status/1" do
    test "builds a status set IQ carrying the status text" do
      iq = Ops.set_status("hello world")
      assert NodeUtils.get_attr(iq, "xmlns") == "status"
      assert NodeUtils.get_attr(iq, "type") == "set"

      status = child(iq)
      assert status.tag == "status"
      assert status.content == "hello world"
    end
  end

  describe "parse_url/1" do
    test "pulls the url from a <picture url=...> reply" do
      reply = %Node{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %Node{tag: "picture", attrs: %{"url" => "https://example.test/p.jpg"}, content: nil}
        ]
      }

      assert Ops.parse_url(reply) == "https://example.test/p.jpg"
    end

    test "returns nil when there is no picture child" do
      assert Ops.parse_url(%Node{tag: "iq", attrs: %{}, content: []}) == nil
    end
  end
end
