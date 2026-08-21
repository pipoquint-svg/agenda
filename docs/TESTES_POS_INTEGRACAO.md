# BlackSheep Agenda — Testes pós-integração

Status: **gate obrigatório de sandbox e go-live**.

Este documento é normativo. Nenhum teste com integrações conectadas pode começar sem cumprir a preparação abaixo. Se um requisito não puder ser cumprido, o teste correspondente permanece **NÃO TESTADO** e o processo para nessa etapa. Não improvisar alternativa.

## Regra de evidência

Cada item deve terminar com um dos estados:

- `PASSOU`
- `FALHOU`
- `NÃO TESTADO`

Ausência de evidência nunca equivale a aprovação.

## 1. Ambiente de teste isolado

### Google Cloud e Google Calendar

Obrigatório antes de conectar:

- projeto Google Cloud exclusivo de teste, separado de produção;
- conta Google de teste, nunca conta operacional;
- calendários fictícios exclusivos, todos com prefixo `TESTE`;
- nenhum mapping de sandbox pode apontar para calendário operacional;
- registrar o estado de publicação OAuth;
- para testes duráveis, usar uma destas estratégias e registrar qual foi adotada:
  - `OAUTH_PUBLICADO`; ou
  - `WORKSPACE_DELEGATION` quando tecnicamente aplicável;
- se o app estiver em `Testing`, não considerar o ambiente pronto para os testes duráveis: refresh tokens podem expirar e a Agenda deve falhar fechada;
- registrar os scopes efetivamente concedidos;
- confirmar permissão de escrita, não apenas leitura.

Scopes esperados pelo runtime atual:

- `openid`
- `email`
- `https://www.googleapis.com/auth/calendar.events`
- `https://www.googleapis.com/auth/calendar.calendarlist.readonly`

### Mercado Pago

- sandbox obrigatório;
- usuário de teste obrigatório;
- cartões/PIX de teste;
- webhook, confirmação e reconciliação executados integralmente no sandbox;
- nenhuma credencial produtiva no ambiente de teste;
- registrar a estratégia/chave de idempotência usada e comprovar ausência de colisão com integrações existentes;
- credencial de produção só pode ser instalada após todos os critérios de saída do sandbox.

### Meta / WhatsApp

- templates transacionais devem ser submetidos à aprovação em paralelo ao desenvolvimento;
- enquanto não aprovados, usar número/test infrastructure dedicada;
- nenhum número de cliente real em teste;
- nenhuma mensagem de teste pode sair para operação real.

### Dados

- nenhum nome, telefone, e-mail, CPF/CNPJ ou outro dado de cliente real;
- dados de teste devem ser explicitamente fictícios;
- antes de produção executar varredura de placeholders, domínios de exemplo, IDs de exemplo e textos `TESTE`/`test` indevidos;
- nenhum dado fictício do sandbox pode ser promovido para produção.

## 2. Ordem obrigatória dos testes

Não avançar enquanto a etapa anterior não estiver `PASSOU`.

### Etapa 1 — Gate A: integridade de reserva

Executar contra o banco real **do ambiente sandbox**, com concorrência real.

Casos mínimos:

1. requisições paralelas para o mesmo slot/recurso;
2. holds simultâneos para o mesmo slot/recurso;
3. hold concorrendo com confirmação;
4. bloqueio externo chegando durante hold;
5. confirmar que a constraint de recurso é a autoridade final;
6. confirmar que divergência é registrada e nunca descartada silenciosamente.

Resultado obrigatório: exatamente um fluxo vence quando houver disputa exclusiva. Dupla reserva deve ser tecnicamente impossível por execução concorrente, não apenas por leitura de código.

### Etapa 2 — Retorno de pagamento em iOS Safari

Executar com Mercado Pago sandbox:

- Safari em iPhone real com ITP ativo;
- Android Chrome;
- Chrome desktop;
- Safari desktop.

Confirmar em cada plataforma:

- pagamento volta para a jornada correta;
- usuário vê confirmação quando o pagamento foi confirmado;
- não existe pagamento confirmado invisível para o usuário;
- refresh/reentrada não duplica conversão nem pagamento.

### Etapa 3 — Hold expirando com pagamento em trânsito

- iniciar pagamento;
- forçar expiração/liberação do hold enquanto pagamento está em processamento;
- concluir aprovação depois da expiração;
- confirmar que o pagamento é registrado financeiramente;
- confirmar criação de incidente administrativo;
- confirmar que o slot não é reocupado automaticamente;
- confirmar que um recurso já vendido a terceiro nunca é roubado pela confirmação tardia.

Contrato esperado atual: `PAYMENT_AFTER_EXPIRATION`, sem reativação silenciosa.

### Etapa 4 — Sincronização Google

Testar somente calendários `TESTE`:

- evento externo ocupado gera bloqueio;
- evento marcado livre não gera bloqueio;
- evento de dia inteiro segue configuração do calendário;
- convite recusado não gera bloqueio;
- recorrência tratada por ocorrência;
- instância cancelada tratada corretamente;
- evento gerenciado pela própria Agenda não cria bloqueio externo contra si mesmo;
- exclusão externa libera bloqueio na sincronização seguinte;
- token/conexão expirada provoca falha fechada;
- falha fechada dispara alerta/incidente observável.

### Etapa 5 — Fluxo completo do cliente

Executar jornada integral em dispositivo real, com integrações sandbox:

- desktop;
- mobile;
- avançar e voltar etapas;
- hold curto;
- dados/termos;
- pagamento sandbox;
- confirmação;
- remarcar por link tokenizado;
- cancelar por link tokenizado;
- token expirado;
- token inválido;
- token já utilizado.

## 3. Registro obrigatório de bugs

Cada bug deve registrar:

- código de erro, quando houver;
- tela/etapa;
- dispositivo;
- navegador e versão;
- passos exatos de reprodução;
- `CONSISTENTE` ou `INTERMITENTE`;
- evidência disponível;
- PR/correção associada quando existir.

Ao fim de cada rodada, agrupar bugs por tela e por tipo de falha, nunca apenas em ordem cronológica.

## 4. Regra de correção

- corrigir por lote coerente;
- depois da correção repetir todas as etapas afetadas;
- regra de negócio nunca pode ser alterada para fazer um teste passar;
- qualquer correção que exija mudança de regra de negócio deve parar para decisão humana;
- especificação não pode ser alterada para acomodar comportamento observado.

## 5. Critérios obrigatórios para sair do sandbox

Todos devem estar `PASSOU`:

- Etapa 1 com evidência de concorrência;
- Etapa 2 em iPhone real;
- Etapa 3;
- todos os subitens da Etapa 4;
- Etapa 5 completa em mobile e desktop;
- varredura sem placeholder/dado fictício/domínio de teste em artefato produtivo;
- estratégia de publicação/autorização Google resolvida e registrada;
- alertas de falha configurados e testados, incluindo conexão Google expirada.

Enquanto qualquer item estiver `FALHOU` ou `NÃO TESTADO`, credenciais produtivas não podem ser conectadas.

## 6. Regras permanentes

- teste não escreve em calendário operacional;
- teste não envia WhatsApp para cliente real;
- teste não gera cobrança real;
- sincronização não verificável = agendamento falha fechado;
- item sem evidência = `NÃO TESTADO`;
- Amelia continua operando em paralelo durante a transição e não pode sofrer efeitos colaterais do sandbox.

## 7. Modelo de relatório por rodada

```text
RODADA:
DATA:
AMBIENTE:
COMMIT/DEPLOY:

ETAPA 1 — Gate A
PASSOU:
FALHOU:
NÃO TESTADO:
EVIDÊNCIAS:

ETAPA 2 — iOS Safari / retorno pagamento
PASSOU:
FALHOU:
NÃO TESTADO:
EVIDÊNCIAS:

ETAPA 3 — pagamento após expiração
PASSOU:
FALHOU:
NÃO TESTADO:
EVIDÊNCIAS:

ETAPA 4 — Google
PASSOU:
FALHOU:
NÃO TESTADO:
EVIDÊNCIAS:

ETAPA 5 — jornada completa
PASSOU:
FALHOU:
NÃO TESTADO:
EVIDÊNCIAS:

BUGS POR TELA:
BUGS POR TIPO:

DECISÕES HUMANAS PENDENTES:
```
