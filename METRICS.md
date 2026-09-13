# Como ativar o `/metrics` (Prometheus) no `weed s3`

O gateway S3 do SeaweedFS (`weed s3`) só expõe métricas Prometheus se a flag
`-metricsPort` for passada na linha de comando dele. Não é algo que liga
sozinho, não tem endpoint de administração pra ativar em runtime, e não tem
hot-reload de flag — só é aplicado reiniciando o processo com a flag presente.

## Passo a passo

1. **Localize onde o `weed s3` é iniciado** — systemd unit, `docker run`/
   `docker-compose`, manifest do Kubernetes, script de start, etc. Isso
   depende de como o deploy foi feito em cada ambiente.

2. **Adicione a flag na linha de comando**:
   ```
   -metricsPort=9327
   ```
   Qualquer porta livre serve — `9327` é só um exemplo. Precisa ser uma
   porta que não colida com nada mais no host/container.

   Exemplo de `ExecStart` num systemd unit:
   ```ini
   [Service]
   ExecStart=/usr/local/bin/weed s3 -filer=<filers> -port=8333 -metricsPort=9327 [demais flags já usadas]
   ```

3. **(Opcional) Controle quem alcança a porta de métricas** com
   `-metricsIp`:
   - Vazio (padrão) → herda o mesmo IP de `-ip.bind`. Se esse já for
     `0.0.0.0`, a porta de métricas fica acessível de qualquer host que
     tenha rota até a máquina — sem autenticação nenhuma, é texto puro.
   - `-metricsIp=127.0.0.1` → restringe a métrica a processos rodando na
     mesma máquina (ex.: um agente Prometheus/coletor local, ou um proxy
     próprio que leia localhost e reexponha só o necessário — foi o padrão
     usado no `server.py` deste repositório).

4. **Reinicie o processo/serviço.** É a única forma de aplicar a mudança —
   não existe reload sem derrubar a conexão.

5. **Confirme que subiu**:
   ```bash
   curl http://<ip-do-s3>:<metricsPort>/metrics
   ```
   Resposta esperada: texto no formato de exposição do Prometheus, com
   linhas tipo `SeaweedFS_s3_bucket_size_bytes{bucket="..."} <valor>`.

## Considerações antes de aplicar

- **Reiniciar o `weed s3` interrompe a API S3 por alguns segundos** — todo
  PUT/GET/DELETE em andamento naquele processo é afetado. Planeje uma
  janela de baixo tráfego.
- **Se houver mais de uma instância de `weed s3` atrás de um balanceador**,
  reinicie uma de cada vez (rolling restart), nunca todas simultaneamente —
  senão a API S3 fica fora do ar por completo durante a troca.
- **A porta de métricas não tem autenticação nem TLS por padrão.** Se for
  ficar acessível fora da máquina (`-metricsIp` vazio com `-ip.bind` amplo),
  trate isso como qualquer outra porta de infraestrutura exposta — firewall/
  rede restrita até quem precisa coletar (ex.: o Prometheus, ou um proxy
  próprio).
- **Teste primeiro num ambiente que não seja produção**, se houver um
  disponível, antes de aplicar o restart em produção.

## O que essas métricas trazem, por bucket

Depois de ativado, o endpoint expõe (entre outras) estas séries, todas
rotuladas com `bucket="<nome>"`:

| Métrica | Significado |
|---|---|
| `SeaweedFS_s3_bucket_size_bytes` | tamanho lógico — uma cópia do dado vivo |
| `SeaweedFS_s3_bucket_physical_size_bytes` | tamanho físico em disco — réplicas + paridade EC, incluindo dado ainda não vacuumado |
| `SeaweedFS_s3_bucket_quota_bytes` | cota configurada via `s3.bucket.quota` — só aparece se a cota estiver habilitada |
| `SeaweedFS_s3_bucket_read_only` | `1` se o bucket está travado (ex.: por estourar a cota), `0` se gravável |
| `SeaweedFS_s3_bucket_object_count` | contagem de objetos no bucket |
