# POC III — `min_volume_age_seconds` do vacuum é mesmo respeitado?

**Status: aberta, não iniciada por decisão do usuário.** Registro do
ponto a investigar, sem execução por enquanto.

## Ponto a investigar

O `weed scaffold -config=admin` documenta, na seção `[maintenance.vacuum]`,
`min_volume_age_seconds = 86400` (24h) como default — um volume só
qualificaria pra vacuum depois de 24h de existência. Só que observamos
(POC II) um vacuum rodando com sucesso num cluster que tinha só algumas
horas de vida (redeploy feito na mesma tarde), no volume 47.

Duas hipóteses possíveis:
1. O default documentado no scaffold não é o que o código realmente usa
   quando não existe nenhum `admin.toml` real (confirmado: este
   ambiente não tem `admin.toml` em nenhum dos 4 caminhos de busca, nem
   `-dataDir` configurado no `weed-admin.service` — roda 100% em
   default embutido, que pode não ser idêntico ao do template).
2. "Idade" em `min_volume_age_seconds` não significa "tempo desde a
   criação do volume" — pode ser outra coisa (ex.: tempo desde a última
   escrita, parecido com o `quiet_for_seconds` do EC).

## Como testar (quando/se retomar)

1. Gerar um `admin.toml` explícito (`weed scaffold -config=admin > admin.toml`),
   descomentar `min_volume_age_seconds` com um valor bem alto (ex.:
   `999999`), colocar em `-dataDir` do `weed-admin.service`.
2. Reiniciar `weed-admin`.
3. Forçar um volume a acumular lixo (sobrescrever um arquivo, como no
   POC II) e ver se o vacuum ainda roda antes do tempo configurado —
   olhando `journalctl -u weed-worker` e `/api/plugin/scheduler-status`.

## Referência

Achado original, contexto completo da conversa que levantou a dúvida:
ver a pergunta "Como eu faria para ver as configurações de vacuum" no
histórico da sessão (ainda não copiado pro `HISTORICO.md`).
