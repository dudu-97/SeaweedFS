# Fluxo: Object Lock — upload/exclusão via Client S3 x Painel Admin

Diagrama de como a mesma configuração de Object Lock (Governance/Compliance,
30 dias de retenção default) tem efeito completamente diferente dependendo
de o dado entrar/sair pela API S3 ou pelo File Browser do `weed admin`.
Testado e confirmado no lab (ver `CONFIGURACOES-DE-PERMISSOES.md`).

## Diagrama

```mermaid
flowchart TD
    Start["Bucket com Object Lock habilitado\n(ex.: Compliance, 30 dias de retenção default)"] --> Choice{"Por onde o dado entra?"}

    Choice -->|"Client S3\n(aws-cli, mc, Upload Demo)"| C1
    Choice -->|"Painel weed admin\n(File Browser → Upload)"| P1

    subgraph CLIENTFLOW["Caminho: Client S3 (requisição assinada)"]
        C1["PUT /bucket/chave (SigV4)"] --> C2["s3api: grava o objeto no filer"]
        C2 --> C3{"Bucket tem retenção\ndefault configurada?"}
        C3 -->|"sim"| C4["Retenção default aplicada\nautomaticamente no PutObject\n(ou client manda\nx-amz-object-lock-mode /\n-retain-until-date)"]
        C3 -->|"não, mas client chama depois"| C4b["PutObjectRetention /\nPutObjectLegalHold"]
        C4 --> C5["Objeto gravado COM\nExtObjectLockModeKey +\nExtRetentionUntilDateKey"]
        C4b --> C5
    end

    subgraph PANELFLOW["Caminho: Painel admin (File Browser)"]
        P1["Upload pelo File Browser\n(UploadFile handler)"] --> P2["Grava direto no filer,\nsem passar pelo s3api"]
        P2 --> P3["⚠️ Retenção default do bucket\nNUNCA é aplicada aqui —\nsó existe no caminho da API S3"]
        P3 --> P4["Objeto gravado\nSEM nenhum atributo de lock"]
    end

    C5 --> D1
    P4 --> D2

    subgraph DELETEOBJ["Exclusão de objeto"]
        D1["DELETE via client S3\n→ checkObjectLockPermissions()"] --> D1a{"Modo?"}
        D1a -->|"Governance + tem\ns3:BypassGovernanceRetention"| D1b["Permite apagar"]
        D1a -->|"Governance sem a permissão,\nou Compliance (sempre)"| D1c["Nega — Access Denied"]

        D2["DELETE via File Browser\n→ filer_pb.DoRemove direto"] --> D2a["⚠️ Nenhuma checagem de lock —\napaga sempre, qualquer modo"]
    end

    D1b --> E1
    D1c --> E1
    D2a --> E1

    subgraph DELETEBUCKET["Exclusão do bucket"]
        E1{"Excluir bucket →\nCheckBucketForLockedObjects\nvarre todos os objetos"}
        E1 -->|"achou objeto com\nlock ainda ativo"| E2["Bloqueia:\n'bucket has objects with\nactive Object Lock...'"]
        E1 -->|"nenhum objeto\ncom lock ativo"| E3["Exclui o bucket normalmente"]
        E2 -.->|"apagar cada arquivo\npelo File Browser primeiro\n(bypass acima)"| E1
    end
```

## Leitura rápida

- **Tudo via client S3**: objeto nasce com retenção → `DELETE` do objeto
  respeita Governance/Compliance → excluir o bucket fica bloqueado enquanto
  existir objeto travado.
- **Tudo via painel (File Browser)**: objeto nasce **sem** retenção, porque
  esse caminho não passa pelo código que aplica a configuração de Object
  Lock do bucket → excluir bucket funciona direto, em um passo.
- **Misto** (algum objeto veio de client S3): excluir bucket é bloqueado,
  mas cada arquivo travado pode ser apagado individualmente pelo File
  Browser (que nunca checa lock) → esvazia o bucket → aí o bucket sai.

## Referências
- [CONFIGURACOES-DE-PERMISSOES.md](CONFIGURACOES-DE-PERMISSOES.md)
- `weed/s3api/s3api_object_retention.go` (checagem no client S3)
- `weed/admin/handlers/file_browser_handlers.go` (Upload/DeleteFile do painel)
- `weed/s3api/s3_objectlock/object_lock_check.go` (checagem na exclusão de bucket)
