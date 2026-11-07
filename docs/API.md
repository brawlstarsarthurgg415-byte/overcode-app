# API do Overcode Hub

**Versão:** v1  
**Base local:** `http://127.0.0.1:8765`  
**Contrato:** `GET /api/v1/openapi.json`

## Conexão

No celular, inicie o motor no Termux:

```bash
overcode-hub start
```

Na mesma máquina, use `http://127.0.0.1:8765`. Para outro dispositivo na rede local, inicie `overcode-hub lan` no computador e envie o token Bearer em cada chamada. Não encaminhe a porta 8765 para a internet.

## Endpoints principais

| Método | Rota | Função |
|---|---|---|
| GET | `/api/v1/health` | Estado do motor |
| GET | `/api/v1/state` | Modo, diretório e atividade |
| GET | `/api/v1/models` | Provedores e modelos sem expor chaves |
| GET | `/api/v1/capabilities` | Recursos e limites |
| GET | `/api/v1/sessions` | Histórico |
| GET | `/api/v1/session/{id}` | Uma conversa |
| POST | `/api/v1/chat` | Conversar com o agente |
| POST | `/api/v1/mode` | normal, ask, plan, auto ou custom |
| POST | `/api/v1/terminal` | Comando local com política de aprovação |
| POST | `/api/v1/ssh/connect` | Testar conexão SSH por chave |
| POST | `/api/v1/ssh/run` | Comando remoto com política de aprovação |
| GET | `/api/v1/plugins` | Plugins instalados |
| POST | `/api/v1/plugins/download` | Baixar ZIP do GitHub, desativado por padrão |

As rotas antigas `/api/...` continuam funcionando por compatibilidade.

## Exemplo cURL

```bash
curl http://127.0.0.1:8765/api/v1/health
curl -X POST http://127.0.0.1:8765/api/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Resuma o estado do projeto"}'
```

Para acesso LAN, acrescente `-H 'Authorization: Bearer SEU_TOKEN'`.

## SDKs

- Python: `sdk/python/overcode.py`
- JavaScript: `sdk/javascript/overcode.js`

Exemplo Python:

```python
from overcode import Overcode

oc = Overcode("http://127.0.0.1:8765")
print(oc.health())
print(oc.chat("Olá, Overcode!"))
```

## Segurança

- O Hub local escuta em loopback por padrão.
- O modo LAN exige token Bearer.
- Não há endpoint que revele chaves de provedores.
- Comandos de instalação e operações de risco continuam sujeitos a aprovação.
- SSH usa chave ou ssh-agent; a senha não é salva.
- Plugins baixados permanecem desativados. Marcar um plugin como ativo não executa código. A execução extensível de plugins requer revisão e permissões específicas e não é anunciada como pronta nesta versão.