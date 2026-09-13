# Configurações de Permissões — Testes

Registro dos testes de permissionamento feitos no painel `weed admin` e via
cliente S3, comparando os dois caminhos de acesso ao dado.

## Teste 1 — Bypass de Object Lock pelo File Browser do painel admin

**Setup:** bucket `teste-onze`, Object Lock habilitado, retenção de 30 dias
(testado nos modos Governance e Compliance). Login no painel `weed admin`
com usuário de role `admin`.

**Observado:**

- Upload de arquivo direto pelo **File Browser do painel** → o objeto chega
  "limpo", sem nenhuma marcação de retenção, mesmo com Object Lock/30 dias
  configurado no bucket.
- Upload do mesmo bucket feito por um **client S3 de verdade** (testado pela
  nossa página de demo de upload, que assina a requisição como um client S3
  real) → o objeto chega **com** a retenção de 30 dias aplicada.
- **Bucket só com dado(s) enviado(s) pelo painel** → nenhum objeto tem
  marcação de retenção → o botão de **excluir bucket funciona direto, em
  um passo só**, independente do modo (Governance ou Compliance)
  configurado no bucket.
- **Bucket com pelo menos 1 dado enviado por um client S3 real** (Upload
  Demo, `mc`, `aws-cli` etc., portanto com a marcação de retenção aplicada)
  → o botão de excluir bucket **é bloqueado**
  (`"bucket has objects with active Object Lock retention or legal hold"`),
  tanto em Governance quanto em Compliance.
- Nesse segundo caso, se em vez de usar o botão de excluir bucket a pessoa
  for no File Browser e apagar **cada arquivo individualmente** (inclusive
  o que está com retenção ativa) → a exclusão do arquivo **funciona**, mesmo
  em Compliance. Esvaziando o bucket assim, o botão de excluir bucket passa
  a funcionar em seguida — ou seja, dá para destruir o bucket inteiro em
  dois passos mesmo quando ele tem dado sob Compliance.

**Causa raiz:** o painel tem dois caminhos de exclusão diferentes. O de
"excluir bucket" checa explicitamente se existe retenção/legal hold ativo
antes de deixar apagar. Já o "excluir arquivo" do File Browser fala direto
com o filer (sem passar pela camada que aplica e verifica Object Lock) e por
isso nunca checa retenção — apaga independente do modo configurado. Pelo
mesmo motivo, um upload feito por ali também não recebe a marcação de
retenção que o bucket deveria aplicar por padrão: essa aplicação também só
acontece no caminho da API S3.

**Quem consegue reproduzir:** só quem tem a credencial de **role "admin"**
do painel (não a de "readonly" — essa é bloqueada nessas ações). Isso é uma
credencial do próprio `weed admin`, separada das access keys S3.

**Risco:** a garantia de retenção regulatória (WORM/Compliance) só existe no
caminho da API S3. Quem tiver a senha de admin do painel derruba Compliance
sem bypass, sem header especial e sem nenhum registro de "bypass" — o
controle de acesso ao painel precisa ser tratado com o mesmo cuidado que se
dá à política de IAM S3, e não como um acesso operacional qualquer.
