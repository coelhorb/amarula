defmodule Amarula.Content.Keep do
  @moduledoc """
  A received keep-in-chat / undo (`content` of a `%Amarula.Msg{type: :keep}`).

    * `:key` — the kept message as an `t:Amarula.Msg.ref/0`.
    * `:kept?` — `true` to keep, `false` to undo a keep.
  """

  @type t :: %__MODULE__{key: Amarula.Msg.ref() | nil, kept?: boolean()}

  @enforce_keys [:key]
  defstruct [:key, kept?: false]
end
