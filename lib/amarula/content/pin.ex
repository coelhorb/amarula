defmodule Amarula.Content.Pin do
  @moduledoc """
  A received pin / unpin (`content` of a `%Amarula.Msg{type: :pin}`).

    * `:key` — the pinned message as an `Amarula.Msg.ref/0`.
    * `:pinned?` — `true` for a pin, `false` for an unpin.
  """

  @type t :: %__MODULE__{key: Amarula.Msg.ref() | nil, pinned?: boolean()}

  @enforce_keys [:key]
  defstruct [:key, pinned?: false]
end
