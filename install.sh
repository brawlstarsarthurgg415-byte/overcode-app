#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$ROOT/instalar-overcode-v2_5.sh" ]; then
  echo '[Overcode] Instalando/atualizando o motor de terminal v2.5 (SSH e comandos preservados)...'
  bash "$ROOT/instalar-overcode-v2_5.sh"
fi

command -v python3 >/dev/null 2>&1 || { echo '[Overcode] Python 3 não encontrado. Instale com: pkg install python  (Termux)'; exit 1; }
mkdir -p "$HOME/.overcode/hub/web" "$HOME/.overcode/hub/sessions" "$HOME/.overcode/plugins"
cp -f "$ROOT/hub/server.py" "$HOME/.overcode/hub/server.py"
cp -f "$ROOT/hub/web/index.html" "$HOME/.overcode/hub/web/index.html"
mkdir -p "$HOME/.overcode/hub/sdk/python" "$HOME/.overcode/hub/sdk/javascript"
cp -f "$ROOT/api/openapi.json" "$HOME/.overcode/hub/openapi.json"
cp -f "$ROOT/sdk/python/overcode.py" "$HOME/.overcode/hub/sdk/python/overcode.py"
cp -f "$ROOT/sdk/javascript/overcode.js" "$HOME/.overcode/hub/sdk/javascript/overcode.js"
chmod 700 "$HOME/.overcode/hub"
chmod 600 "$HOME/.overcode/hub/server.py" "$HOME/.overcode/hub/web/index.html"
chmod 600 "$HOME/.overcode/hub/openapi.json" "$HOME/.overcode/hub/sdk/python/overcode.py" "$HOME/.overcode/hub/sdk/javascript/overcode.js"

if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then BIN="$PREFIX/bin"; else BIN="$HOME/.local/bin"; mkdir -p "$BIN"; fi
cat > "$BIN/overcode-hub" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
BASE="$HOME/.overcode/hub"
PY="${PYTHON:-python3}"
PID="$BASE/hub.pid"
LOG="$BASE/hub.log"
case "${1:-start}" in
  start)
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
      echo "Overcode Hub já está rodando (PID $(cat "$PID")). http://127.0.0.1:8765"; exit 0
    fi
    mkdir -p "$BASE"
    nohup "$PY" "$BASE/server.py" --host 127.0.0.1 --port 8765 >>"$LOG" 2>&1 </dev/null &
    echo $! > "$PID"
    sleep 1
    if kill -0 "$(cat "$PID")" 2>/dev/null; then echo "Overcode Hub iniciado: http://127.0.0.1:8765"; echo "Log: $LOG"; else echo "Falha ao iniciar. Veja: $LOG"; exit 1; fi
    ;;
  open)
    if command -v termux-open-url >/dev/null 2>&1; then termux-open-url http://127.0.0.1:8765
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open http://127.0.0.1:8765
    else echo "Abra no navegador: http://127.0.0.1:8765"; fi
    ;;
  stop)
    if [ -f "$PID" ]; then kill "$(cat "$PID")" 2>/dev/null || true; rm -f "$PID"; echo 'Overcode Hub encerrado.'; else echo 'Overcode Hub não está rodando.'; fi
    ;;
  status)
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then echo "Rodando (PID $(cat "$PID")): http://127.0.0.1:8765"; else echo 'Parado.'; fi
    ;;
  lan)
    echo 'Abrindo acesso na rede local. O token será exibido abaixo. Não exponha a porta à internet.'
    exec "$PY" "$BASE/server.py" --host 0.0.0.0 --port 8765
    ;;
  foreground)
    exec "$PY" "$BASE/server.py" --host 127.0.0.1 --port 8765
    ;;
  *) echo 'Uso: overcode-hub {start|open|stop|status|lan|foreground}'; exit 2 ;;
esac
LAUNCHER
chmod +x "$BIN/overcode-hub"

python3 -m py_compile "$HOME/.overcode/hub/server.py"
rm -rf "$HOME/.overcode/hub/__pycache__"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Adicione ao PATH: export PATH=\"$BIN:\$PATH\"";; esac

echo
echo '[Overcode] Painel v2.6 instalado sem remover nem substituir os comandos do motor.'
echo '1. Abra `overcode` e escolha a IA em /model (e /apikey, se necessário).'
echo '2. Execute: overcode-hub start'
echo '3. Abra: overcode-hub open'
echo 'SSH e terminal continuam no motor e ficam recolhidos em Ferramentas avançadas no painel.'