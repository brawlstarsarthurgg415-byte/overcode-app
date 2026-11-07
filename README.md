# Overcode v2.7 — Kelly Hub + Android

Este pacote acrescenta uma interface gráfica local ao motor de terminal Overcode. O motor e seus comandos existentes (`/ssh`, `/terminal`, `/parar`, `/skills`, `/resume`, `/rewind`, etc.) continuam preservados. SSH e terminal ficam recolhidos em **Ferramentas avançadas**, não foram removidos.

## O que já está neste pacote

- Painel web responsivo em `http://127.0.0.1:8765`, com histórico, preferências e feed de atividades atualizado enquanto a IA executa comandos.
- Voz de saída selecionável entre as vozes disponíveis no navegador; reconhecimento de fala em navegadores compatíveis.
- Modo Plano persistente: após a aprovação, a Kelly continua no modo Plano e não repete a pergunta de aprovação do plano. Ações de risco ainda pedem confirmação.
- Terminal local e conexão SSH por chave/ssh-agent, em uma área recolhida.
- Lista de habilidades, download de ZIPs do GitHub e API v1 documentada. Plugins baixados ficam desativados; o código não é executado automaticamente.
- Projeto Android Kotlin com WebView, vozes nativas selecionáveis, reconhecimento de fala e registro de `VoiceInteractionService` para funcionar como assistente digital.
- API REST v1 com contrato OpenAPI, SDKs Python/JavaScript, estado de modelos e capacidades, mantendo as rotas antigas por compatibilidade.
- Atalho de build no GitHub Actions para gerar `app-debug.apk` a partir do projeto Android.

## Instalação no Termux ou Linux

Extraia o ZIP e entre na pasta `Overcode_2_6`. Execute:

```bash
bash install.sh
```

O instalador reaplica o motor v2.5 (mantendo backup da instalação anterior, como fazia o instalador v2.5) e instala o painel. Depois:

```bash
overcode
```

Escolha a IA com `/model` e configure a chave com `/apikey` quando necessário. Saia do menu inicial quando terminar. Em seguida:

```bash
overcode-hub start
overcode-hub open
```

Para parar/consultar:

```bash
overcode-hub status
overcode-hub stop
```

O servidor usa `127.0.0.1` por padrão — só o próprio aparelho pode acessá-lo. Para rodar no computador e conectar de outro aparelho na mesma rede, execute `overcode-hub lan`. Ele mostra o token Bearer no terminal; cole esse token no painel que abrir no celular. O APK guarda o token para que a janelinha do assistente também consiga conversar com o motor remoto. Restrinja a rede e não encaminhe a porta 8765 para a internet.

### Modelos locais

Se `/model` selecionou um modelo local e o arquivo GGUF já está em `~/.overcode/modelos`, o Hub tenta iniciar `llama-server` automaticamente. Se estiver faltando, consulte `~/.overcode/hub/llama-server.log`. Modelos locais podem exigir bastante RAM. O perfil cloud usa as chaves já gravadas pelo motor em `~/.overcode/provedores.json`.

## Instalar e configurar o APK

Abra a pasta `android/` no Android Studio e aguarde sincronizar o Gradle. Use **Build > Build Bundle(s) / APK(s) > Build APK(s)**. O APK debug ficará em `android/app/build/outputs/apk/debug/app-debug.apk`.

O projeto também inclui `.github/workflows/android-apk.yml`: envie o conteúdo completo desta pasta `Overcode_2_6` para a raiz de um repositório GitHub (mantendo juntas as pastas `android/` e `.github/`). Depois abra **Actions** e execute **Build Overcode APK**. O workflow anexa o APK `Overcode-Kelly-debug-apk` como artefato para baixar. Esse é um APK de depuração para teste pessoal, não uma versão de lançamento assinada para publicar na Play Store.

Ao abrir o app, use `http://127.0.0.1:8765` se o motor estiver no próprio celular (Termux). Se o motor estiver no computador, informe o endereço LAN do computador, por exemplo `http://192.168.1.20:8765`, inicie `overcode-hub lan` no computador e informe o token no painel.

### Botão lateral Samsung

No app, toque **Definir como assistente** e aceite a escolha do assistente digital, quando o Android oferecer a opção. Depois, no Samsung, procure **Configurações > Recursos avançados > Botão lateral > Pressionar e segurar > Assistente digital** e selecione Overcode, se a versão da One UI mostrar essa opção. A disponibilidade e o caminho variam por modelo/versão; se a opção não aparecer, use o atalho do app ou abra o painel normalmente.

**Aviso:** ao configurar o botão lateral para abrir um assistente, alguns modelos deixam de usar esse botão para exibir o menu de desligamento. A Samsung informa alternativas como usar o painel rápido ou pressionar Botão lateral + Volume para baixo.

## Vozes

- No site: **Preferências e vozes** lista as vozes instaladas que o navegador disponibiliza.
- No APK: o mesmo seletor lista as vozes instaladas pelo mecanismo Android TextToSpeech; o reconhecimento usa o serviço de voz instalado no aparelho. O painel guarda a escolha do navegador separada da escolha nativa do Android, porque os catálogos de vozes podem ser diferentes.
- O idioma de reconhecimento está definido como `pt-BR`. Disponibilidade e qualidade dependem do pacote de voz e do serviço instalado.

## API v1 e SDK

O Hub oferece uma API REST local em `http://127.0.0.1:8765/api/v1`. O contrato OpenAPI fica em `api/openapi.json` e também é servido em `/api/v1/openapi.json`.

- `GET /health`, `/state`, `/models` e `/capabilities`
- `GET /sessions` e `/session/{id}`
- `POST /chat`, `/mode`, `/terminal`, `/ssh/connect`, `/ssh/run`
- Aprovação de comandos e planos, lista de habilidades e catálogo de plugins
- SDK Python em `sdk/python/overcode.py`
- SDK JavaScript em `sdk/javascript/overcode.js`

As rotas antigas `/api/...` continuam aceitas. O modo local usa loopback sem token; o modo LAN exige Bearer token. O endpoint de modelos nunca retorna chaves de provedores.

Exemplo rápido:

```python
from overcode import Overcode
client = Overcode("http://127.0.0.1:8765")
print(client.health())
print(client.chat("Olá, Kelly!"))
```

## Segurança e limites desta versão

- O Hub escuta somente em localhost por padrão. O modo LAN exige token.
- Comandos identificados como destrutivos ou de instalação aguardam aprovação. Isso é uma barreira adicional, não substitui revisão humana.
- Perfis SSH guardam host/usuário/porta/caminho de chave, nunca a senha. Prefira chave SSH ou ssh-agent.
- Plugins podem ser baixados, inspecionados e marcados como ativos, mas este pacote **não executa código de plugin automaticamente**. A API REST v1 e os SDKs Python/JavaScript já estão disponíveis. A execução de código de plugins e as permissões específicas por plugin continuam desativadas até existir uma sandbox revisada.
- O painel não altera automaticamente a interface de terminal. O comando `overcode` continua disponível.
- A interface Android é um projeto de código-fonte. Este ambiente não tem Android SDK/Gradle instalado; portanto não foi possível compilar nem testar um APK binário aqui. O build pode ser feito pelo Android Studio ou pelo workflow do GitHub Actions.

## Estrutura

- `instalar-overcode-v2_5.sh` — motor CLI existente preservado.
- `install.sh` — instalador do conjunto.
- `hub/server.py` — servidor local e API.
- `hub/web/index.html` — interface gráfica.
- `android/` — aplicativo Android e assistente de botão lateral.
- `.github/workflows/android-apk.yml` — geração do APK em GitHub Actions.