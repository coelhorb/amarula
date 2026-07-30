defmodule Amarula.Content.Edit do
  @moduledoc """
  A received message edit (`content` of a `%Amarula.Msg{type: :edit}`).

    * `:key` — the edited message as an `Amarula.Msg.ref/0`.
    * `:text` — the new text.
  """

  @type t :: %__MODULE__{key: Amarula.Msg.ref() | nil, text: String.t() | nil}

  @enforce_keys [:key]
  defstruct [:key, :text]
end
