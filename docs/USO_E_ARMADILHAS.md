# Uso do Amarula e armadilhas comuns

Este guia mostra o fluxo mínimo para conectar uma conta WhatsApp, validar um
número e enviar uma mensagem com Amarula. Use apenas contas e contatos para os
quais você tem autorização.

## 1. Inicie a árvore de supervisão e conecte um perfil

O `Amarula.Supervisor` deve estar em execução antes de abrir conexões. Em uma
aplicação OTP, adicione-o uma única vez ao seu supervisor; em um script, inicie-o
explicitamente:

```elixir
{:ok, _} = Amarula.Supervisor.start_link()

{:ok, conn} =
  Amarula.new(%{profile: :whatsapp_ana})
  |> Amarula.connect(parent_pid: self())

receive do
  {:amarula, :connection_update, %{connection: :open}} -> :ok
end
```

`profile` identifica as credenciais persistidas. Por padrão, elas ficam em
`amarula_data/<profile>/`; trate essa pasta como segredo, faça backup e nunca a
adicione ao Git.

Para emparelhar por código de telefone dentro deste repositório, use:

```bash
mix run examples/pair.exs whatsapp_ana 5534992050220
```

No celular: **WhatsApp → Dispositivos conectados → Conectar dispositivo →
Conectar com número de telefone**. O código tem oito caracteres e expira. Em um
aplicativo que depende de Amarula, o comando `mix amarula.pair <perfil> --phone
<numero>` requer que a aplicação inicie `Amarula.Supervisor`.

## 2. Valide o número antes de enviar

Use somente dígitos E.164, sem `+`, espaços, parênteses ou hífens. Consulte a
disponibilidade com `Amarula.Contacts.on_whatsapp/2` e use o endereço devolvido
pelo servidor — ele pode canonicalizar o número informado.

Exemplo real de número brasileiro com possível nono dígito:

1. teste primeiro `553488192957` (sem o `9` adicional);
2. se necessário, teste `5534988192957` (com o `9` adicional).

```elixir
defmodule Numero do
  alias Amarula.{Address, Contacts}

  def resolve(conn) do
    ["553488192957", "5534988192957"]
    |> Enum.reduce_while({:error, :not_on_whatsapp}, fn candidate, _acc ->
      case Contacts.on_whatsapp(conn, candidate) do
        {:ok, [%{exists: true, address: %Address{} = address}]} ->
          {:halt, {:ok, address}}

        {:ok, _} ->
          {:cont, {:error, :not_on_whatsapp}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
```

Na validação desta conta, os dois formatos resolveram para o mesmo endereço
canônico: `553488192957@s.whatsapp.net`. Portanto, não assuma que a entrada com
o nono dígito será o JID usado no envio; envie para o `Address` retornado por
`on_whatsapp/2`.

## 3. Envie somente depois de `:open`

```elixir
with {:ok, address} <- Numero.resolve(conn),
     {:ok, message_id} <- Amarula.send_text(conn, address, "Olá!") do
  IO.puts("Mensagem aceita: #{message_id}")
end
```

`{:ok, message_id}` significa que o servidor aceitou a mensagem. Não significa
leitura pelo destinatário. Não envie antes do evento `connection: :open`; fazer
isso pode falhar ou produzir uma sessão incompleta.

## Armadilhas e diagnóstico

### Erro `{:send_rejected, "463"}`

O WhatsApp pode bloquear o primeiro contato 1:1 até existir um token de
confiança (`tctoken`). Não reenvie em loop: cada tentativa adicional pode piorar
a restrição. Aguarde uma interação legítima do contato e verifique o resultado
de `send_text/3`.

O Amarula armazena esse token pela identidade LID do contato. Versões com a
correção de chaveamento LID devem encontrar o token tanto quando o envio começa
por PN quanto quando ele chega em uma notificação `@lid`. Se um perfil antigo
contiver a chave LID sem `@lid`, o Amarula a migra automaticamente na primeira
leitura.

### PN, LID e sessões

O número de telefone (PN) e o LID são identidades diferentes do mesmo contato.
Não construa LIDs manualmente. O Amarula aprende o mapeamento durante USync e
resolve sessões Signal no LID quando necessário. Para responder a uma mensagem
recebida, reutilize `msg.channel` em vez de remontar um número.

### Histórico não é caixa de entrada persistente

`{:amarula, :messages_upsert, ...}` entrega mensagens ao processo consumidor,
mas o Amarula não mantém um arquivo de conversas por conta própria. Se precisar
de busca, histórico ou auditoria, grave os eventos em seu próprio armazenamento.

### Execução de exemplos

Os exemplos em `examples/` servem para desenvolvimento local. Em produção,
mantenha uma conexão supervisionada, registre um processo para receber os
eventos e faça reconexão/telemetria no aplicativo. Nunca exponha o conteúdo de
`amarula_data/` em logs, imagens de contêiner ou suporte técnico.
