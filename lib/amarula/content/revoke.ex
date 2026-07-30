defmodule Amarula.Content.Revoke do
  @moduledoc """
  A received delete-for-everyone (`content` of a `%Amarula.Msg{type: :revoke}`).

    * `:key` — the revoked message as an `Amarula.Msg.ref/0`.
  """

  @type t :: %__MODULE__{key: Amarula.Msg.ref() | nil}

  @enforce_keys [:key]
  defstruct [:key]
end
