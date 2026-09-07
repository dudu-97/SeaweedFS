# POCs

Índice dos testes documentados individualmente, um `POC-N.md` por teste,
a partir de agora. Ver `HISTORICO.md` para tudo que já foi validado antes
desse formato.

- [POC-I.md](POC-I.md) — O que acontece quando envio o dado com replicação 000 por padrão? (concluída: fragmenta em chunks de 4MiB e espalha entre racks, mesmo sem nenhuma réplica)
- [POC-II.md](POC-II.md) — A cota considera só a versão atual, ou soma as versões antigas também? (concluída: soma tudo; e achado extra — versionamento só é garantido via API S3, não via upload direto no Filer)
- [POC-III.md](POC-III.md) — `min_volume_age_seconds` do vacuum é mesmo respeitado? (aberta, não iniciada — decisão de não seguir por enquanto)
- [POC-IV.md](POC-IV.md) — Lifecycle não roda sozinho: por quê, e como lidar com isso em produção (concluída: campo em branco = sem carência de dias; lifecycle agendado ~24h, não travado; cron de 30min é possível mas afeta o cluster inteiro, não 1 bucket)
- [POC-V.md](POC-V.md) — Lifecycle em múltiplos buckets: passada global, mas contagem inconsistente (concluída: bug de contagem confirmado no comando manual `run-shard` — 13/40 buckets (32,5%) com 1 versão a menos do que configurado, 0/5 quando isolado a 1 bucket; **mas o caminho automático real testado com 10 buckets/10 regras diferentes saiu 10/10 correto** — bug parece específico do comando manual, não do ciclo de produção)

