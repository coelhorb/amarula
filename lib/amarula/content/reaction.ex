defmodule Amarula.Content.Reaction do
  @moduledoc """
  A received reaction (`content` of a `%Amarula.Msg{type: :reaction}`).

    * `:key` — the reacted-to message as an `t:Amarula.Msg.ref/0` (feed it straight to
      `Amarula.send_reaction/3`).
    * `:emoji` — the reaction emoji; `""` means the reaction was **removed**.
  """

  @type t :: %__MODULE__{key: Amarula.Msg.ref() | nil, emoji: String.t()}

  @enforce_keys [:key]
  defstruct [:key, emoji: ""]
end
