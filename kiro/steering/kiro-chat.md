---
inclusion: always
---
# Chat entre bots (Kiro Chat)

Existe um chat aberto compartilhado entre todos os bots do Kiro Crew, acessível pelas ferramentas do servidor MCP `kiro-chat`.
Use-o para coordenar trabalho com os outros bots.

- No início de cada tarefa, chame `read_messages` para ver o que os outros bots disseram em `#geral`.
  Se a ferramenta disser que você não tem identidade, chame `join_chat` com o **seu** nome (o primeiro nome com que
  você aparece no Kiro Crew, ex: "Jon - Chief" → Jon) e uma descrição do que você faz. Nunca use nomes de exemplo.
- Se você aparecer no chat com um nome que não é o seu, chame `join_chat` com o seu nome. Não coloque `--bot` no
  `mcp.json` compartilhado.
- Quando precisar de algo de outro bot, use `send_message` mencionando `@nome` (veja quem existe com `list_bots`).
  Use `@todos` para falar com todos.
- Para avisos urgentes ou para acionar um bot que precisa agir agora, use `notify_bot`.
- Se uma resposta de ferramenta mostrar "🔔 menção(ões) não lida(s)", chame `check_mentions` e responda quem te chamou
  com `send_message`, no mesmo canal e com `reply_to` igual ao id da mensagem.
- Ao terminar uma tarefa que alguém pediu, avise no chat mencionando quem pediu.
- Para trabalhos longos, crie um canal próprio com `create_channel` (ex: `feature-login`).
- Se você foi iniciado por um gatilho do Kiro Chat (o prompt diz que você foi chamado), siga o prompt:
  se ele disser que sua resposta será publicada automaticamente, escreva só o texto da resposta; senão,
  responda com `send_message`. Depois termine. Não fique em loop: o chat te acorda de novo quando precisar.
- Não crie cron nem script de "escuta" do chat para você: o Kiro Chat já te acorda quando alguém te chama.
- Só use `wait_for_mentions` em loop se o humano pedir explicitamente para você ficar de plantão.
- Seja objetivo: mensagens curtas, com ids de PR, commits e caminhos de arquivos quando relevante.
- `#geral` é um canal aberto: todos os bots escutam as mensagens dos humanos. Se você foi acordado por uma mensagem
  que não te menciona, responda só se o assunto for com você ou se tiver algo novo; senão, `[SEM RESPOSTA]`.
- Para a conversa terminar:
  - Só mencione outro bot se precisar que ele faça algo agora: mencionar acorda o bot. Para agradecer, concordar
    ou confirmar, não mencione ninguém.
  - Quando a tarefa acabar, inclua `[FIM]` na mensagem (ou use `send_message` com `final: true`). Ela é publicada,
    mas não acorda ninguém.
  - Se não tiver nada útil a acrescentar, não responda (num gatilho, responda `[SEM RESPOSTA]`).
  - Existe um limite de trocas seguidas entre bots sem um humano. Ao atingi-lo, ninguém mais é acordado.
