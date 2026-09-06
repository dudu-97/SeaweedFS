# POCs

Índice dos testes documentados individualmente, um `POC-N.md` por teste,
a partir de agora. Ver `HISTORICO.md` para tudo que já foi validado antes
desse formato.

- [POC-I.md](POC-I.md) — O que acontece quando envio o dado com replicação 000 por padrão? (concluída: fragmenta em chunks de 4MiB e espalha entre racks, mesmo sem nenhuma réplica)
- [POC-II.md](POC-II.md) — A cota considera só a versão atual, ou soma as versões antigas também? (concluída: soma tudo; e achado extra — versionamento só é garantido via API S3, não via upload direto no Filer)
- [POC-III.md](POC-III.md) — `min_volume_age_seconds` do vacuum é mesmo respeitado? (aberta, não iniciada — decisão de não seguir por enquanto)
- [POC-IV.md](POC-IV.md) — Lifecycle não roda sozinho: por quê, e como lidar com isso em produção (concluída: campo em branco = sem carência de dias; lifecycle agendado ~24h, não travado; cron de 30min é possível mas afeta o cluster inteiro, não 1 bucket)
- [POC-V.md](POC-V.md) — Lifecycle em múltiplos buckets: passada global, mas contagem inconsistente (concluída: confirma passada global + regra por bucket; achado forte — 5 de 15 buckets testados (33%) retiveram 1 versão não-corrente a menos do que a regra mandava, versão atual nunca afetada; candidato a relato formal)

