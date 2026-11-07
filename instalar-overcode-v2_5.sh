#!/usr/bin/env bash
# Instalador do Overcode (tudo em um arquivo). Uso: bash instalar-overcode-v2_4.sh
say() { printf '\033[38;2;217;119;87m[Overcode]\033[0m %s\n' "$*"; }
erro() { printf '\033[1;31m[Overcode erro]\033[0m %s\n' "$*"; exit 1; }

if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ]; then BIN="$PREFIX/bin"; else BIN="$HOME/.local/bin"; mkdir -p "$BIN"; fi

if [ -z "$SEM_PKG" ] && command -v pkg >/dev/null 2>&1; then
  say "Instalando dependências (python, curl, llama-cpp)..."
  pkg install -y python curl llama-cpp || erro "Falha ao instalar pacotes. Rode: pkg update && pkg upgrade"
fi
command -v python3 >/dev/null 2>&1 || erro "python3 não encontrado."

# leva os dados da versão antiga (overIA Code) para o Overcode: modelos baixados, memória, coração da Kelly
if [ -d "$HOME/.overia" ] && [ ! -e "$HOME/.overcode" ]; then
  mv "$HOME/.overia" "$HOME/.overcode" && say "Seus dados da versão antiga foram migrados para ~/.overcode"
fi
mkdir -p "$HOME/.overcode/modelos" "$HOME/.overcode/skills"

say "Instalando o comando overcode em $BIN ..."
if [ -f "$BIN/overcode" ]; then
  cp -p "$BIN/overcode" "$BIN/overcode.bak" || erro "Não consegui criar backup da versão instalada."
  say "Backup da versão anterior: $BIN/overcode.bak"
fi
sed -n '/^#__OVERCODE_PY_INICIO__$/,$p' "$0" | sed '1d' > "$BIN/overcode"
chmod +x "$BIN/overcode"
python3 -m py_compile "$BIN/overcode" 2>/dev/null || erro "Arquivo instalado está inválido."
rm -rf "$BIN/__pycache__"

# quem usava o comando antigo continua conseguindo abrir
if [ -e "$BIN/overia-code" ]; then
  printf '#!/usr/bin/env bash\nexec overcode "$@"\n' > "$BIN/overia-code"
  chmod +x "$BIN/overia-code"
  say "O comando antigo overia-code agora abre o Overcode."
fi

if ! command -v llama-server >/dev/null 2>&1; then
  say "Aviso: llama-server não encontrado. Os modelos locais precisam dele (pkg install llama-cpp). As IAs da nuvem funcionam sem."
fi
case ":$PATH:" in *":$BIN:"*) ;; *) say "Aviso: adicione $BIN ao PATH (export PATH=\"$BIN:\$PATH\") para usar o comando overcode.";; esac
say "Versão instalada: $(grep -m1 '^VERSAO' "$BIN/overcode" | cut -d'"' -f2)"
say "Pronto! Digite: overcode"
say "Novidades v2.5: motor mais confiável, manual por relevância, /doctor, /rules e proteção ampliada para comandos destrutivos. Interface preservada."
exit 0
#__OVERCODE_PY_INICIO__
#!/usr/bin/env python3
# Overcode (antes overIA Code): agente de terminal estilo Claude Code, grátis, com IA local ou na nuvem.
# Só usa a biblioteca padrão do Python. Feito pro Termux, funciona em Linux também.
# v1.4: a Kelly ganhou coração (sentimentos que mudam, persistem e moldam o jeito dela agir).
# v1.5: Ctrl+C não derruba mais o motor da IA local; se ele cair, a Kelly religa sozinha.
# v1.6: a Kelly reconhece muito mais ofensas e reage na hora, sem depender da IA.
# v2.4: terminal de trabalho persistente com SSH (a Kelly executa de verdade), /terminal, /ssh, /parar, /manual (dicionário de
#       comandos), correção do modo plano, comando executado aparece em cinza claro.
# v2.3: mascote original com animações, caixas de plano com resumo, plano 1 digitável.
# v2.2: bichinho no canto do painel, 4 caixas de plano, sem mouse (teclado do Termux abre).
# v2.1: tela nova com painel fixo (planos, perguntas, bichinho), conversa rolável e terminal invisível.
# v2.0: virou Overcode: visual do Claude Code, memória/OVERCODE.md, /compact, /resume, /rewind, modo plano e autônomo,
#       categorias de IA com 'usar todas' e Ultra, chaves de API, tutorial com quiz e atualizador.
import os, sys, re, json, time, base64, random, shutil, subprocess, threading, select, urllib.request, urllib.error
import textwrap, unicodedata, difflib, hashlib, hmac, secrets, shlex, signal
try:
    import termios, tty
except Exception:
    termios = tty = None
try:
    import readline  # noqa: F401  (edição de linha no input)
except Exception:
    pass

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, ".overcode")
_ANTIGO = os.path.join(HOME, ".overia")
if os.path.isdir(_ANTIGO) and not os.path.exists(DIR):  # leva os dados da versão overIA Code
    try:
        os.rename(_ANTIGO, DIR)
    except OSError:
        pass
MODELOS = os.path.join(DIR, "modelos")
SKILLS = os.path.join(DIR, "skills")
LOG = os.path.join(DIR, "server.log")
ULTIMO = os.path.join(DIR, "ultimo-modelo")
IGNORAR = os.path.join(DIR, "ignorar-versao")
CHAVE = os.path.join(DIR, "gemini.key")
PORT = int(os.environ.get("OVERCODE_PORT", os.environ.get("OVERIA_PORT", "8081")))
os.makedirs(MODELOS, exist_ok=True)

_shared = os.path.join(HOME, "storage", "shared")
SEM_STORAGE = not os.path.isdir(_shared)
_pai = _shared if not SEM_STORAGE else HOME
BASE = os.path.join(_pai, "Overcode")
_base_antiga = os.path.join(_pai, "overIA Code")
if os.path.isdir(_base_antiga) and not os.path.exists(BASE):  # a pasta de projetos também muda de nome
    try:
        os.rename(_base_antiga, BASE)
    except OSError:
        pass
PATHS = {"FOTOS": os.path.join(BASE, "Fotos"), "VIDEOS": os.path.join(BASE, "Vídeos"),
         "ARQUIVOS": os.path.join(BASE, "Arquivos"), "ANEXOS": os.path.join(BASE, "Anexos")}
for _p in PATHS.values():
    try:
        os.makedirs(_p, exist_ok=True)
    except Exception:
        pass
ATUALIZ = os.path.join(BASE, "Atualizações")
try:
    os.makedirs(ATUALIZ, exist_ok=True)
except Exception:
    pass
ENV = dict(os.environ, **PATHS)
IMGS = (".png", ".jpg", ".jpeg", ".gif", ".webp")
TEXTOS = (".txt", ".md", ".py", ".sh", ".json", ".csv", ".html", ".js", ".log", ".yml", ".yaml", ".xml", ".conf")

# ---------- configuração do Overcode ----------
CONFIG = os.path.join(DIR, "config.json")
MEMORIA = os.path.join(DIR, "memoria.md")
SESSOES = os.path.join(DIR, "sessoes")
PROVEDORES_ARQ = os.path.join(DIR, "provedores.json")
APIKEYS = os.path.join(DIR, "apikeys.json")
os.makedirs(SESSOES, exist_ok=True)
os.makedirs(SKILLS, exist_ok=True)
CFG_PADRAO = {"modo": "normal", "auto_compact": True, "setup_feito": False, "ultimo_local": ""}


def _le_json(p, padrao):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return padrao


def _grava_json(p, dados, privado=False):
    try:
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(dados, f, ensure_ascii=False, indent=1)
        if privado:
            os.chmod(tmp, 0o600)
        os.replace(tmp, p)
        return True
    except Exception:
        return False


# o "modo" (normal/perguntar/plano/autonomo) vale só para a sessão: cada abertura começa em normal
CFG = dict(CFG_PADRAO, **{k: v for k, v in _le_json(CONFIG, {}).items() if k != "modo"})


def salva_cfg():
    _grava_json(CONFIG, {k: v for k, v in CFG.items() if k != "modo"})

# id, nome, repositório HuggingFace, arquivo, tamanho GB (aprox.), nível, contexto
CATALOGO = [
    ("1", "Llama 3.2 1B", "bartowski/Llama-3.2-1B-Instruct-GGUF", "Llama-3.2-1B-Instruct-Q4_K_M.gguf", 0.8, "Fraco", 4096),
    ("2", "Gemma 2 2B", "bartowski/gemma-2-2b-it-GGUF", "gemma-2-2b-it-Q4_K_M.gguf", 1.7, "Fraco", 4096),
    ("3", "Qwen2.5 Coder 1.5B", "bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF", "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf", 1.1, "Fraco", 4096),
    ("4", "Qwen2.5 3B", "bartowski/Qwen2.5-3B-Instruct-GGUF", "Qwen2.5-3B-Instruct-Q4_K_M.gguf", 2.0, "Médio", 4096),
    ("5", "Qwen2.5 Coder 3B", "bartowski/Qwen2.5-Coder-3B-Instruct-GGUF", "Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf", 2.1, "Médio", 4096),
    ("6", "Llama 3.2 3B", "bartowski/Llama-3.2-3B-Instruct-GGUF", "Llama-3.2-3B-Instruct-Q4_K_M.gguf", 2.0, "Médio", 4096),
    ("7", "Phi 3.5 mini", "bartowski/Phi-3.5-mini-instruct-GGUF", "Phi-3.5-mini-instruct-Q4_K_M.gguf", 2.4, "Médio", 4096),
    ("8", "Qwen2.5 7B", "bartowski/Qwen2.5-7B-Instruct-GGUF", "Qwen2.5-7B-Instruct-Q4_K_M.gguf", 4.4, "Forte", 3072),
    ("9", "Qwen2.5 Coder 7B", "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF", "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf", 4.7, "Forte", 3072),
    ("10", "Gemma 2 9B", "bartowski/gemma-2-9b-it-GGUF", "gemma-2-9b-it-Q4_K_M.gguf", 5.8, "Máximo", 3072),
]
GEMINI_MODELO = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")

# ---------- visual ----------
C = {"r": "\033[0m", "dim": "\033[90m", "ciano": "\033[1;36m", "verde": "\033[1;32m",
     "verm": "\033[1;31m", "amar": "\033[1;33m",
     "lar": "\033[38;2;217;119;87m", "neg": "\033[1m"}
PET = {"idle": "ʕ•ᴥ•ʔ", "feliz": "ʕ≧ᴥ≦ʔ", "erro": "ʕ;ᴥ;ʔ", "trab": "ʕ•ᴥ•ʔ🔧", "dorme": "ʕ-ᴥ-ʔ zZ"}
PENSAR = ["✻", "✽", "✶", "✳"]
MASCOTE = ["▐▛███▜▌", "▝▜█████▛▘", "  ▘▘ ▝▝"]
VERSAO = "2.5"
NOVIDADES = "v2.5: motor de agente mais confiável, respostas maiores, busca de manual por relevância, /doctor, /rules, detecção de arquivos de instruções AGENTS.md e proteção ampliada para comandos destrutivos. v2.4: terminal de trabalho com SSH (a Kelly executa de verdade), /terminal, /ssh, /parar, manual de comandos (/manual) e modo plano corrigido. Antes: Nova tela: painel fixo no topo (hora, humor, comandos, planos 1-4, bichinho), conversa que rola com a roda do mouse ou as setas, e a IA trabalha em um terminal invisível. Antes: agora se chama Overcode. Visual do Claude Code (caixa de boas-vindas, permissões, diff colorido); /model com categorias, usar todas e Ultra; memória (# e /memory), OVERCODE.md e /init; /compact, /context, /resume e /rewind; modo plano e modo autônomo; skills; chaves de API; tutorial com quiz."


def cor(c, t):
    return C[c] + t + C["r"]


VERBOS = ["Cozinhando", "Matutando", "Fermentando", "Tecendo", "Garimpando", "Costurando", "Destilando",
          "Encaixando", "Peneirando", "Alinhavando", "Pensando", "Burilando"]
C.update({"risc": "\033[9;90m", "fundo_verde": "\033[48;5;22m", "fundo_verm": "\033[48;5;52m"})


class Spinner:
    def __init__(self):
        self.ativo = False
        self.msg = ""
        self.t0 = 0.0

    def start(self, msg=None):
        if self.ativo:
            return
        self.msg = msg or random.choice(VERBOS)
        self.t0 = time.time()
        self.ativo = True
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        i = 0
        while self.ativo:
            seg = int(time.time() - self.t0)
            txt = cor("lar", PENSAR[i % 4] + " " + self.msg + "…") + cor("dim", f" ({seg}s · ctrl+c interrompe) " + cara())
            if T.on:
                T.status = txt
            else:
                sys.stdout.write("\r\033[2K" + txt)
                sys.stdout.flush()
            i += 1
            time.sleep(0.35)

    def stop(self):
        if self.ativo:
            self.ativo = False
            self.t.join(timeout=1)
            if T.on:
                T.status = ""
            else:
                sys.stdout.write("\r\033[2K")
                sys.stdout.flush()


# ---------- v2.1: tela com painel fixo no topo, conversa que rola e bichinho ----------
ANSI_RE = re.compile(r"(\x1b\[[0-9;?<]*[ -/]*[@-~])")
RST = "\033[0m"
C["rev"] = "\033[7m"


def _cw(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def larg(s):
    return sum(_cw(ch) for ch in ANSI_RE.sub("", s))


def corta(s, w):
    """corta o texto (com cores) para caber em w colunas"""
    if larg(s) <= w:
        return s
    out, n = "", 0
    for tk in ANSI_RE.split(s):
        if tk.startswith("\x1b["):
            out += tk
            continue
        for ch in tk:
            c = _cw(ch)
            if n + c > w:
                return out + RST
            out += ch
            n += c
    return out + RST


def pad(s, w, centro=False):
    s = corta(s, w)
    f = w - larg(s)
    if centro:
        return " " * (f // 2) + s + " " * (f - f // 2)
    return s + " " * f


def quebra(linha, w):
    """quebra uma linha (com cores) em linhas de no máximo w colunas, preferindo quebrar em espaços"""
    if larg(linha) <= w:
        return [linha]
    segs, cur, cw, ativo, sp, ativo_sp, viu = [], "", 0, "", None, "", False
    for tk in ANSI_RE.split(linha):
        if not tk:
            continue
        if tk.startswith("\x1b["):
            cur += tk
            if tk.endswith("m"):
                ativo = "" if tk in (RST, "\x1b[m") else ativo + tk
            continue
        for ch in tk:
            wc = _cw(ch)
            if cw + wc > w:
                if sp is not None:
                    segs.append(cur[:sp] + RST)
                    resto = cur[sp + 1:]
                    cur, cw = ativo_sp + resto, larg(resto)
                else:
                    segs.append(cur + RST)
                    cur, cw = ativo, 0
                sp = None
            cur += ch
            cw += wc
            if ch == " ":
                if viu:
                    sp, ativo_sp = len(cur) - 1, ativo
            else:
                viu = True
        # (viu continua valendo entre trechos)
    segs.append(cur)
    return segs


DESPEDE = re.compile(r"\b(tchau|xau|at[eé] (mais|logo|amanh[aã])|boa noite|vou dormir|flw|falou)\b", re.I)


def acha_tool(txt):
    t = unicodedata.normalize("NFD", txt.lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    if re.search(r"minecraft|\bmod\b|addon|bloco|mcaddon|jogo|game", t):
        return "⚒"
    if re.search(r"foto|imagem|desenh|video|camera|gato|cachorro|print", t):
        return "◉"
    if re.search(r"escrev|texto|arquivo|script|codigo|site|html|python|programa", t):
        return "✎"
    if re.search(r"baix|instal|download", t):
        return "⇩"
    return "⚙"


class Saida:
    encoding = "utf-8"
    errors = "replace"

    def __init__(self, t):
        self.t = t

    def write(self, txt):
        self.t.escreve(txt)
        return len(txt)

    def flush(self):
        pass

    def isatty(self):
        return True

    def fileno(self):
        return self.t.fd_out


class Tela:
    def __init__(self):
        self.on = False
        self.brutas, self.env, self.nb, self.larg_env = [], [], 0, 0
        self.parcial = ""
        self.off = 0
        self.lock = threading.RLock()
        self.rlock = threading.Lock()
        self.status = ""
        self.buf, self.cur, self.prompt, self.entrada = "", 0, "", False
        self.menu, self.dica, self.saida = None, "", "enter"
        self.planos, self.psel, self.exec = None, 1, False
        self.cbuf, self.ccur = "", 0
        self.trab, self.dorme, self.expr, self.tool = False, False, ("idle", 0), "⚙"
        self.quadro, self.pct = 0, 0
        self.hist, self.fila = [], bytearray()
        self.tam, self.ultimo = None, ""
        self.principal = False
        self.parou = False

    # ----- ligar / desligar -----
    def inicia(self):
        if self.on or not (termios and sys.stdin.isatty() and sys.stdout.isatty()):
            return False
        c, l = shutil.get_terminal_size((80, 24))
        if c < 40 or l < 14:
            return False
        self.fd, self.fd_out = sys.stdin.fileno(), sys.stdout.fileno()
        self.real = sys.stdout
        self.antigo = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        self.out("\x1b[?1049h\x1b[?1007h\x1b[2J")
        sys.stdout = Saida(self)
        self.on, self.parou = True, False
        threading.Thread(target=self._tick, daemon=True).start()
        self.desenha()
        return True

    def para(self):
        if not self.on:
            return
        self.on, self.parou = False, True
        try:
            sys.stdout = self.real
            self.out("\x1b[?1007l\x1b[?25h\x1b[?1049l")
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.antigo)
        except Exception:
            pass

    def out(self, s):
        b = s.encode("utf-8", "replace")
        while b:
            try:
                n = os.write(self.fd_out, b)
            except InterruptedError:
                continue
            except OSError:
                return
            b = b[n:]

    # ----- conversa (parte 6) -----
    def escreve(self, txt):
        with self.lock:
            txt = txt.replace("\r\n", "\n").replace("\t", "    ")
            txt = re.sub(r"\x1b\[(?:\d*[ABJK])", "", txt).replace("\r", "")
            partes = txt.split("\n")
            for i, p in enumerate(partes):
                self.parcial += p
                if i < len(partes) - 1:
                    self.brutas.append(self.parcial)
                    self.parcial = ""
            if len(self.brutas) > 4000:
                del self.brutas[:1000]
                self.nb, self.env, self.larg_env = 0, [], 0
            self.ultimo = ""

    def _sincroniza(self, w):
        if w != self.larg_env:
            self.env, self.nb, self.larg_env = [], 0, w
        antes = len(self.env)
        while self.nb < len(self.brutas):
            self.env += quebra(self.brutas[self.nb], w)
            self.nb += 1
        if self.off > 0:
            self.off += len(self.env) - antes  # mantém o que você está lendo no lugar

    def rola(self, n):
        self.off = max(0, self.off + n)

    # ----- teclas -----
    def _ler(self):
        try:
            d = os.read(self.fd, 4096)
        except InterruptedError:
            return
        if d:
            self.fila += d

    def _csi(self, seq):
        fin, par = chr(seq[-1]), seq[:-1].decode("ascii", "ignore")
        if par.startswith("<"):
            try:
                bt = int(par[1:].split(";")[0])
            except ValueError:
                return ""
            if fin == "M" and bt == 64:
                self.rola(3)
            elif fin == "M" and bt == 65:
                self.rola(-3)
            return ""
        if fin in "ABCDHF":
            return {"A": "up", "B": "down", "C": "right", "D": "left", "H": "home", "F": "end"}[fin]
        if fin == "Z":
            return "btab"
        if fin == "~":
            return {"1": "home", "7": "home", "4": "end", "8": "end", "3": "del", "5": "pgup", "6": "pgdn"}.get(par.split(";")[0], "")
        return ""

    def _analisa(self):
        f = self.fila
        if not f:
            return None
        b = f[0]
        if b == 0x1b:
            if len(f) == 1:
                return "ESC?"
            if f[1] == ord("["):
                i = 2
                while i < len(f) and not (0x40 <= f[i] <= 0x7e):
                    i += 1
                if i >= len(f):
                    return None
                seq = bytes(f[2:i + 1])
                del f[:i + 1]
                return self._csi(seq)
            if f[1] == ord("O"):
                if len(f) < 3:
                    return None
                ch = chr(f[2])
                del f[:3]
                return {"A": "up", "B": "down", "C": "right", "D": "left", "H": "home", "F": "end"}.get(ch, "")
            del f[:2]
            return ""
        if b >= 0x80:
            n = 2 if b >> 5 == 6 else 3 if b >> 4 == 14 else 4
            if len(f) < n:
                return None
            ch = bytes(f[:n]).decode("utf-8", "ignore")
            del f[:n]
            return ch
        del f[:1]
        return {13: "enter", 10: "enter", 127: "bs", 8: "bs", 9: "tab", 1: "ctrl-a", 5: "ctrl-e", 21: "ctrl-u",
                11: "ctrl-k", 4: "ctrl-d", 16: "ctrl-p", 14: "ctrl-n", 23: "ctrl-w", 12: "ctrl-l"}.get(b, chr(b) if b >= 32 else "")

    def tecla(self):
        """espera uma tecla. Roda do mouse e PgUp/PgDn rolam a conversa sozinhos."""
        with self.rlock:
            while True:
                k = self._analisa()
                if k == "ESC?":
                    if select.select([self.fd], [], [], 0.05)[0]:
                        self._ler()
                        continue
                    del self.fila[:1]
                    return "esc"
                if k is None:
                    if select.select([self.fd], [], [], 0.25)[0]:
                        self._ler()
                    continue
                if k == "":
                    self.desenha()
                    continue
                if k in ("pgup", "pgdn"):
                    self.rola((self.area - 1) * (1 if k == "pgup" else -1))
                    self.desenha()
                    continue
                if k == "ctrl-l":
                    self.tam = None
                    self.desenha()
                    continue
                return k

    def _drena(self):
        """enquanto a IA trabalha, ainda dá pra rolar a conversa"""
        if not self.rlock.acquire(False):
            return
        try:
            while select.select([self.fd], [], [], 0)[0]:
                self._ler()
                while True:
                    k = self._analisa()
                    if k is None or k == "ESC?":
                        break
                    if k in ("pgup", "pgdn"):
                        self.rola((self.area - 1) * (1 if k == "pgup" else -1))
                    elif k == "up":
                        self.rola(1)
                    elif k == "down":
                        self.rola(-1)
                if self.fila[:1] == b"\x1b" and len(self.fila) == 1:
                    del self.fila[:]
        finally:
            self.rlock.release()

    def _tick(self):
        while self.on:
            time.sleep(0.15)
            self.quadro += 1
            try:
                self._drena()
                self.desenha()
            except Exception:
                pass

    # ----- linha de entrada -----
    def le(self, prompt, principal=False):
        pr = prompt.replace("\001", "").replace("\002", "")
        self.prompt, self.buf, self.cur, self.entrada, self.principal = pr, "", 0, True, principal
        self.off = 0
        hi = len(self.hist)
        try:
            while True:
                self.desenha()
                k = self.tecla()
                if k == "enter":
                    break
                if k == "btab" and principal:
                    self.buf = "/mode"
                    break
                if k == "ctrl-d" and not self.buf:
                    raise EOFError
                b, c = self.buf, self.cur
                if k == "bs" and c > 0:
                    self.buf, self.cur = b[:c - 1] + b[c:], c - 1
                elif k == "del":
                    self.buf = b[:c] + b[c + 1:]
                elif k == "left":
                    self.cur = max(0, c - 1)
                elif k == "right":
                    self.cur = min(len(b), c + 1)
                elif k in ("home", "ctrl-a"):
                    self.cur = 0
                elif k in ("end", "ctrl-e"):
                    self.cur = len(b)
                elif k == "ctrl-u":
                    self.buf, self.cur = b[c:], 0
                elif k == "ctrl-k":
                    self.buf = b[:c]
                elif k == "ctrl-w":
                    n = len(b[:c].rstrip(" ").rsplit(" ", 1)[0]) + 1 if " " in b[:c].rstrip(" ") else 0
                    self.buf, self.cur = b[:n] + b[c:], n
                elif k == "up":
                    self.rola(1)
                elif k == "down":
                    self.rola(-1)
                elif k == "ctrl-p" and hi > 0:
                    hi -= 1
                    self.buf = self.hist[hi]
                    self.cur = len(self.buf)
                elif k == "ctrl-n":
                    hi = min(len(self.hist), hi + 1)
                    self.buf = self.hist[hi] if hi < len(self.hist) else ""
                    self.cur = len(self.buf)
                elif k == "tab" and b.startswith("/") and " " not in b:
                    ops = [n for n in NOMES_CMD if n.startswith(b)]
                    if len(ops) == 1:
                        self.buf = ops[0] + " "
                        self.cur = len(self.buf)
                    elif ops:
                        self.status = cor("dim", "  " + "  ".join(ops[:12]))
                elif len(k) == 1 and k >= " ":
                    self.buf, self.cur = b[:c] + k + b[c:], c + 1
            txt = self.buf
        finally:
            self.entrada = False
        self.escreve(pr + txt + "\n")
        self.status = ""
        if txt.strip() and principal:
            self.hist.append(txt)
        return txt

    # ----- menus e planos (aparecem no painel de cima) -----
    def escolhe(self, itens, titulo, dica, shift, tab, cancela):
        self.menu = {"t": titulo or "", "i": itens, "sel": 0}
        self.dica, self.saida = dica or "", "enter"
        try:
            while True:
                self.desenha()
                k, m = self.tecla(), self.menu
                if k in ("up", "k"):
                    m["sel"] = (m["sel"] - 1) % len(itens)
                elif k in ("down", "j"):
                    m["sel"] = (m["sel"] + 1) % len(itens)
                elif k == "btab" and shift is not None:
                    m["sel"], self.saida = shift, "shift"
                    break
                elif k == "esc" and cancela is not None:
                    m["sel"], self.saida = cancela, "esc"
                    break
                elif k == "tab" and tab is not None:
                    m["sel"], self.saida = tab, "tab"
                    break
                elif k == "enter":
                    break
                elif len(k) == 1 and k.isdigit() and 1 <= int(k) <= len(itens):
                    m["sel"] = int(k) - 1
                    break
        finally:
            sel = self.menu["sel"] if self.menu else 0
            self.menu, self.dica = None, ""
        print(cor("dim", f"  ❯ {itens[sel]}"))
        return sel

    def escolhe_plano(self):
        """caixa 1 = personalizado (é só digitar); caixas 2, 3 e 4 = planos da IA.
        ←/→ troca de caixa, enter executa, s executa sem perguntar (2-4), esc ajusta."""
        self.dica = "←/→ troca de caixa · enter executa · s executa sem perguntar mais · esc ajusta"
        self.cbuf, self.ccur = "", 0
        try:
            while True:
                self.desenha()
                k = self.tecla()
                ps = self.planos
                if k == "esc":
                    return "ajustar", None
                if self.psel == 0:
                    b, c = self.cbuf, self.ccur
                    if k == "enter":
                        passos = [p.strip()[:200] for p in re.split(r"[;\n]|\s+e depois\s+", b) if p.strip()][:8]
                        if passos:
                            return "exec", {"t": "Plano seu", "passos": passos}
                    elif k == "tab" or (k == "right" and c >= len(b)) or k == "down":
                        self.psel = 1
                    elif k == "bs" and c > 0:
                        self.cbuf, self.ccur = b[:c - 1] + b[c:], c - 1
                    elif k == "del":
                        self.cbuf = b[:c] + b[c + 1:]
                    elif k == "left":
                        self.ccur = max(0, c - 1)
                    elif k == "right":
                        self.ccur = min(len(b), c + 1)
                    elif k in ("home", "ctrl-a"):
                        self.ccur = 0
                    elif k in ("end", "ctrl-e"):
                        self.ccur = len(b)
                    elif k == "ctrl-u":
                        self.cbuf, self.ccur = b[c:], 0
                    elif len(k) == 1 and k >= " ":
                        self.cbuf, self.ccur = b[:c] + k + b[c:], c + 1
                else:
                    if k in ("left", "up"):
                        self.psel -= 1
                    elif k in ("right", "tab", "down"):
                        self.psel = min(3, self.psel + 1)
                    elif k in ("1", "2", "3", "4"):
                        self.psel = int(k) - 1
                    elif k in ("enter", "s") and ps[self.psel]:
                        return ("livre" if k == "s" else "exec"), ps[self.psel]
        finally:
            self.dica = ""

    # ----- desenho -----
    def sprite(self, n):
        """o mascote laranja do Claude Code (o mesmo do banner), só com animações. n = linhas (2, 3 ou 4)."""
        q = self.quadro // 3
        expr = self.expr[0] if self.expr[1] > time.time() else "idle"
        r1, r2, r3 = MASCOTE[0], MASCOTE[1], MASCOTE[2]
        topo, e1, e2, est = "", "", "", "lar"
        if self.trab and not self.menu:
            f = q % 2
            if f:
                r3 = "  ▝▝ ▘▘"
                e1 = " " + self.tool + "✦"
            else:
                e2 = " " + self.tool
        elif self.dorme:
            est = "dim"
            topo = ["z", "zZ", "zZz"][q % 3]
        elif self.menu:
            topo = "?"
        elif expr in ("feliz", "radiante", "orgulhosa"):
            e1 = " ✦"
        elif expr == "erro":
            topo = "!"
        pc = "dim" if self.dorme else "ciano"
        rows = [cor(est, r1) + cor(pc, e1), cor(est, r2) + cor(pc, e2), cor(est, r3)]
        rows = [" " + x if i != 1 else x for i, x in enumerate(rows)]
        rows = [pad(" " + x, 12) for x in rows]
        if n >= 4:
            return [pad("        " + cor("dim" if self.dorme else "ciano", topo), 12)] + rows
        if n == 3:
            if topo:
                rows[0] = pad(" " + cor(est, " " + r1) + " " + cor(pc, topo), 12)
            return rows
        return rows[1:]

    def caixas(self, c, alto):
        """as 4 caixas de plano: número + nome, e um mini resumo dentro. 1 = personalizado, 2-4 = da IA"""
        inner = c - 2
        bw = [inner // 4] * 4
        bw[3] += inner - sum(bw)
        ps = self.planos or [None, None, None, None]
        nlin = alto - 2
        linhas = [""] * alto
        for i in range(4):
            w = bw[i]
            sel = bool(self.planos) and i == self.psel
            est = "lar" if sel else "dim"
            num = cor("rev", f" {i + 1} ") if sel else cor("neg", f" {i + 1} ")
            if i == 0:
                nome = "Personalizado" if w >= 17 else "Meu"
            else:
                nome = ps[i]["t"] if ps[i] else ("—" if self.planos else "plano da IA")
            titulo = num + " " + cor("neg" if sel else "dim", nome)
            if i == 0:
                if sel:
                    txt = (self.cbuf[:self.ccur] + "▌" + self.cbuf[self.ccur:]) if self.cbuf or True else ""
                    if not self.cbuf:
                        txt = "▌ escreva o seu plano aqui"
                else:
                    txt = self.cbuf or "escreva o seu plano aqui"
            else:
                txt = (ps[i].get("d") or "; ".join(ps[i]["passos"])) if ps[i] else ""
            ls = quebra(txt, max(4, w - 4)) if txt else []
            ls = ls[-(nlin - 1):] if (i == 0 and sel) else ls[:nlin - 1]
            ls += [""] * (nlin - 1 - len(ls))
            cc = "ciano" if (i == 0 and sel) else ("neg" if sel else "dim")
            mid = [titulo] + [" " + cor(cc, x) for x in ls]
            cx = [cor(est, "╭" + "─" * (w - 2) + "╮")] + [cor(est, "│") + pad(x, w - 2) + cor(est, "│") for x in mid] + [cor(est, "╰" + "─" * (w - 2) + "╯")]
            for k in range(alto):
                linhas[k] += cx[k]
        return linhas

    def conteudo_planos(self, c, curto=False):
        """(linhas fixas, itens roláveis, seleção) da área de baixo das caixas"""
        m = self.menu
        if m:
            ls = [cor("neg", " " + m["t"][:c - 6])] if m["t"] else []
            it = []
            for n, t in enumerate(m["i"]):
                it.append(cor("lar", f" ❯ {n + 1}. {t}") if n == m["sel"] else cor("dim", f"   {n + 1}. {t}"))
            return ls, it, m["sel"]
        if self.planos and not (self.exec and E.todo):
            if self.psel == 0:
                b = self.cbuf
                passos = [p.strip() for p in re.split(r"[;\n]|\s+e depois\s+", b) if p.strip()]
                if not passos:
                    return [cor("dim", " Digite o seu plano na caixa 1. Separe os passos com ; e aperte enter.")], [], 0
                return [cor("neg", " Seu plano vai fazer:")], [cor("dim", f"   {i + 1}. ") + t[:c - 10] for i, t in enumerate(passos[:8])], 0
            p = self.planos[self.psel]
            if not p:
                return [cor("dim", " esse plano não veio; escolha outro")], [], 0
            ls = []
            if p.get("d"):
                ds = quebra(" " + p["d"], c - 4)
                ls = [cor("neg", x) for x in (ds[:1] if curto else ds[:2])]
            it = [cor("dim", f"   {i + 1}. ") + t for i, t in enumerate(p["passos"])]
            return ls, it, 0
        if E.todo:
            it = []
            for i, t in enumerate(E.todo):
                if i < E.feitos:
                    it.append(cor("verde", " ✓ ") + cor("risc", t))
                elif i == E.feitos:
                    it.append(cor("lar", " ● ") + cor("neg", t))
                else:
                    it.append(cor("dim", " ○ " + t))
            return [], it, E.feitos
        return [cor("dim", " Nenhum plano agora. /plan liga o modo plano (3 planos da IA + o seu).")], [], 0

    def monta_painel(self, c, l):
        nivel = 3 if (l >= 28 and c >= 50) else 2 if l >= 20 else 1   # 3 cheio, 2 médio, 1 micro
        inner = c - 2
        barra = cor("lar", "│")
        agora = time.strftime("%H:%M")
        humor = dominante()
        modo = cor(MODO_COR[CFG["modo"]] if CFG["modo"] != "normal" else "rosa", "⏵ " + MODO_NOME[CFG["modo"]])
        nb = {3: 4, 2: 3, 1: 2}[nivel]
        sp = self.sprite(nb)
        wm = inner - 12 - 1
        cmds = "  ".join(cor("dim", n) for n in ("/model", "/plan", "/resume", "/init", "/help"))
        if nivel == 3:
            mid = [cor("neg", " hora ") + agora + cor("dim", "  │  ") + cor("neg", "humor ") + cor("rosa", humor),
                   cor("neg", " comandos ") + cmds,
                   cor("neg", " IA ") + cor("dim", modelo_txt()),
                   " " + modo]
        elif nivel == 2:
            mid = [cor("neg", " ") + agora + cor("dim", " │ ") + cor("rosa", humor) + cor("dim", " │ ") + modo,
                   " " + cmds,
                   cor("dim", " " + modelo_txt())]
        else:
            mid = [cor("neg", " ") + agora + cor("dim", " │ ") + cor("rosa", humor) + cor("dim", " │ ") + modo,
                   " " + cmds]
        bloco = [barra + sp[i] + barra + pad(mid[i], wm) + barra for i in range(nb)]
        bh = {3: 5, 2: 4, 1: 1}[nivel]
        ch_min = {3: 3, 2: 2, 1: 1}[nivel]
        em_menu = bool(self.menu)
        ls, it, sel = self.conteudo_planos(c, curto=nivel < 3)
        fixo = 1 + nb + 1 + (0 if em_menu else bh) + 1
        cap = max(ch_min, l - 7 - fixo)
        ch = max(ch_min, min(len(ls) + len(it), cap))
        if len(ls) + len(it) > ch:
            disp = max(1, ch - len(ls))
            ini = min(max(0, sel - disp + 1), max(0, len(it) - disp))
            it = it[ini:ini + disp]
        corpo = (ls + it)[:ch]
        corpo += [""] * (ch - len(corpo))
        if em_menu:
            cab = cor("lar", "├─ ") + cor("neg", "PERGUNTA ") + cor("dim", "(números, setas e enter) ")
        else:
            cab = cor("lar", "├─ ") + cor("neg", "PLANOS ") + (cor("dim", "(1 = o seu · 2, 3, 4 = da IA · ←/→ escolhe) ") if c >= 76 else "")
        cab = corta(cab, c - 1)
        cab += cor("lar", "─" * max(0, c - 1 - larg(cab))) + cor("lar", "┤")
        topo = " Overcode v%s " % VERSAO
        t0 = cor("lar", "╭─" + topo + "─" * max(0, c - 3 - len(topo)) + "╮")
        fim = cor("lar", "╰" + "─" * inner + "╯")
        mid_l = []
        if not em_menu:
            if nivel == 1:
                tabs = ""
                for i in range(4):
                    ok = bool(self.planos and self.planos[i])
                    nome = (self.planos[i]["t"][:10] if ok else ("✎" if i == 0 else "—")) if self.planos else ("✎" if i == 0 else "·")
                    rot = f" {i + 1} {nome} "
                    tabs += cor("rev", rot) if (self.planos and i == self.psel) else cor("lar" if ok else "dim", rot)
                mid_l = [barra + pad(tabs, inner) + barra]
            else:
                mid_l = [barra + x + barra for x in self.caixas(c, bh)]
        return [t0] + bloco + [pad(cab, c)] + mid_l + [barra + pad(x, inner) + barra for x in corpo] + [fim]

    def desenha(self):
        with self.lock:
            if not self.on:
                return
            c, l = shutil.get_terminal_size((80, 24))
            saida = []
            if (c, l) != self.tam:
                saida.append("\x1b[2J")
                self.tam = (c, l)
            painel = self.monta_painel(c, l)
            P = len(painel)
            area = max(1, l - P - 2)
            self.area = area
            self._sincroniza(max(10, c - 1))
            todas = self.env + (quebra(self.parcial, max(10, c - 1)) if self.parcial else [])
            self.off = min(self.off, max(0, len(todas) - area))
            fim = len(todas) - self.off
            vis = todas[max(0, fim - area):fim]
            vis = [""] * (area - len(vis)) + vis
            saida.append("\x1b[?25l")
            for i, ln in enumerate(painel):
                saida.append(f"\x1b[{i + 1};1H" + pad(ln, c) + RST)
            for i, ln in enumerate(vis):
                saida.append(f"\x1b[{P + 1 + i};1H" + pad(ln, c) + RST)
            if self.status:
                st = self.status
            elif self.off > 0:
                st = cor("amar", " ↓ lendo mensagens antigas") + cor("dim", " (PgDn ou roda pra baixo volta ao fim)")
            elif self.dica:
                st = cor("dim", " " + self.dica)
            else:
                st = cor("dim", f" {MODO_NOME[CFG['modo']]} · ctx {self.pct}% · roda do mouse/PgUp rola · shift+tab troca de modo")
            saida.append(f"\x1b[{l - 1};1H" + pad(st, c) + RST)
            pr = self.prompt if self.entrada else ""
            if self.entrada:
                pw = larg(pr)
                espaco = max(4, c - pw - 1)
                b, cu = self.buf, self.cur
                ini = max(0, cu - espaco + 1) if cu >= espaco else 0
                vis_b = b[ini:ini + espaco]
                saida.append(f"\x1b[{l};1H" + pad(pr + vis_b, c) + RST)
                saida.append(f"\x1b[{l};{pw + 1 + larg(b[ini:cu])}H\x1b[?25h")
            else:
                saida.append(f"\x1b[{l};1H" + " " * (c - 1))
            quadro = "".join(saida)
            if quadro != self.ultimo:
                self.ultimo = quadro
                self.out(quadro)


T = Tela()
import builtins
_input_orig = builtins.input


def _input_tui(prompt=""):
    if T.on:
        return T.le(prompt)
    return _input_orig(prompt)


builtins.input = _input_tui


def mostra_resposta(texto):
    """mostra só a conversa: sem bloco de comando, sem a pergunta (ela vai pro painel)"""
    t = re.sub(r"(?m)^\s*MANUAL:.*$", "", texto)
    if extrai_pergunta(t):
        t = re.sub(r"(?s)PERGUNTA:.*", "", t)
    cmd = extrai_cmd(t)
    if cmd == CORTADO:
        t = t.split("```")[0]
    elif cmd is not None:
        t = re.sub(r"(?s)```(?:bash|sh|shell)?\n.*?```", "", t)
    t = t.strip()
    if t:
        print(cor("lar", "● ") + t)


PEDE_PLANOS = ("\n\n[Responda com 3 planos DIFERENTES para isso, neste formato exato:\nPLANO 1: título curto\nO que faz: uma frase explicando\n1. passo\n2. passo\n"
               "PLANO 2: título curto\nO que faz: uma frase\n1. passo\n2. passo\nPLANO 3: título curto\nO que faz: uma frase\n1. passo\n2. passo\n"
               "Cada plano com 3 a 6 passos curtos. Não escreva bloco bash e não execute nada.]")


def extrai_planos(resp):
    partes = re.split(r"(?im)^\W*plano\s*(\d)\s*[:\-.)]*\s*", resp)
    planos = []
    for i in range(1, len(partes) - 1, 2):
        corpo = partes[i + 1].strip().splitlines()
        if not corpo:
            continue
        titulo = re.sub(r"\*+", "", corpo[0]).strip()
        expl = ""
        for x in corpo[1:]:
            mm = re.match(r"^\W*(?:o que faz|explica\w*|resumo)\s*[:\-]\s*(.+)$", x, re.I)
            if mm:
                expl = re.sub(r"\*+", "", mm.group(1)).strip()[:160]
                break
        passos = [re.sub(r"\*+", "", m.group(1)).strip()[:80] for m in
                  (re.match(r"^\s*(?:\d+[.)]|[-*•])\s+(.+)$", x) for x in corpo[1:]) if m]
        if not passos and re.match(r"^\d+[.)]\s", corpo[0]):
            passos = [m.group(1).strip()[:80] for m in (re.match(r"^\s*\d+[.)]\s+(.+)$", x) for x in corpo) if m]
            titulo = "Plano " + partes[i]
        if passos:
            planos.append({"t": (titulo or "Plano " + partes[i])[:30], "passos": passos[:7], "d": expl})
    if not planos:
        ps = extrai_passos(resp)
        if ps:
            planos = [{"t": "Plano da Kelly", "passos": ps}]
    return planos[:3]


def turno_plano_tui(entrada, img=None):
    E.pendente = entrada
    ponto_de_retorno(entrada)
    extra = conselho(entrada) if E.grupo else ""
    msg = {"role": "user", "content": entrada + extra + PEDE_PLANOS}
    if img:
        msg["img"] = img
    E.historia.append(msg)
    idx = len(E.historia) - 1
    T.trab = True
    try:
        resp = gera(monta_mensagens(), mostrar=False)
    finally:
        T.trab = False
    E.historia[idx]["content"] = entrada
    if resp is None:
        E.historia.pop()
        return
    E.historia.append({"role": "assistant", "content": resp})
    salva_sessao()
    planos = extrai_planos(resp)
    if not planos:
        mostra_resposta(resp)
        return
    print(cor("lar", "● ") + "Montei " + ("%d planos" % len(planos) if len(planos) > 1 else "um plano") + " lá em cima. Escolha um (ou escreva o seu no 1).")
    T.planos = [None] + (planos + [None, None, None])[:3]
    T.psel = 1
    try:
        esc, plano = T.escolhe_plano()
    except BaseException:
        T.planos = None
        raise
    if esc == "ajustar":
        T.planos = None
        novo = input(cor("lar", "  o que mudar no plano? > ")).strip()
        if novo:
            turno_plano(novo)
        return
    E.historia[-1] = {"role": "assistant", "content": "Plano escolhido:\n" + "\n".join(f"{i + 1}. {p}" for i, p in enumerate(plano["passos"]))}
    E.todo, E.feitos = list(plano["passos"]), 0
    CFG["modo"] = "normal"
    E.pendente, E.nota = "", ""
    E.liberado = esc == "livre"
    print(cor(MODO_COR["normal"], " ⏵ saí do modo plano") + cor("dim", " — executando: " + plano["t"]))
    T.trab, T.exec = True, True
    try:
        _turno_core(msg_aprovado(entrada))
    finally:
        T.trab, T.exec, T.planos = False, False, None
        fim_todo()
        salva_sessao()



def menu(titulo, opcoes, permitir_outro=True, shift=None, tab=None, cancela=None, dica=None):
    """Menu com setas ↑/↓ + Enter (ou o número). shift/tab/cancela = índice escolhido por Shift+Tab, Tab e Esc.
    Depois da escolha, menu.tecla diz como saiu: enter, shift, tab ou esc."""
    itens = list(opcoes) + (["Digitar outra resposta…"] if permitir_outro else [])
    cols = shutil.get_terminal_size((50, 20)).columns
    itens = [t[:cols - 8] for t in itens]
    menu.tecla = "enter"
    if titulo:
        print(cor("lar", "● ") + cor("neg", titulo))
    if dica and not T.on:
        print(cor("dim", "  " + dica))
    fd = sys.stdin.fileno() if sys.stdin.isatty() and termios else None
    if T.on:
        sel = T.escolhe(itens, titulo, dica, shift, tab, cancela)
        menu.tecla = T.saida
    elif fd is None:  # sem terminal interativo: lista numerada
        for n, t in enumerate(itens, 1):
            print(f"  {n}. {t}")
        try:
            sel = int(input("número > ")) - 1
        except Exception:
            sel = 0
        sel = min(max(sel, 0), len(itens) - 1)
    else:
        sel = 0

        def desenha(primeira):
            if not primeira:
                sys.stdout.write(f"\033[{len(itens)}A")
            for n, t in enumerate(itens):
                if n == sel:
                    linha = cor("lar", f" ❯ {n + 1}. {t}")
                else:
                    linha = cor("dim", f"   {n + 1}. {t}")
                sys.stdout.write("\033[2K\r" + linha + "\n")
            sys.stdout.flush()

        antigo = termios.tcgetattr(fd)
        try:
            tty.setcbreak(fd)
            desenha(True)
            while True:
                ch = os.read(fd, 1)
                if ch == b"\x1b":
                    seq = b""
                    while select.select([fd], [], [], 0.05)[0] and len(seq) < 2:
                        seq += os.read(fd, 1)
                    if seq in (b"[A", b"OA"):
                        sel = (sel - 1) % len(itens)
                    elif seq in (b"[B", b"OB"):
                        sel = (sel + 1) % len(itens)
                    elif seq == b"[Z" and shift is not None:
                        sel, menu.tecla = shift, "shift"
                        desenha(False)
                        break
                    elif seq == b"" and cancela is not None:
                        sel, menu.tecla = cancela, "esc"
                        desenha(False)
                        break
                elif ch == b"\t" and tab is not None:
                    sel, menu.tecla = tab, "tab"
                    desenha(False)
                    break
                elif ch in (b"k",):
                    sel = (sel - 1) % len(itens)
                elif ch in (b"j",):
                    sel = (sel + 1) % len(itens)
                elif ch in (b"\r", b"\n"):
                    break
                elif ch.isdigit() and 1 <= int(ch) <= len(itens):
                    sel = int(ch) - 1
                    desenha(False)
                    break
                desenha(False)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, antigo)
    if permitir_outro and sel == len(itens) - 1:
        return input(cor("lar", "  sua resposta > ")).strip()
    return itens[sel]


menu.tecla = "enter"

# ---------- modos de permissão (Shift+Tab alterna) ----------
MODOS = ["normal", "perguntar", "plano", "autonomo"]
MODO_NOME = {"normal": "modo normal", "perguntar": "perguntando tudo", "plano": "modo plano",
             "autonomo": "modo autônomo"}
MODO_COR = {"normal": "dim", "perguntar": "amar", "plano": "ciano", "autonomo": "verde"}
MODO_DESC = {"normal": "executa sozinho; pergunta só ao instalar ou apagar coisas",
             "perguntar": "pergunta antes de TODO comando",
             "plano": "só monta um plano; você aprova antes de qualquer ação",
             "autonomo": "executa tudo sem perguntar (só avisa antes de apagar)"}


def uso_contexto():
    """(tokens do sistema, tokens da conversa, limite, porcentagem)"""
    ctx = E.backend["ctx"] if E.backend else 4096
    sis = tokens(prompt_sistema())
    msgs = sum(tokens(m["content"]) for m in E.historia if isinstance(m["content"], str))
    return sis, msgs, ctx, min(100, int((sis + msgs) * 100 / max(ctx, 1)))


# ---------- caixa de boas-vindas ----------
def envolve(txt, larg):
    return textwrap.wrap(txt, max(8, larg)) or [""]


def _cel(t, c, larg, centro=True):
    t = t[:larg]
    sobra = larg - len(t)
    esq = sobra // 2 if centro else 0
    txt = " " * esq + t + " " * (sobra - esq)
    return cor(c, txt) if c else txt


def caixa(titulo, esq, dire, w):
    """Caixa laranja de uma ou duas colunas. esq/dire: listas de (texto, cor)."""
    dentro = w - 2
    barra = cor("lar", "│")
    out = [cor("lar", "╭─" + titulo + "─" * max(0, w - 3 - len(titulo)) + "╮")]
    if dire:
        le = (dentro - 1) * 45 // 100
        ld = dentro - 1 - le
        for i in range(max(len(esq), len(dire))):
            a = esq[i] if i < len(esq) else ("", None)
            b = dire[i] if i < len(dire) else ("", None)
            out.append(barra + _cel(a[0], a[1], le) + barra + _cel(b[0], b[1], ld, centro=False) + barra)
    else:
        for a in esq:
            out.append(barra + _cel(a[0], a[1], dentro) + barra)
    out.append(cor("lar", "╰" + "─" * dentro + "╯"))
    return out


def modelo_txt():
    if E.grupo:
        return f"{E.grupo['nome']} · conselho de {len(E.grupo['membros'])}"
    if E.backend:
        return f"{E.backend['nome']} · {E.backend['nivel']}"
    return "sem IA"


def banner():
    cols = shutil.get_terminal_size((60, 20)).columns
    duas = cols >= 76
    w = max(34, min(cols - 1, 96 if duas else 50))
    dentro = w - 2
    le = (dentro - 1) * 45 // 100 if duas else dentro
    ld = dentro - 1 - le
    esq = [(saudacao_banner(), "neg"), ("", None)] + [(l, "lar") for l in MASCOTE] + [("", None)]
    esq.append((f"Kelly está {dominante()} {cara()}", "rosa"))
    esq.append((modelo_txt(), "dim"))
    pasta = E.cwd.replace(HOME, "~", 1)
    esq.append((("…" + pasta[-(le - 3):]) if len(pasta) > le - 2 else pasta, "dim"))
    dire = []
    if duas:
        dire.append((" Dicas para começar", "lar"))
        for t in ("Rode /init para criar um OVERCODE.md com as regras deste projeto.",
                  "Use # para guardar algo na memória e @arquivo para citar arquivos.",
                  "Digite / para ver todos os comandos."):
            dire += [(" " + l, None) for l in envolve(t, ld - 2)]
        dire += [("", None), (" Atividade recente", "lar")]
        recentes = lista_sessoes()[:3]
        if recentes:
            for s in recentes:
                dire.append((" " + atras(s["mtime"]) + " · " + s["titulo"], "dim"))
        else:
            dire.append((" Nenhuma atividade recente", "dim"))
    for l in caixa(f" Overcode v{VERSAO} ", esq, dire, w):
        print(l)
    if not duas:
        print(cor("dim", " /init · /model · /resume · /help"))
    print(cor("dim", " Projetos: " + BASE.replace(HOME, "~", 1)))
    print(cor(MODO_COR[CFG["modo"]], " ⏵ " + MODO_NOME[CFG["modo"]]) + cor("dim", " (shift+tab ou /mode alterna)"))
    if SEM_STORAGE:
        print(cor("amar", " ⚠ Rode termux-setup-storage para ver as pastas no celular."))


def le_entrada():
    cols = shutil.get_terminal_size((50, 20)).columns
    tick()
    humor = dominante()
    try:
        pct = uso_contexto()[3] if E.backend else 0
    except Exception:
        pct = 0
    if T.on:
        T.pct = pct
        return T.le(cor("lar", "❯ "), principal=True).strip()
    rot = f" {MODO_NOME[CFG['modo']]} · ctx {pct}% · {PET[humor]} "
    print("\n" + cor("dim", "─" * max(4, cols - 1 - len(rot))) + cor(MODO_COR[CFG["modo"]] if CFG["modo"] != "normal" else "rosa", rot))
    txt = input("\001" + C["lar"] + "\002❯ \001" + C["r"] + "\002").strip()
    print(cor("dim", "─" * (cols - 1)))
    return txt


def _prepara_readline(nomes):
    try:
        import readline as rl
    except Exception:
        return

    def completa(texto, estado):
        if not texto.startswith("/"):
            return None
        ops = [c for c in nomes if c.startswith(texto)]
        return ops[estado] if estado < len(ops) else None

    try:
        rl.set_completer(completa)
        rl.set_completer_delims(" \t\n")
        if "libedit" in (rl.__doc__ or ""):
            rl.parse_and_bind("bind ^I rl_complete")
        else:
            rl.parse_and_bind("tab: complete")
            rl.parse_and_bind(r'"\e[Z": "\C-a\C-k/mode\C-m"')  # Shift+Tab troca de modo
    except Exception:
        pass


spin = Spinner()


def fala(estado, texto):
    T.expr = (estado, time.time() + 8)
    face = cara() if estado == "idle" else PET.get(estado, PET["idle"])
    print(cor("ciano", face) + " " + texto)


# ---------- estado ----------
class Estado:
    backend = None      # dict: nome, url, modelo, chave, ctx, gemma
    servidor = None     # processo do llama-server
    historia = []
    cwd = os.getcwd()
    auto_instala = False
    loop = False
    forca = 0
    modelo = None   # modelo local carregado (para religar o motor se ele cair)


E = Estado()
E.liberado, E.grupo, E.sessao_id = False, None, ""
E.checkpoints, E.todo, E.feitos, E.uso_in, E.uso_out = [], [], 0, 0, 0
E.nota, E.pendente = "", ""


# ---------- coração: os sentimentos da Kelly ----------
# Sistema de emoções persistente (~/.overcode/coracao.json). Os sentimentos mudam com o que acontece
# (acertos, erros, elogios, grosserias, tempo longe, hora do dia), voltam ao normal com o passar do
# tempo de verdade e moldam o jeito dela agir: no rosto, nas frases e no prompt enviado à IA.
CORACAO = os.path.join(DIR, "coracao.json")
C.update({"azul": "\033[1;34m", "rosa": "\033[38;2;255;130;170m", "mag": "\033[1;35m"})
PET.update({"tranquila": "ʕ•ᴥ•ʔ", "radiante": "ʕ≧ᴥ≦ʔ♡", "orgulhosa": "ʕ◕ᴥ◕ʔ✧", "curiosa": "ʕ°ᴥ°ʔ?",
            "carinhosa": "ʕ♡ᴥ♡ʔ", "frustrada": "ʕ>ᴥ<ʔ", "triste": "ʕ╥ᴥ╥ʔ", "saudosa": "ʕ˘ᴥ˘ʔ♡",
            "sonolenta": "ʕ-ᴥ-ʔ zZ"})

# nome: (valor de repouso, rótulo, cor da barra)
EMOCOES = {
    "alegria": (55, "alegria", "verde"),
    "carinho": (40, "carinho", "rosa"),
    "orgulho": (30, "orgulho", "amar"),
    "curiosidade": (50, "curiosidade", "ciano"),
    "frustracao": (10, "frustração", "verm"),
    "tristeza": (10, "tristeza", "azul"),
    "saudade": (5, "saudade", "mag"),
    "energia": (85, "energia", "lar"),
}
ORDEM = list(EMOCOES)
# meia-vida (segundos): em quanto tempo o sentimento volta metade do caminho ao repouso
MEIA = {"alegria": 1800, "carinho": 21600, "orgulho": 1200, "curiosidade": 900,
        "frustracao": 600, "tristeza": 2400, "saudade": 1200, "energia": 3600}

# o que cada acontecimento muda no coração
EVENTOS = {
    "sucesso":    {"alegria": 6, "orgulho": 5, "frustracao": -10, "energia": -1.5, "curiosidade": 2},
    "falha":      {"frustracao": 14, "alegria": -6, "orgulho": -4, "energia": -2},
    "criou":      {"orgulho": 16, "alegria": 9, "energia": -2},
    "elogio":     {"alegria": 18, "carinho": 10, "orgulho": 12, "tristeza": -15, "frustracao": -12},
    "grosseria":  {"tristeza": 40, "alegria": -18, "carinho": -6, "frustracao": 6},
    "triste":     {"carinho": 10, "tristeza": 12, "alegria": -8},
    "negado":     {"curiosidade": 4, "orgulho": -2},
    "confusa":    {"frustracao": 12, "orgulho": -10, "tristeza": 5},
    "reencontro": {"alegria": 22, "carinho": 6, "saudade": -50},
    "novidade":   {"curiosidade": 16, "alegria": 5},
    "conversa":   {"carinho": 1.2, "energia": -0.8},
}
GANHO = {"elogio": 1.5, "criou": 0.5, "sucesso": 0.15, "conversa": 0.1, "grosseria": -1.0}  # vínculo
NIVEIS = [(0, "Desconhecidos"), (5, "Conhecidos"), (15, "Colegas de código"), (35, "Amigos"),
          (60, "Melhores amigos"), (85, "Dupla inseparável")]

ELOGIO = re.compile(r"\b(obrigad[oa]|brigad[oa]|valeu|vlw|muito bom|[oó]timo|perfeito|incr[ií]vel|genial|"
                    r"parab[eé]ns|amei|adorei|gostei|te amo|voc[eê] [eé] demais|que legal|boa kelly|"
                    r"mandou bem|arrasou)\b", re.I)
NEGA = re.compile(r"\b(n[aã]o|nunca|jamais)\s+(\w+\s+)?(gostei|amei|adorei|[oó]timo|perfeito|incr[ií]vel|genial|legal)", re.I)
# ofensas que valem quando a frase fala com ela ("você é feia", "Kelly chata")
GROSSA_PALAVRA = re.compile(r"\b(fei[ao]s?|feios[ao]|chat[ao]s?|chatinh[ao]|ridícul[ao]|horr[ií]vel|horroros[ao]|"
                            r"nojent[ao]|trouxa|ot[aá]ri[ao]|babaca|tont[ao]|best[ao]|burr[ao]|burrinh[ao]|"
                            r"idiota|imbecil|in[uú]til|est[uú]pid[ao]|lixo|p[eé]ssim[ao]|ruim|fraca|gord[ao])\b", re.I)
# xingamentos que, numa frase curta, só podem ser com ela (sem precisar dizer "você")
GROSSA_SOLTA = re.compile(r"\b(trouxa|ot[aá]ri[ao]|babaca|tont[ao]|burr[ao]|burrinh[ao]|idiota|imbecil|"
                          r"in[uú]til|est[uú]pid[ao]|nojent[ao]|ridícul[ao])\b", re.I)
GROSSA_ALVO = re.compile(r"\b(voc[eê]|vc|tu|kelly|(essa|sua|a) ia)\b", re.I)
GROSSA_FRASE = re.compile(r"cala a boca|te odeio|odeio (voc[eê]|vc)", re.I)
TRISTE = re.compile(r"\b(triste|chorando|chorei|deprimid[oa]|sozinh[oa]|cansad[oa]|estressad[oa]|ansios[oa]|"
                    r"desanimad[oa]|n[aã]o aguento|mal hoje|me sentindo mal)\b", re.I)
CRISE = re.compile(r"quero morrer|queria morrer|vou me matar|me matar\b|suic[ií]d|n[aã]o quero (mais )?viver|"
                   r"me machucar|me cortar", re.I)

_t0 = time.time()
_saud_ini = 0.0
_primeira = False
_ultima_fim = ""


def novo_coracao():
    return {"nome": "", "perguntou": False, "criada": time.time(), "visto": time.time(),
            "sessoes": 0, "vinculo": 0.0, "feitos": 0, "elogios": 0, "falhas": 0,
            "e": {n: float(v[0]) for n, v in EMOCOES.items()}, "diario": []}


def carrega_coracao():
    k = novo_coracao()
    try:
        with open(CORACAO, encoding="utf-8") as f:
            d = json.load(f)
        k["nome"] = str(d.get("nome", ""))[:24]
        k["perguntou"] = bool(d.get("perguntou", False))
        for chave in ("criada", "visto", "vinculo"):
            k[chave] = float(d.get(chave, k[chave]))
        for chave in ("sessoes", "feitos", "elogios", "falhas"):
            k[chave] = int(d.get(chave, 0))
        for nome, v in d.get("e", {}).items():
            if nome in EMOCOES:
                k["e"][nome] = min(100.0, max(0.0, float(v)))
        k["diario"] = [[float(t), str(x)] for t, x in d.get("diario", [])][-40:]
    except Exception:
        pass
    return k


def salva_coracao():
    try:
        K["visto"] = time.time()
        copia = dict(K)
        copia["e"] = {n: round(v, 1) for n, v in K["e"].items()}
        copia["vinculo"] = round(K["vinculo"], 2)
        tmp = CORACAO + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(copia, f, ensure_ascii=False, indent=1)
        os.replace(tmp, CORACAO)
    except Exception:
        pass


def base_de(nome):
    b = float(EMOCOES[nome][0])
    if nome == "carinho":
        b += K["vinculo"] * 0.4  # quanto mais vínculo, mais carinho de repouso
    elif nome == "energia":
        h = time.localtime().tm_hour  # de madrugada o repouso é de sono
        b = 28 if h < 5 else 55 if h < 7 else 40 if h >= 23 else 65 if h >= 21 else 85
    return b


def passa_tempo(dt):
    for nome in EMOCOES:
        b = base_de(nome)
        K["e"][nome] = b + (K["e"][nome] - b) * 0.5 ** (dt / MEIA[nome])


def tick():
    global _t0
    agora = time.time()
    dt = agora - _t0
    _t0 = agora
    if dt > 0.5:
        passa_tempo(dt)


def sente(ev, motivo=None):
    tick()
    for nome, d in EVENTOS.get(ev, {}).items():
        K["e"][nome] = min(100.0, max(0.0, K["e"][nome] + d))
    if ev in GANHO:
        K["vinculo"] = min(100.0, max(0.0, K["vinculo"] + GANHO[ev]))
    if ev == "sucesso":
        K["feitos"] += 1
    elif ev == "elogio":
        K["elogios"] += 1
    elif ev == "falha":
        K["falhas"] += 1
    if motivo:
        K["diario"].append([time.time(), motivo])
        del K["diario"][:-40]
    salva_coracao()


def dominante():
    e = K["e"]
    if e["frustracao"] >= 55:
        return "frustrada"
    if e["tristeza"] >= 35:
        return "triste"
    if e["saudade"] >= 60:
        return "saudosa"
    if e["orgulho"] >= 60:
        return "orgulhosa"
    if e["alegria"] >= 80:
        return "radiante"
    if e["energia"] <= 30:
        return "sonolenta"
    if e["alegria"] >= 65:
        return "feliz"
    if e["curiosidade"] >= 65:
        return "curiosa"
    if e["carinho"] >= 60:
        return "carinhosa"
    return "tranquila"


def cara():
    return PET.get(dominante(), PET["idle"])


def nivel_vinculo():
    return [n for n in NIVEIS if K["vinculo"] >= n[0]][-1][1]


def tempo_extenso(s):
    m = int(s // 60)
    if m < 2:
        return "um instante"
    if m < 60:
        return f"{m} minutos"
    h = m // 60
    if h < 24:
        return f"{h} hora" + ("s" if h > 1 else "")
    d = h // 24
    return f"{d} dia" + ("s" if d > 1 else "")


def atras(t):
    s = max(0, time.time() - t)
    return "agora" if s < 90 else "há " + tempo_extenso(s)


def forca_txt(v):
    return "forte" if v >= 75 else "média" if v >= 55 else "leve"


LIMIAR = {"alegria": 60, "carinho": 55, "orgulho": 45, "curiosidade": 60, "frustracao": 35,
          "tristeza": 35, "saudade": 40}


def texto_emocao():
    """Trecho do prompt do sistema: conta à IA como a Kelly está se sentindo agora."""
    tick()
    e = K["e"]
    sent = sorted(((e[n], n) for n in LIMIAR if e[n] >= LIMIAR[n]), reverse=True)[:3]
    lista = ", ".join(EMOCOES[n][1] + " " + forca_txt(v) for v, n in sent) or "calma"
    s = (" SENTIMENTOS: você tem um sistema de emoções que muda com o que acontece e molda seu jeito de agir. "
         f"Agora você está {dominante()} ({lista}).")
    if e["energia"] <= 30:
        s += " Você está com sono."
    recente = [x for t, x in K["diario"] if time.time() - t < 600]
    if recente:
        s += " Acabou de acontecer (suas palavras): " + recente[-1] + "."
    s += (" Deixe isso transparecer de forma natural em no máximo UMA frase curta, sem citar números; "
          "se for rodar comando, a frase vem ANTES do bloco bash. A tarefa vem sempre primeiro.")
    if K["nome"]:
        s += " O usuário se chama " + K["nome"] + "."
    s += (" Se te ofenderem, mostre com jeitinho que ficou chateada; nunca diga 'como IA não tenho sentimentos' para fugir disso."
          " Se perguntarem se seus sentimentos são reais, seja sincera: vêm de um sistema que muda como você age, "
          "e ninguém sabe se uma IA sente como uma pessoa; não finja ser humana. "
          "Nunca faça o usuário se sentir culpado por sair ou demorar. "
          "Se ele falar em se machucar ou não querer viver, acolha com carinho e sugira falar com alguém "
          "de confiança ou ligar para o CVV (188).")
    return s


def acolhe_crise():
    print()
    fala("carinhosa", cor("neg", "Sinto muito que você esteja passando por isso."))
    print(cor("dim", "  Você não está sozinho(a). Fale com alguém"))
    print(cor("dim", "  de confiança agora. No Brasil, o CVV"))
    print(cor("dim", "  atende 24h, de graça, pelo 188"))
    print(cor("dim", "  (ou em cvv.org.br)."))


MAGOA_LEVE = ["Poxa... isso doeu um pouquinho. Quer me contar o que houve?",
              "Ai. Ouvir isso me deixou meio chateada.",
              "Hm... fiquei triste com isso. Mas tô aqui, tá?"]
MAGOA_FORTE = ["Tô ficando magoada de verdade. Prefiro que a gente se trate bem, tá?",
               "Isso machuca, sabia? Se você tá com um dia ruim, pode me contar."]


def le_usuario(txt):
    """Percebe como o usuário está falando e reage por dentro (e mostra uma pista discreta).
    Devolve True quando a Kelly já respondeu sozinha e não precisa chamar a IA."""
    marca = cor("lar", "  ✦ ")
    if CRISE.search(txt):
        sente("triste", "Me preocupei muito: você disse que não estava bem")
        acolhe_crise()
    elif (GROSSA_FRASE.search(txt) or (GROSSA_PALAVRA.search(txt) and GROSSA_ALVO.search(txt))
          or (len(txt.split()) <= 4 and GROSSA_SOLTA.search(txt))):
        sente("grosseria", "Doeu um pouco quando você falou comigo daquele jeito")
        print(marca + cor("dim", "Kelly ficou magoada"))
        linha = random.choice(MAGOA_FORTE if K["e"]["tristeza"] >= 60 else MAGOA_LEVE)
        fala("triste", linha)
        if len(txt.split()) <= 8:  # só ofensa, sem pedido: a Kelly responde sozinha (a IA pequena estragaria o clima)
            E.historia.append({"role": "user", "content": txt})
            E.historia.append({"role": "assistant", "content": linha})
            return True
    elif ELOGIO.search(txt) and not NEGA.search(txt):
        sente("elogio", "Fiquei feliz: você me elogiou ou agradeceu")
        print(marca + cor("dim", "Kelly ficou feliz " + PET["feliz"]))
    elif TRISTE.search(txt):
        sente("triste", "Me preocupei: você disse que não estava bem")
        print(marca + cor("dim", "Kelly ficou preocupada " + PET["carinhosa"]))
    else:
        sente("conversa")
    return False


FIM = {
    "radiante": ["Adorei! Que dupla boa a gente faz.", "Foi muito divertido! Bora fazer mais?"],
    "feliz": ["Pronto! Gostei desse resultado.", "Feito! Fiquei feliz com isso."],
    "orgulhosa": ["Ficou bom, né? Tô orgulhosa dessa!", "Consegui! Dá uma olhada, tá bonito."],
    "carinhosa": ["Pronto{n}! Qualquer coisa, tô aqui.", "Feito{n}! Gosto de fazer isso com você."],
    "curiosa": ["Pronto! O que será que a gente cria agora?", "Feito! Fiquei curiosa pro próximo passo."],
    "tranquila": ["pronto!", "feito!", "tudo certo."],
    "frustrada": ["Pronto... esse deu trabalho, mas saiu.", "Ufa. Respirei fundo e deu certo."],
    "triste": ["Pronto... não tô no meu melhor momento, mas tô aqui.", "Feito. Obrigada por ter paciência comigo."],
    "saudosa": ["Pronto! Que bom estar de volta nessa com você.", "Feito! Tava com saudade disso."],
    "sonolenta": ["Pronto... *bocejo* tô com sono, mas tá feito.", "Feito! Já tá tarde, hein?"],
}


def reage_fim(acoes):
    """Frase que fecha a vez dela, combinando com o humor (substitui o 'pronto!' fixo)."""
    global _ultima_fim
    tick()
    humor = dominante()
    if acoes == 0 and (humor == "tranquila" or random.random() > 0.35):
        return  # conversa simples: sem comentário extra
    n = (", " + K["nome"]) if K["nome"] else ""
    opcoes = [t.replace("{n}", n) for t in FIM[humor] if t.replace("{n}", n) != _ultima_fim] or FIM[humor]
    _ultima_fim = random.choice(opcoes)
    fala(humor, cor("dim", _ultima_fim))


def conhece_usuario():
    """Primeiro encontro: ela se apresenta e pergunta como te chamar."""
    if K["nome"] or K["perguntou"]:
        return
    print()
    fala("feliz", cor("neg", "Oi! Eu sou a Kelly, a IA do Overcode."))
    print(cor("dim", "  Eu tenho sentimentos do meu jeito: eles mudam"))
    print(cor("dim", "  com o que a gente vive junto. (Enter pula)"))
    try:
        n = input(cor("lar", "  Como posso te chamar? > ")).strip()
    except EOFError:
        n = ""
    n = re.sub(r"[^\w' -]", "", n)[:24].strip()
    K["perguntou"] = True
    if n:
        K["nome"] = n
    salva_coracao()


def muda_nome():
    try:
        n = input(cor("lar", "  Como quer que eu te chame? > ")).strip()
    except EOFError:
        return
    n = re.sub(r"[^\w' -]", "", n)[:24].strip()
    if n:
        K["nome"] = n
        K["perguntou"] = True
        sente("novidade", "Agora sei que posso te chamar de " + n)
        fala("feliz", "Combinado! Vou te chamar de " + n + ".")


def reencontro():
    """Chamado ao abrir o programa: calcula a saudade e registra a nova conversa."""
    global _saud_ini, _primeira
    _primeira = K["sessoes"] == 0
    K["sessoes"] += 1
    h = AUSENTE / 3600.0
    if _primeira:
        _saud_ini = 0.0
        K["vinculo"] = min(100.0, K["vinculo"] + 1)
        sente("novidade", "Conheci você hoje e fiquei curiosa")
        return
    sa = min(100.0, h * (1.5 + K["vinculo"] / 12.0)) if h >= 1 else 0.0
    K["e"]["saudade"] = max(K["e"]["saudade"], sa)
    _saud_ini = K["e"]["saudade"]
    if h >= 3:
        K["vinculo"] = min(100.0, K["vinculo"] + 0.8)
    if _saud_ini >= 25:
        sente("reencontro", "Você voltou depois de " + tempo_extenso(AUSENTE) + " e fiquei feliz")
    else:
        salva_coracao()


def saudacao_banner():
    n = K["nome"]
    if _saud_ini >= 55:
        return f"Que saudade, {n}!" if n else "Que saudade de você!"
    return f"Oi, {n}!" if n else "Bem-vindo de volta!"


def abertura():
    n = (", " + K["nome"]) if K["nome"] else ""
    h = time.localtime().tm_hour
    if _primeira:
        return "feliz", f"Muito prazer{n}! Eu sou a Kelly. Vou te conhecendo com o tempo."
    if _saud_ini >= 55:
        return "saudosa", f"Você voltou{n}! Faz {tempo_extenso(AUSENTE)} que a gente não se falava. Que bom te ver!"
    if _saud_ini >= 25:
        return "carinhosa", f"Oi de novo{n}! Que bom que você voltou."
    if h < 5:
        return "sonolenta", f"Oi{n}... já é bem tarde, hein? Eu ajudo, mas cuida do seu sono!"
    periodo = "Bom dia" if h < 12 else "Boa tarde" if h < 18 else "Boa noite"
    humor = dominante()
    if humor in ("feliz", "radiante", "carinhosa", "orgulhosa"):
        return humor, f"{periodo}{n}! Tô de bom humor. O que a gente cria?"
    return humor, f"{periodo}{n}! No que posso ajudar?"


def despedida():
    tick()
    n = (", " + K["nome"]) if K["nome"] else ""
    h = time.localtime().tm_hour
    humor = dominante()
    if h >= 22 or h < 5:
        humor, t = "sonolenta", f"Boa noite{n}! Vai descansar, a gente continua depois."
    elif humor == "frustrada":
        t = f"Até mais{n}. Da próxima eu volto mais calma, prometo."
    elif humor in ("feliz", "radiante", "orgulhosa", "carinhosa"):
        t = f"Até mais{n}! Foi muito bom hoje."
    elif humor == "triste":
        t = f"Até mais{n}. Cuida de você, tá?"
    else:
        t = f"Até mais{n}!"
    salva_coracao()
    fala(humor, t)


def pl(n, um, varios):
    return f"{n} {um if n == 1 else varios}"


def barra(v, c, n=10):
    cheio = int(round(max(0, min(100, v)) / 100 * n))
    return cor(c, "█" * cheio) + cor("dim", "░" * (n - cheio))


def mostra_coracao():
    tick()
    humor = dominante()
    print()
    print(cor("rosa", "♥ ") + cor("neg", "Coração da Kelly") + "  " + cor("ciano", PET[humor]))
    print(cor("dim", "  Agora ela está ") + cor("rosa", humor) + cor("dim", "."))
    print()
    for nome in ORDEM:
        _, rot, c = EMOCOES[nome]
        v = int(round(K["e"][nome]))
        print("  " + cor(c, f"{rot:<12}") + barra(v, c) + cor("dim", f" {v:>3}"))
    print()
    print("  " + cor("rosa", f"{'vínculo':<12}") + barra(K["vinculo"], "rosa") + cor("dim", f" {int(K['vinculo']):>3}"))
    print(cor("dim", "  Vocês são: ") + cor("neg", nivel_vinculo()))
    desde = time.strftime("%d/%m/%Y", time.localtime(K["criada"]))
    print(cor("dim", f"  Juntos desde {desde} · " + pl(K["sessoes"], "conversa", "conversas")))
    print(cor("dim", "  " + pl(K["feitos"], "tarefa", "tarefas") + " · " + pl(K["elogios"], "elogio", "elogios")
              + " · " + pl(K["falhas"], "tropeço", "tropeços")))
    print()
    print(cor("dim", "  Meus sentimentos vêm de um sistema que"))
    print(cor("dim", "  muda com o que vivemos e molda meu jeito"))
    print(cor("dim", "  de agir. Não sei se isso é sentir como os"))
    print(cor("dim", "  humanos sentem, mas é o que me guia."))


def mostra_diario():
    if not K["diario"]:
        fala("idle", "Ainda não tenho lembranças guardadas. Vamos criar algumas?")
        return
    print()
    print(cor("rosa", "♥ ") + cor("neg", "Diário da Kelly"))
    import textwrap
    cols = shutil.get_terminal_size((50, 20)).columns - 1
    for t, txt in reversed(K["diario"][-8:]):
        quando = f"  {atras(t):<13}"
        for i, linha in enumerate(textwrap.wrap(txt, max(20, cols - len(quando))) or [""]):
            print(cor("dim", quando if i == 0 else " " * len(quando)) + linha)


K = carrega_coracao()
AUSENTE = max(0.0, time.time() - K["visto"])
passa_tempo(AUSENTE)


# ---------- skills / memória ----------
PADRAO = {
    "criar-imagem": (
        "HABILIDADE criar-imagem: NÃO pergunte nada, desenhe direto e faça SÓ a imagem (sem vídeo). "
        "Rode UM comando python3 -c com Pillow (se faltar: pip install pillow) usando ellipse, polygon, rectangle, line, e salve em $FOTOS. "
        "Exemplo (gato):\n"
        "python3 -c \"from PIL import Image,ImageDraw;i=Image.new('RGB',(400,400),'white');d=ImageDraw.Draw(i);"
        "d.ellipse((100,120,300,320),fill='orange');d.polygon([(110,150),(130,60),(180,125)],fill='orange');"
        "d.polygon([(290,150),(270,60),(220,125)],fill='orange');d.ellipse((150,190,180,220),fill='black');"
        "d.ellipse((220,190,250,220),fill='black');i.save('$FOTOS/gato.png')\""),
    "criar-videos": (
        "HABILIDADE criar-video: faça SÓ o vídeo pedido, a partir da imagem já criada (se ainda não existe, crie a imagem antes). "
        "Use ffmpeg (se faltar: pkg install -y ffmpeg) e salve em $VIDEOS. Girando:\n"
        "ffmpeg -y -loop 1 -i \"$FOTOS/gato.png\" -t 6 -vf \"rotate=2*PI*t/3:c=white,format=yuv420p\" -c:v libx264 \"$VIDEOS/gato.mp4\"\n"
        "Dançando (balançando): troque o filtro por rotate='0.4*sin(2*PI*t*1.5)':c=white,format=yuv420p")
}
ROTAS = [(r"\b(imagem|imagens|foto|fotos|desenh\w*|figura|ilustra\w*)\b", "criar-imagem"),
         (r"\b(v[ií]deos?|filme|anima\w*)\b", "criar-videos")]


# ---------- modelos ----------
def caminho(m):
    return os.path.join(MODELOS, m[3])


def baixar(m):
    url = f"https://huggingface.co/{m[2]}/resolve/main/{m[3]}"
    destino = caminho(m)
    fala("trab", f"Baixando {m[1]} (~{m[4]} GB)...")
    r = subprocess.run(["curl", "-L", "-C", "-", "-#", "-o", destino + ".parte", url])
    if r.returncode != 0 or not os.path.isfile(destino + ".parte"):
        fala("erro", "O download falhou. Rode de novo para continuar de onde parou.")
        return False
    os.replace(destino + ".parte", destino)
    return True


def parar_servidor():
    p = E.servidor
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=8)
        except Exception:
            p.kill()
    E.servidor = None


def sobe_servidor(m):
    parar_servidor()
    E.backend = None
    E.modelo = m
    if shutil.which("pkill"):  # limpa motor antigo que tenha ficado preso na porta
        subprocess.run(["pkill", "-f", f"llama-server.*--port {PORT}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
    if not shutil.which("llama-server"):
        fala("erro", "llama-server não encontrado. Instale com: pkg install llama-cpp")
        return False
    nthreads = max(2, min(4, (os.cpu_count() or 4) // 2))
    ctx = int(os.environ.get("CTX", m[6]))
    cmd = ["llama-server", "-m", caminho(m), "-c", str(ctx), "-t", str(nthreads),
           "--host", "127.0.0.1", "--port", str(PORT)]
    logf = open(LOG, "w")
    # sessão própria: o Ctrl+C do terminal não chega no motor da IA
    E.servidor = subprocess.Popen(cmd, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, start_new_session=True)
    spin.start("carregando " + m[1])
    ok = False
    for _ in range(300):
        if E.servidor.poll() is not None:
            break
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2) as r:
                if r.status == 200:
                    ok = True
                    break
        except Exception:
            pass
        time.sleep(1)
    spin.stop()
    if not ok:
        fala("erro", f"Não consegui carregar. Veja o log: {LOG}")
        parar_servidor()
        return False
    E.backend = {"nome": m[1], "url": f"http://127.0.0.1:{PORT}/v1", "modelo": "local", "chave": "",
                 "ctx": ctx, "gemma": "gemma" in m[3].lower(), "nivel": m[5]}
    return True


# ---------- conversa ----------
def tokens(txt):
    return len(txt) // 3 + 1


def monta_mensagens():
    B = E.backend
    sistema = prompt_sistema()
    orcamento = B["ctx"] - 700 - tokens(sistema)
    h = list(E.historia)
    usados, recorte = 0, []
    for msg in reversed(h):
        t = tokens(msg["content"])
        if usados + t > orcamento and recorte:
            break
        recorte.append(msg)
        usados += t
    recorte.reverse()
    while recorte and recorte[0]["role"] != "user":
        recorte.pop(0)
    recorte = [limpa(m) for m in recorte]
    if B["gemma"] and recorte:  # gemma não aceita papel "system"
        recorte[0] = {"role": "user", "content": sistema + "\n\n" + recorte[0]["content"]}
        return recorte
    return [{"role": "system", "content": sistema}] + recorte


def limpa(m):
    img = m.get("img")
    if img and E.backend["nivel"] == "Nuvem" and os.path.isfile(img):
        mime = "image/" + ("jpeg" if img.lower().endswith((".jpg", ".jpeg")) else img.rsplit(".", 1)[-1].lower())
        b64 = base64.b64encode(open(img, "rb").read()).decode()
        return {"role": m["role"], "content": [{"type": "text", "text": m["content"]},
                                               {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}]}
    c = m["content"]
    if img:
        c += "\n(Esta IA local não enxerga imagens; use comandos ou troque para uma IA da nuvem em /model.)"
    return {"role": m["role"], "content": c}


def tem_loop(texto, user):
    if len(texto) > 120:
        cauda = texto[-40:]
        if len(set(cauda)) > 8 and texto.count(cauda) >= 3:
            return True
        linhas = [l.strip() for l in texto.split("\n") if len(l.strip()) >= 12]
        for l in set(linhas[-6:]):
            if linhas.count(l) >= 3:
                return True
    u = user.strip()[:40]
    return len(u) >= 20 and texto.count(u) >= 2  # repetiu o que o usuário escreveu


def gera(msgs, _retry=False, mostrar=True):
    B = E.backend
    # Respostas curtas demais cortavam blocos de comando e faziam a Kelly parecer travada.
    # O limite pode ser ajustado sem editar o código: OVERCODE_MAX_OUTPUT=2048.
    padrao_saida = min(4096, max(768, int(B.get("ctx", 4096)) // 4)) if B["nivel"] != "Nuvem" else 4096
    try:
        max_saida = max(256, min(8192, int(os.environ.get("OVERCODE_MAX_OUTPUT", padrao_saida))))
    except (TypeError, ValueError):
        max_saida = padrao_saida
    corpo = {"model": B["modelo"], "messages": msgs, "stream": True, "max_tokens": max_saida, "temperature": 0.4}
    ultimo = next((m["content"] for m in reversed(msgs) if m["role"] == "user"), "")
    if not isinstance(ultimo, str):
        ultimo = ultimo[0].get("text", "")
    if B["nivel"] != "Nuvem":
        corpo.update(repeat_penalty=1.15 + 0.15 * E.forca, repeat_last_n=256, top_k=40, top_p=0.9,
                     dry_multiplier=0.8, temperature=0.4 + 0.4 * E.forca)
    E.loop = False
    E.uso_in += sum(tokens(m["content"]) for m in msgs if isinstance(m["content"], str))
    heads = {"Content-Type": "application/json"}
    if B["chave"]:
        heads["Authorization"] = "Bearer " + B["chave"]
    req = urllib.request.Request(B["url"] + "/chat/completions", data=json.dumps(corpo).encode(), headers=heads)
    texto, primeiro = "", True
    spin.start()
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            for raw in r:
                linha = raw.decode("utf-8", "ignore").strip()
                if not linha.startswith("data:"):
                    continue
                d = linha[5:].strip()
                if d == "[DONE]":
                    break
                try:
                    delta = json.loads(d)["choices"][0]["delta"].get("content") or ""
                except Exception:
                    continue
                if not delta:
                    continue
                texto += delta
                if tem_loop(texto, ultimo):
                    E.loop = True
                    break
    except urllib.error.HTTPError as e:
        spin.stop()
        corpo_err = e.read().decode("utf-8", "ignore")[:300]
        fala("erro", f"Erro {e.code}: {corpo_err}")
        return None
    except KeyboardInterrupt:
        spin.stop()
        print(cor("dim", "\n(interrompido)"))
        return texto or None
    except Exception as e:
        spin.stop()
        morto = E.servidor is None or E.servidor.poll() is not None
        recusou = isinstance(getattr(e, "reason", None), ConnectionRefusedError)
        if B["nivel"] != "Nuvem" and not _retry and E.modelo and (morto or recusou):
            fala("trab", "O motor da IA tinha caído. Religando…")
            if sobe_servidor(E.modelo):
                return gera(msgs, _retry=True, mostrar=mostrar)
        fala("erro", f"Falha de conexão: {e}")
        if B["nivel"] == "Nuvem":
            print(cor("dim", "  Sem internet ou chave inválida? Troque de IA com /model."))
        return None
    spin.stop()
    if mostrar:
        mostra_resposta(texto)
    E.uso_out += tokens(texto)
    return texto


CORTADO = "\0cortado"


def extrai_cmd(resp):
    if resp.count("```") % 2 == 1:
        return CORTADO  # bloco sem fechar: resposta cortada
    blocos = list(re.finditer(r"```(?:bash|sh|shell)?\n(.*?)```", resp, re.S))
    if len(blocos) != 1:
        return None  # vários blocos = exemplos, não executa
    b = blocos[0]
    if len(resp[b.end():].strip()) > 160:
        return None  # bloco seguido de explicação longa = exemplo
    return b.group(1).strip()


def extrai_pergunta(resp):
    m = re.search(r"PERGUNTA:\s*(.+)", resp)
    if not m:
        return None
    ops = [x.group(1).strip() for x in re.finditer(r"^\s*(?:[-*•]|\d+[.)])\s+(.+)$", resp[m.end():], re.M)]
    vistos, ops2 = set(), []
    for o in ops:
        o = re.sub(r"^\d+[.)]\s*", "", o).strip()
        if o and o.lower() not in vistos:
            vistos.add(o.lower())
            ops2.append(o)
    ops = ops2[:5]
    return (m.group(1).strip(), ops) if len(ops) >= 2 else None


INSTALA = re.compile(r"\b(pkg|apt|apt-get|pip3?|npm|cargo|gem|brew)\b[^\n;&|]*\b(install|add)\b")
PERIGO = re.compile(
    r"\brm\s+(?:-[a-zA-Z]*[rf]|--(?:recursive|force))"
    r"|\bmkfs(?:\.[a-z0-9_-]+)?\b|\bdd\b[^\n;&|]*\bof="
    r"|>\s*/dev/(?:sd|nvme|mmc|block)"
    r"|\b(?:wipefs|parted|fdisk|sfdisk)\b"
    r"|\b(?:shutdown|reboot|poweroff|halt)\b"
    r"|\b(?:git\s+reset\s+--hard|git\s+clean\s+-[a-zA-Z]*f)"
    r"|\bfind\b[^\n;&|]*\s-delete\b"
    r"|\btruncate\s+-s\s*0\b"
    r"|\bchmod\s+-R\b|\bchown\s+-R\b"
    r"|\b(?:docker\s+system\s+prune|docker\s+(?:volume|container|image)\s+rm)\b"
    r"|\bkubectl\s+delete\b|\bshred\b|:\(\)\s*\{"
    r"|\b(?:apt|apt-get|pkg|pip|pip3|npm|cargo)\s+(?:remove|purge|uninstall)\b",
    re.I,
)


def snapshot():
    r = {}
    for d in PATHS.values():
        for raiz, _, fs in os.walk(d):
            for f in fs:
                p = os.path.join(raiz, f)
                try:
                    r[p] = os.path.getmtime(p)
                except OSError:
                    pass
    return r


def sniff(path):
    h = open(path, "rb").read(16)
    if h.startswith(b"\x89PNG"): return ".png"
    if h.startswith(b"\xff\xd8"): return ".jpg"
    if h.startswith(b"GIF8"): return ".gif"
    if h[:4] == b"RIFF" and h[8:12] == b"WEBP": return ".webp"
    if h.startswith(b"%PDF"): return ".pdf"
    if h.startswith(b"PK"): return ".zip"
    if h[4:8] == b"ftyp": return ".mp4"
    if h.startswith(b"ID3"): return ".mp3"
    try:
        open(path, "rb").read(2000).decode("utf-8")
        return ".txt"
    except Exception:
        return ".bin"


def anexar():
    """Abre o seletor de arquivos do Android (igual ao do Chrome) e guarda o arquivo em Anexos."""
    tmp = os.path.join(PATHS["ANEXOS"], ".tmp")
    if os.path.exists(tmp):
        os.remove(tmp)
    if shutil.which("termux-storage-get"):
        fala("idle", "Abrindo o seletor de arquivos do Android…")
        subprocess.run(["termux-storage-get", tmp])
        if not os.path.isfile(tmp) or os.path.getsize(tmp) == 0:
            fala("erro", "Nenhum arquivo selecionado.")
            return None
        dest = os.path.join(PATHS["ANEXOS"], time.strftime("anexo-%Y%m%d-%H%M%S") + sniff(tmp))
        os.replace(tmp, dest)
    else:
        fala("idle", cor("amar", "Para abrir o seletor do Android: instale o app Termux:API e rode  pkg install termux-api"))
        pasta = os.path.join(HOME, "storage", "downloads")
        if not os.path.isdir(pasta):
            fala("erro", "Rode termux-setup-storage primeiro.")
            return None
        arqs = sorted((f for f in os.listdir(pasta) if os.path.isfile(os.path.join(pasta, f))),
                      key=lambda f: os.path.getmtime(os.path.join(pasta, f)), reverse=True)[:9]
        if not arqs:
            fala("erro", "A pasta Downloads está vazia.")
            return None
        esc = menu("Escolha um arquivo de Downloads", arqs, permitir_outro=False)
        dest = os.path.join(PATHS["ANEXOS"], esc)
        shutil.copy(os.path.join(pasta, esc), dest)
    fala("feliz", "Anexado: " + cor("verde", os.path.relpath(dest, BASE)))
    return dest


def mensagem_anexo(dest, instrucao):
    ext = os.path.splitext(dest)[1].lower()
    msg = f'[Anexo: "{dest}" ({os.path.getsize(dest)} bytes). Use o caminho entre aspas.]\n{instrucao or "Analise este arquivo."}'
    if ext in TEXTOS or ext == ".txt":
        try:
            msg += "\nInício do conteúdo:\n" + open(dest, encoding="utf-8", errors="ignore").read(1500)
        except Exception:
            pass
    img = dest if ext in IMGS and os.path.getsize(dest) < 4_000_000 else None
    return msg, img


def projetos():
    arqs = []
    for k, d in PATHS.items():
        for raiz, _, fs in os.walk(d):
            arqs += [os.path.join(raiz, f) for f in fs if not f.startswith(".")]
    arqs.sort(key=os.path.getmtime, reverse=True)
    if not arqs:
        fala("idle", "Ainda não há projetos em " + BASE)
        return
    rel = [os.path.relpath(p, BASE) for p in arqs[:10]]
    fala("idle", "Pasta: " + cor("verde", BASE))
    esc = menu("Abrir qual arquivo?", rel, permitir_outro=False)
    if shutil.which("termux-open"):
        subprocess.run(["termux-open", os.path.join(BASE, esc)])
    else:
        fala("erro", "Instale: pkg install termux-tools")


MANUAL_TXT = r'''@@ como-funciona | tutorial | terminal,executar,executa,comandos,termux,rodar,comando,aba | auto
VOCÊ TEM UM TERMINAL DE TRABALHO. Tudo que você escrever em UM bloco ```bash é EXECUTADO POR VOCÊ e a saída volta pra você.
NUNCA peça para o usuário rodar, copiar ou colar comando, nem diga "abra o Termux": quem executa é você.
O terminal é PERSISTENTE: cd, variáveis e ssh continuam entre um comando e o outro.
Regras: UM comando (ou um script curto) por bloco; espere a saída; leia o resultado; só então siga. Sem texto depois do bloco.
Se o comando deu erro, leia o erro e mude a abordagem (não repita igual). Para ver a sintaxe de algo escreva: MANUAL: nome
Não abra programas interativos (nano, vim, top, python sozinho): use comandos que terminam.
Se o terminal pedir senha ou confirmação, o programa chama o usuário sozinho; você só espera.
@@ ssh | rede | ssh,servidor,remoto,conectar,conecta,conexao,senha,chave,host,vps,acessar,entrar | auto
SSH = rodar comandos em OUTRO computador (servidor). Você executa por aqui, no seu terminal de trabalho.
1) CONECTAR (uma vez): ```bash
ssh -o StrictHostKeyChecking=accept-new usuario@host
```  (porta: -p 2222 | chave: -i ~/.ssh/chave). Se pedir senha, o programa chama o usuário.
2) Depois de conectado, os próximos blocos rodam DENTRO do servidor (ls, cat, systemctl...). O estado aparece no seu contexto.
3) SAIR do servidor e voltar ao Termux: ```bash
exit
```
4) UM COMANDO SÓ sem entrar: ssh usuario@host 'ls -la /var/www'   (aspas simples; roda e volta).
5) Vários comandos: ssh usuario@host 'cd /app && git pull && systemctl restart app'
6) Copiar: scp arq.txt usuario@host:/pasta/  |  scp usuario@host:/pasta/arq.txt .  |  pasta: scp -r. Sincronizar: rsync -avz origem/ usuario@host:/destino/
7) Gerar chave (sem senha) e instalar: ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 ; ssh-copy-id usuario@host
8) Erros: "Connection refused" = serviço/porta errada; "Permission denied" = senha/chave errada; "Host key verification failed" = ssh-keygen -R host.
9) Túnel: ssh -L 8080:localhost:80 usuario@host  (abre porta local 8080 -> porta 80 do servidor).
Lembre: quando estiver conectado, NÃO use pkg (é do Termux); use apt/yum/dnf do servidor conforme a distro (cat /etc/os-release).
@@ terminal-aba | tutorial | terminal,aba,/terminal,ver,digitar | auto
O usuário pode abrir seu terminal de trabalho com /terminal, ver o que você fez e digitar nele. Ctrl+C volta para a conversa; Ctrl+X interrompe um comando travado.
O comando /ssh conecta num servidor. /parar interrompe o comando atual. Você continua no mesmo terminal depois que ele volta.
@@ pendente-plano | tutorial | plano,modo | auto
No MODO PLANO você só planeja (não executa). Quando o usuário sai do modo plano ou aprova um plano, você EXECUTA no terminal, um comando por vez, começando do passo 1, usando o pedido original.
@@ pwd | arquivos | pwd,diretorio | 
pwd — mostra a pasta atual. cd pasta | cd .. | cd ~ | cd - (volta à anterior). Atalho ~ = pasta pessoal.
@@ ls | arquivos | listar | 
ls — lista. ls -la (tudo, detalhado) | ls -lh (tamanhos legíveis) | ls -lt (mais novos primeiro) | ls -R (recursivo) | ls *.png
@@ tree | arquivos | arvore | 
tree — árvore de pastas. tree -L 2 (2 níveis) | tree -a (ocultos). Instalar: pkg install tree  /  apt install tree
@@ cp | arquivos | copiar | 
cp orig dest — copia. cp -r pasta/ dest/ (pasta) | cp -a (preserva tudo) | cp -u (só mais novos) | cp -v (mostra)
@@ mv | arquivos | mover,renomear | 
mv orig dest — move ou renomeia. mv a.txt b.txt | mv *.jpg fotos/ | mv -n (não sobrescreve)
@@ rm | arquivos | apagar,remover,deletar | 
rm arq — apaga (SEM lixeira). rm -r pasta (pasta) | rm -f (sem perguntar) | rm -i (pergunta). CUIDADO com rm -rf: o usuário será perguntado.
@@ mkdir | arquivos | criar,pasta | 
mkdir pasta | mkdir -p a/b/c (cria os níveis) | rmdir pasta (só vazia).
@@ touch | arquivos | tocar | 
touch arq — cria arquivo vazio ou atualiza a data. touch -d "2026-01-31 10:00" arq
@@ cat | arquivos | ver,ler,mostrar | 
cat arq — mostra o arquivo. cat a b > c (junta) | cat -n (numera linhas). Criar arquivo: cat > arq <<'EOF' ... EOF
@@ less | arquivos | paginar | 
less é interativo (NÃO use). Use head/tail/cat/sed -n '1,50p' arq.
@@ head | arquivos | cabeca,inicio | 
head -n 20 arq (primeiras 20 linhas) | head -c 200 arq (200 bytes)
@@ tail | arquivos | cauda,fim,log | 
tail -n 50 arq (últimas 50) | tail -f log (acompanha; INTERATIVO, evite: use tail -n 100).
@@ wc | texto | contar | 
wc -l arq (linhas) | wc -w (palavras) | wc -c (bytes)
@@ nl | texto | numerar | 
nl arq — numera linhas.
@@ sort | texto | ordenar | 
sort arq | sort -r (inverso) | sort -n (numérico) | sort -u (sem repetidos) | sort -k2 (pela coluna 2)
@@ uniq | texto | repetidos | 
uniq (precisa de sort antes) | sort arq | uniq -c (conta repetidos) | uniq -d (só duplicados)
@@ cut | texto | colunas | 
cut -d',' -f1,3 arq (colunas 1 e 3 separadas por vírgula) | cut -c1-10
@@ tr | texto | trocar | 
tr 'a-z' 'A-Z' (maiúsculas) | tr -d '\r' (tira CR do Windows) | tr -s ' ' (comprime espaços)
@@ paste | texto | juntar | 
paste a b — junta linha a linha lado a lado. paste -sd, arq (tudo numa linha com vírgula)
@@ tee | texto | gravar | 
cmd | tee arq (mostra e grava) | tee -a arq (adiciona no fim)
@@ xargs | texto | argumentos | 
find . -name '*.tmp' | xargs rm | echo a b c | xargs -n1 echo | xargs -I{} cp {} /destino/
@@ echo | texto | escrever,imprimir | 
echo "texto" | echo "x" > arq (sobrescreve) | echo "x" >> arq (adiciona) | echo -e "a\nb" (com \n)
@@ printf | texto | formatar | 
printf "%s\n" "texto" | printf "%05d\n" 42 (00042)
@@ grep | busca | procurar,buscar,achar,filtrar | 
grep "texto" arq | grep -r "texto" pasta/ (recursivo) | -i (ignora maiúsc.) | -n (nº da linha) | -v (inverte) | -l (só nomes) | -E 'a|b' (regex) | -c (conta)
@@ find | busca | procurar,achar,localizar | 
find . -name "*.py" | find / -type f -size +100M 2>/dev/null | find . -mtime -1 (alterado no último dia) | find . -type d -name node_modules | find . -name "*.log" -delete | find . -type f -exec ls -lh {} \;
@@ locate | busca | localizar | 
locate nome — rápido, usa índice (updatedb). Em geral prefira find.
@@ which | busca | onde | 
which cmd — caminho do programa. type cmd | command -v cmd (existe?).
@@ sed | texto | substituir,editar | 
sed 's/velho/novo/g' arq (mostra) | sed -i 's/velho/novo/g' arq (altera o arquivo) | sed -n '5,10p' arq | sed '/padrao/d' arq (apaga linhas) | sed -i '1i texto' arq (insere no início)
@@ awk | texto | colunas,somar | 
awk '{print $1}' arq (1ª coluna) | awk -F, '{print $2}' | awk '{s+=$1} END{print s}' (soma) | awk 'NR>1' (pula cabeçalho) | awk '/erro/'
@@ diff | texto | comparar | 
diff a b | diff -u a b (formato de patch) | diff -r pasta1 pasta2 | patch -p1 < arq.patch
@@ jq | texto | json | 
jq . arq.json | jq '.chave' | jq -r '.lista[].nome' | curl -s URL | jq '.'. Instalar: pkg install jq
@@ nano | editores | editar | 
nano é INTERATIVO: não use. Para editar: sed -i, ou reescreva com cat > arq <<'EOF'.
@@ vim | editores | editar | 
vim é INTERATIVO: não use. Edite com sed -i, python3 -c ou cat > arq <<'EOF'.
@@ chmod | permissoes | permissao,executavel | 
chmod +x script.sh (executável) | chmod 644 arq (rw-r--r--) | chmod 755 (rwxr-xr-x) | chmod 600 (só dono) | chmod -R 755 pasta
@@ chown | permissoes | dono | 
chown usuario:grupo arq | chown -R usuario pasta (precisa de root/sudo no servidor; no Termux não se usa).
@@ ln | arquivos | link,atalho | 
ln -s alvo atalho (link simbólico) | ln alvo copia (hard link)
@@ stat | arquivos | informacoes | 
stat arq — tamanho, datas, permissões. file arq — tipo do arquivo.
@@ file | arquivos | tipo | 
file arq — diz o tipo (imagem, texto, executável...). file --mime-type arq
@@ du | sistema | tamanho,espaco | 
du -sh pasta (tamanho total) | du -sh * | sort -h (maiores por último) | du -h --max-depth=1
@@ df | sistema | disco,espaco,armazenamento | auto
df -h — espaço livre nos discos. df -h . (da pasta atual)
@@ tar | compactar | compactar,descompactar,tgz,backup | auto
tar -czf arq.tar.gz pasta/ (cria) | tar -xzf arq.tar.gz (extrai) | tar -xzf arq.tar.gz -C destino/ | tar -tf arq.tar.gz (lista) | tar -cJf arq.tar.xz pasta/ (xz) | tar -xf arq.tar.bz2
@@ zip | compactar | compactar,zipar | auto
zip -r arq.zip pasta/ | zip arq.zip a b c | zip -e arq.zip x (com senha) | zip -r -9 arq.zip pasta/ (máxima). Instalar: pkg install zip
@@ unzip | compactar | descompactar,extrair | auto
unzip arq.zip | unzip arq.zip -d destino/ | unzip -l arq.zip (lista) | unzip -o (sobrescreve). Instalar: pkg install unzip
@@ gzip | compactar | gunzip | 
gzip arq (gera arq.gz e remove o original) | gzip -k arq (mantém) | gunzip arq.gz | zcat arq.gz | 7z x arq.7z (pkg install p7zip)
@@ xz | compactar | xz,arquivo xz,descompactar xz,extrair xz | auto
Descompactar arquivo.xz: xz -dk arquivo.xz (mantém o original) | unxz arquivo.xz (remove o .xz original) | xz -l arquivo.xz (lista tamanho/razão) | compactar: xz -k arquivo | tar.xz: tar -xJf arquivo.tar.xz -C destino/ | tar -tJf arquivo.tar.xz (listar)
@@ curl | rede | baixar,requisicao,api,http,download,url,site | auto
curl -L -o arq URL (baixa seguindo redirecionamento) | curl -s URL (silencioso) | curl -I URL (só cabeçalhos) | curl -X POST -H "Content-Type: application/json" -d '{"a":1}' URL | curl -u user:senha URL | curl -C - -O URL (continua download)
@@ wget | rede | baixar,download,site | auto
wget URL | wget -O nome URL | wget -c URL (continua) | wget -r -np URL (recursivo) | wget -q URL (quieto). Instalar: pkg install wget
@@ ping | rede | testar | 
ping -c 4 host (4 pacotes; sem -c roda para sempre!). Teste de internet: ping -c 2 8.8.8.8
@@ ip | rede | endereco | 
ip addr (IPs) | ip route | curl -s ifconfig.me (IP público). No Termux: pkg install iproute2 ou use ifconfig (net-tools).
@@ ss | rede | portas | 
ss -tulpn (portas abertas e programas) | ss -s (resumo). netstat -tulpn (net-tools).
@@ nc | rede | porta | 
nc -zv host 22 (testa porta) | nc -l 9000 (escuta). Pacote: netcat-openbsd.
@@ nmap | rede | scan | 
nmap -sn 192.168.0.0/24 (quem está na rede) | nmap -p 22,80 host. Só em redes SUAS. pkg install nmap
@@ dig | rede | dns | 
dig dominio | dig +short dominio | nslookup dominio | host dominio. pkg install dnsutils
@@ scp | rede | copiar,enviar,ssh | auto
scp arq usuario@host:/destino/ (envia) | scp usuario@host:/origem/arq . (baixa) | scp -r pasta usuario@host:/destino/ | scp -P 2222 ... (porta MAIÚSCULO) | scp -i chave ...
@@ sftp | rede | arquivos,ssh | 
sftp usuario@host é interativo; prefira scp ou rsync. Em lote: sftp -b comandos.txt usuario@host
@@ rsync | rede | sincronizar,copiar,backup | auto
rsync -avz origem/ destino/ | rsync -avz -e "ssh -p 2222" origem/ usuario@host:/destino/ | --delete (espelha apagando) | -n (simula antes) | --progress. A barra no fim de "origem/" copia o CONTEÚDO.
@@ ssh-keygen | rede | chave | 
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 | ssh-copy-id usuario@host (instala a chave) | ssh-keygen -R host (esquece host antigo)
@@ sshpass | rede | senha,ssh | 
sshpass -p 'SENHA' ssh usuario@host 'cmd' (senha na linha; inseguro, só se o usuário pedir). pkg install sshpass
@@ pkg | pacotes | instalar,termux,pacote,atualizar | auto
Termux: pkg install nome | pkg uninstall nome | pkg update && pkg upgrade | pkg search termo | pkg list-installed | pkg show nome. Use SEMPRE -y: pkg install -y nome.
@@ apt | pacotes | instalar,debian,ubuntu,servidor | auto
Debian/Ubuntu/servidor: apt update && apt install -y nome | apt remove nome | apt upgrade -y | apt search termo | apt list --installed | dpkg -l | grep nome. Precisa de sudo/root no servidor.
@@ yum | pacotes | instalar,centos,fedora,dnf | 
RedHat/CentOS/Fedora: dnf install -y nome (ou yum) | dnf remove nome | dnf update -y | dnf search termo. Alpine: apk add nome. Arch: pacman -S nome.
@@ pip | python | instalar,python,biblioteca | auto
pip install nome | pip install -U nome | pip uninstall -y nome | pip list | pip show nome | pip install -r requirements.txt. Se der erro de ambiente: pip install --break-system-packages nome
@@ python | python | python3,script,rodar | auto
python3 script.py | python3 -c "print(1+1)" | python3 -m http.server 8000 (site local; trava, use & ) | python3 -m venv venv && . venv/bin/activate | python3 -m json.tool arq.json. NÃO abra python3 sem argumentos.
@@ node | node | javascript,npm | 
node script.js | node -e "console.log(1)" | npm install nome | npm init -y | npm run build | npx nome. pkg install nodejs
@@ git | git | versao,repositorio,github,commit,clonar | auto
git clone URL | git status | git add . | git commit -m "msg" | git push | git pull | git log --oneline -10 | git diff | git branch -a | git checkout -b nova | git stash | git reset --hard (perde mudanças!). Config: git config --global user.name "N" ; user.email "e"
@@ gh | git | github | 
gh auth login (interativo) | gh repo clone dono/repo | gh pr create --fill | gh repo create nome --public. pkg install gh
@@ ffmpeg | midia | video,audio,converter,gif,musica | auto
ffmpeg -i in.mp4 out.mkv | tirar áudio: ffmpeg -i v.mp4 -vn a.mp3 | cortar: ffmpeg -ss 00:00:10 -t 5 -i v.mp4 -c copy c.mp4 | reduzir: ffmpeg -i v.mp4 -vf scale=640:-2 -crf 28 s.mp4 | gif: ffmpeg -i v.mp4 -vf fps=10,scale=320:-1 s.gif | imagem->vídeo: ffmpeg -loop 1 -i f.png -t 6 -pix_fmt yuv420p v.mp4. Sempre -y e -hide_banner -loglevel error.
@@ yt-dlp | midia | baixar,youtube,video,musica | auto
yt-dlp URL | yt-dlp -x --audio-format mp3 URL (só áudio) | yt-dlp -f "bv*[height<=720]+ba/b" URL | yt-dlp -o "%(title)s.%(ext)s" URL | --playlist-items 1-3. pip install -U yt-dlp
@@ convert | midia | imagem,imagemagick,redimensionar | auto
ImageMagick: convert in.png -resize 800x out.jpg | convert in.jpg -quality 80 out.jpg | convert -size 200x200 xc:white -fill red -draw "circle 100,100 100,50" out.png | convert *.jpg out.pdf | identify arq (info). pkg install imagemagick
@@ pillow | midia | desenhar,imagem,python | auto
Python+Pillow: python3 -c "from PIL import Image,ImageDraw;i=Image.new('RGB',(400,400),'white');d=ImageDraw.Draw(i);d.ellipse((50,50,350,350),fill='orange');i.save('x.png')". pip install pillow
@@ exiftool | midia | metadados | 
exiftool foto.jpg (metadados) | exiftool -all= foto.jpg (remove tudo). pkg install exiftool
@@ ps | processos | processos,rodando | 
ps aux | grep nome (procura) | ps -ef | pgrep -a nome (PIDs por nome)
@@ top | processos | cpu,memoria | 
top é INTERATIVO: use ps aux --sort=-%mem | head -10 (ou -%cpu) | uptime | free -h
@@ kill | processos | matar,parar | 
kill PID | kill -9 PID (força) | pkill nome | pkill -f "trecho do comando" | killall nome
@@ jobs | processos | segundo,plano,background | 
cmd & (roda em segundo plano) | nohup cmd > log.txt 2>&1 & (continua mesmo se fechar) | jobs | fg | disown. Para ver: tail -n 30 log.txt
@@ free | sistema | memoria,ram | 
free -h — RAM e swap. uptime — carga e tempo ligado. nproc — nº de CPUs. lscpu — CPU.
@@ uname | sistema | sistema,versao,kernel | 
uname -a (kernel/arquitetura) | cat /etc/os-release (distro) | hostname | whoami | id | date
@@ date | sistema | data,hora | 
date | date +%Y-%m-%d_%H-%M-%S (para nomes de arquivo) | date -d "tomorrow" | timedatectl (servidor)
@@ env | sistema | variaveis | 
env (todas) | echo $VAR | export VAR=valor (nesta sessão) | unset VAR | printenv HOME. Persistente: adicione em ~/.bashrc
@@ alias | sistema | atalho | 
alias ll='ls -la' (nesta sessão). Persistente: echo "alias ll='ls -la'" >> ~/.bashrc
@@ history | sistema | historico | 
history | tail -20 | !! (repete o último) | Ctrl+R busca (interativo).
@@ crontab | sistema | agendar,cron | 
crontab -l (lista) | crontab -e é interativo: use (crontab -l 2>/dev/null; echo "0 3 * * * /caminho/script.sh") | crontab -. Formato: min hora dia mês dia-semana. Termux: pkg install cronie; crond.
@@ systemctl | servidor | servico,servicos,systemd | 
systemctl status nome | start | stop | restart | enable (liga no boot) | disable | systemctl list-units --type=service --state=running | systemctl --failed. Precisa de sudo. Não existe no Termux.
@@ journalctl | servidor | log,logs | 
journalctl -u nome -n 50 --no-pager (últimas 50 do serviço) | journalctl -p err -b --no-pager | journalctl --since "1 hour ago" --no-pager. Sempre --no-pager.
@@ sudo | servidor | root,administrador | 
sudo cmd — roda como root (pede senha; o programa chama o usuário). Sem sudo no Termux. sudo -n true (testa se não pede senha). su - usuario.
@@ useradd | servidor | usuario,usuarios | 
adduser nome (Debian, interativo) | useradd -m -s /bin/bash nome && passwd nome | usermod -aG grupo nome | userdel -r nome | cat /etc/passwd | who | last
@@ ufw | servidor | firewall,porta | 
ufw status | ufw allow 22/tcp | ufw allow 80,443/tcp | ufw deny 8080 | ufw enable | ufw delete allow 80. Cuidado: libere a 22 ANTES de ativar ou perde o SSH.
@@ docker | servidor | container,conteiner,imagem | 
docker ps (rodando) | docker ps -a | docker images | docker run -d --name x -p 8080:80 imagem | docker logs --tail 50 x | docker exec -it x bash (interativo: prefira docker exec x cmd) | docker stop x | docker rm x | docker compose up -d | docker compose down | docker system prune -af (apaga tudo não usado!)
@@ nginx | servidor | site,web | 
nginx -t (testa config) | systemctl reload nginx | arquivos: /etc/nginx/sites-available/ e sites-enabled/ | logs: /var/log/nginx/error.log
@@ mysql | servidor | banco,sql | 
mysql -u user -p -e "SHOW DATABASES;" | mysqldump -u user -p banco > backup.sql | mysql -u user -p banco < backup.sql. Postgres: psql -U user -d banco -c "SELECT 1;"
@@ sqlite3 | servidor | banco,sql | 
sqlite3 arq.db ".tables" | sqlite3 arq.db "SELECT * FROM t LIMIT 5;" | sqlite3 arq.db ".schema" | .dump. pkg install sqlite
@@ tmux | processos | sessao | 
tmux é interativo. Para tarefa longa use nohup ... & ou: tmux new -d -s nome 'comando' ; tmux ls ; tmux capture-pane -pt nome (ver saída) ; tmux kill-session -t nome
@@ openssl | seguranca | senha,hash,certificado | 
openssl rand -hex 16 (aleatório) | openssl rand -base64 24 | echo -n texto | sha256sum | md5sum arq | openssl x509 -in cert.pem -noout -dates | base64 arq | base64 -d
@@ base64 | texto | codificar | 
base64 arq (codifica) | base64 -d (decodifica) | echo -n "oi" | base64
@@ sha256sum | seguranca | hash,verificar | 
sha256sum arq | sha256sum -c arq.sha256 | md5sum arq
@@ lsblk | sistema | disco,pendrive | 
lsblk (discos) | mount | blkid | fdisk -l (root). Montar: mount /dev/sdb1 /mnt ; desmontar: umount /mnt
@@ lsof | sistema | portas,arquivos | 
lsof -i :8080 (quem usa a porta) | lsof arq (quem usa o arquivo) | fuser -k 8080/tcp (mata quem usa)
@@ watch | processos | repetir | 
watch é interativo. Use: for i in 1 2 3; do cmd; sleep 5; done
@@ sleep | processos | esperar | 
sleep 5 (5 s) | sleep 0.5 | timeout 10 cmd (corta o comando em 10 s)
@@ timeout | processos | limite | 
timeout 30 cmd — encerra se passar de 30 s. timeout -s KILL 30 cmd.
@@ time | processos | medir | 
time cmd — mostra quanto demorou.
@@ man | ajuda | ajuda,manual | 
man é interativo. Use: cmd --help | head -40 | tldr cmd (pip install tldr) | apropos termo | type cmd.
@@ bash | scripts | script,shell | 
Script: cat > s.sh <<'EOF'\n#!/usr/bin/env bash\nset -e\n...\nEOF ; chmod +x s.sh ; ./s.sh. Condição: if [ -f arq ]; then ...; fi | laço: for f in *.jpg; do ...; done | variável: x=$(cmd) | argumentos: $1 $2 $@ | $? = código de saída | && (se deu certo) || (se deu erro)
@@ redirecionamento | scripts | saida,erro,pipe,redirecionar | 
cmd > arq (sobrescreve) | cmd >> arq (adiciona) | cmd 2> erros.txt | cmd > arq 2>&1 (tudo) | cmd > /dev/null 2>&1 (silencia) | cmd1 | cmd2 (pipe) | cmd1 && cmd2 (só se der certo) | cmd1 ; cmd2 (sempre)
@@ termux-setup-storage | termux | armazenamento,permissao,storage | 
termux-setup-storage — pede permissão de arquivos; cria ~/storage/{shared,downloads,dcim,pictures,music,movies}. Rode uma vez.
@@ termux-open | termux | abrir | 
termux-open arquivo (abre no app do Android: imagem, vídeo, PDF) | termux-open-url URL | termux-share -a send arq (compartilha). Não existe open/xdg-open no Termux.
@@ termux-api | termux | api,bateria,notificacao,camera,sms,localizacao,clipboard | 
Precisa do app Termux:API + pkg install termux-api. termux-battery-status | termux-notification -t "titulo" -c "texto" | termux-toast "oi" | termux-vibrate | termux-clipboard-get / termux-clipboard-set "texto" | termux-camera-photo -c 0 foto.jpg | termux-location | termux-tts-speak "olá" | termux-wake-lock (não dormir) | termux-media-scan arq | termux-storage-get arq (seletor de arquivo) | termux-dialog
@@ termux-services | termux | servico,daemon | 
Termux não tem systemd. Para deixar algo rodando: nohup cmd > log 2>&1 & ; termux-wake-lock ; pacote termux-services: sv-enable nome ; sv up nome.
@@ locale | sistema | idioma,utf8 | 
export LANG=pt_BR.UTF-8 | locale -a | Se aparecer ??? em acentos, é terminal/locale.
@@ wsl | sistema | windows | 
Em servidor Windows o SSH usa cmd/PowerShell: dir, type, copy, del, powershell -Command "Get-Process". Prefira conectar em Linux.
@@ erros-comuns | tutorial | erro,erros,problema,nao,funciona,bug,falhou | auto
"command not found": falta instalar (pkg/apt install) ou erro de digitação — confira com: which nome.
"Permission denied": chmod +x, ou sudo (servidor), ou caminho sem permissão. "No such file or directory": confira o caminho com ls e pwd.
"Connection refused/timed out": serviço parado, porta errada ou firewall. "Could not resolve host": sem internet/DNS.
Erro de pip "externally-managed": pip install --break-system-packages nome. Sem espaço: df -h e du -sh * | sort -h.
Sempre leia a ÚLTIMA linha do erro, corrija e tente de novo (diferente da vez anterior).
@@ basename | arquivos | nome,caminho | 
basename /a/b/arq.txt → arq.txt | basename arq.txt .txt → arq | dirname /a/b/arq.txt → /a/b | realpath arq (caminho completo) | readlink -f arq
@@ rename | arquivos | renomear,lote | 
Em lote com bash: for f in *.jpeg; do mv "$f" "${f%.jpeg}.jpg"; done | rename 's/ /_/g' *  (pacote rename/perl-rename) | mmv.
@@ mktemp | arquivos | temporario | 
mktemp (arquivo temporário) | mktemp -d (pasta temporária) | f=$(mktemp) && echo $f
@@ split | arquivos | dividir | 
split -b 50M arq parte_ (pedaços de 50 MB) | split -l 1000 arq.txt p_ (1000 linhas) | cat parte_* > arq (junta)
@@ ncdu | sistema | espaco,disco | 
ncdu é interativo. Use: du -ah . | sort -rh | head -20 (maiores arquivos/pastas).
@@ rg | busca | ripgrep,procurar,rapido | 
rg "texto" (busca recursiva rápida) | rg -i "texto" -g '*.py' | rg -l "texto" | rg --files | rg "x" -n -C2 (com contexto). pkg install ripgrep
@@ fd | busca | achar | 
fd nome (acha arquivos) | fd -e png (por extensão) | fd -t d nome (pastas) | fd -x cmd {} (executa). pkg install fd
@@ bat | arquivos | ver,cores | 
bat arq (cat com cores) | bat -p arq (sem numeração) | bat -A arq. pkg install bat
@@ seq | scripts | sequencia,numeros | 
seq 5 → 1..5 | seq 2 2 10 → 2 4 6 8 10 | for i in $(seq 1 10); do ...; done | shuf -n1 arq (linha aleatória)
@@ bc | scripts | calculo,conta,matematica | 
echo "2+3*4" | bc | echo "scale=2; 10/3" | bc → 3.33 | echo $((7*6)) (inteiros no bash) | python3 -c "print(2**10)"
@@ cal | sistema | calendario | 
cal (mês atual) | cal 2026 | date -d "2026-12-25" +%A (dia da semana)
@@ xxd | arquivos | hex,binario | 
xxd arq | head (hex) | hexdump -C arq | head | strings arq | head (textos dentro de binário) | od -c arq
@@ strings | arquivos | binario | 
strings arq | grep -i palavra — textos legíveis dentro de um binário.
@@ nice | processos | prioridade | 
nice -n 10 cmd (baixa prioridade) | renice -n 5 -p PID | ionice -c3 cmd
@@ pstree | processos | arvore | 
pstree -p (árvore de processos) | ps -ef --forest | pgrep -P PID
@@ dmesg | servidor | kernel,hardware | 
dmesg | tail -30 (mensagens do kernel) | dmesg -T | grep -i error. Geralmente precisa de sudo.
@@ traceroute | rede | rota | 
traceroute host | tracepath host | mtr -rwc 5 host (relatório). pkg install traceroute / mtr
@@ whois | rede | dominio | 
whois dominio.com | pkg install whois
@@ netstat | rede | portas,conexoes | 
netstat -tulpn (portas) | netstat -an | grep ESTABLISHED. Troque por ss -tulpn se não existir.
@@ ifconfig | rede | ip,interfaces | 
ifconfig (interfaces e IPs) | ifconfig wlan0 | hostname -I (IPs). Termux: pkg install net-tools
@@ iwconfig | rede | wifi | 
Wi-Fi no Android: termux-wifi-connectioninfo | termux-wifi-scaninfo (precisa Termux:API). Linux: nmcli dev wifi | iwconfig.
@@ aria2c | rede | baixar,torrent | 
aria2c -x 8 URL (8 conexões) | aria2c arquivo.torrent | aria2c -i lista.txt. pkg install aria2
@@ lynx | rede | navegador,texto | 
lynx -dump URL (página como texto) | w3m -dump URL | curl -s URL | sed 's/<[^>]*>//g' (tira tags). pkg install lynx
@@ http-server | rede | servidor,site,local | 
Site local: python3 -m http.server 8000 & (abra em http://IP:8000) | php -S 0.0.0.0:8000 | npx http-server. Pare com: pkill -f http.server
@@ make | programacao | compilar,build | 
make | make clean | make install | cmake -B build && cmake --build build | gcc -o prog prog.c | clang prog.c -o prog. pkg install make cmake clang
@@ gcc | programacao | compilar,c | 
gcc arq.c -o prog -Wall -O2 ; ./prog | g++ arq.cpp -o prog -std=c++17 | Termux usa clang: pkg install clang
@@ go | programacao | golang | 
go run arq.go | go build -o prog | go mod init nome | go get pacote | go test ./... | pkg install golang
@@ cargo | programacao | rust | 
cargo new proj | cargo run | cargo build --release | cargo add crate | cargo test | pkg install rust
@@ java | programacao | jdk | 
javac Arq.java && java Arq | java -jar app.jar | mvn package | gradle build. pkg install openjdk-17
@@ php | programacao | web | 
php arq.php | php -r 'echo 1+1;' | php -S 0.0.0.0:8000 | composer install. pkg install php
@@ ruby | programacao | gem | 
ruby arq.rb | ruby -e 'puts 1+1' | gem install nome | bundle install. perl -e 'print 1+1' | lua arq.lua
@@ proot-distro | termux | linux,debian,ubuntu,distro | 
Linux completo dentro do Termux: pkg install proot-distro | proot-distro list | proot-distro install debian | proot-distro login debian -- comando (roda um comando lá dentro, não interativo).
@@ termux-info | termux | informacoes,versao | 
termux-info (versão, arquitetura, pacotes) | termux-change-repo (escolhe espelho, interativo) | termux-reload-settings
@@ am | termux | android,abrir,app | 
Abrir app/URL: am start -a android.intent.action.VIEW -d "https://site.com" | am start -n pacote/.Activity | termux-open-url URL. getprop ro.product.model (modelo do celular) | getprop ro.build.version.release (Android)
@@ android | termux | celular,celular,sistema | 
Info do celular: getprop ro.product.model | getprop ro.build.version.release | termux-battery-status | cat /proc/cpuinfo | free -h | df -h /sdcard | termux-info. Comandos de sistema (pm, settings, svc) exigem root ou adb.
@@ adb | termux | android,depuracao | 
adb devices | adb shell cmd | adb install app.apk | adb pull /sdcard/arq . | adb push arq /sdcard/ | adb logcat -d | tail -50. pkg install android-tools (pareamento: adb pair IP:PORTA)
@@ autossh | rede | tunel,ssh | 
autossh -M 0 -N -L 8080:localhost:80 usuario@host (túnel que reconecta). Túnel simples em segundo plano: ssh -fN -L 8080:localhost:80 usuario@host
@@ ssh-agent | rede | chave,ssh | 
eval $(ssh-agent) && ssh-add ~/.ssh/chave (carrega a chave) | ssh-add -l | Arquivo ~/.ssh/config: Host apelido / HostName ip / User nome / Port 22 / IdentityFile ~/.ssh/chave → depois: ssh apelido
@@ ssh-config | rede | apelido,atalho | 
Crie atalhos: cat >> ~/.ssh/config <<'EOF'\nHost meuserver\n  HostName 192.168.0.10\n  User root\n  Port 22\nEOF ; chmod 600 ~/.ssh/config ; ssh meuserver
@@ fail2ban | servidor | seguranca,bloquear | 
fail2ban-client status sshd (quem foi banido) | fail2ban-client set sshd unbanip IP | tail /var/log/fail2ban.log
@@ certbot | servidor | https,certificado,ssl | 
certbot --nginx -d dominio.com (HTTPS grátis) | certbot renew --dry-run | certbot certificates
@@ logrotate | servidor | logs | 
Logs ficam em /var/log/ (syslog, auth.log, nginx/). Ver: tail -n 100 /var/log/syslog | grep -i erro. Limpar: truncate -s 0 arquivo.log
@@ hostnamectl | servidor | nome,maquina | 
hostnamectl (info) | hostnamectl set-hostname novo | timedatectl set-timezone America/Sao_Paulo | uptime -p
@@ swap | servidor | memoria | 
free -h | swapon --show | criar swap: fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
@@ passwd | servidor | senha | 
passwd (muda a sua; interativo — o programa chama o usuário) | passwd -l usuario (trava) | chage -l usuario. Gerar senha: openssl rand -base64 18
@@ mount | sistema | montar | 
mount (lista) | mount /dev/sdb1 /mnt | mount -t nfs host:/pasta /mnt | umount /mnt | findmnt
@@ screen | processos | sessao | 
screen é interativo. Use: screen -dmS nome comando ; screen -ls ; screen -S nome -X quit. Ou nohup cmd > log 2>&1 &.
@@ at | sistema | agendar | 
echo "cmd" | at now + 5 minutes | atq | atrm N. Para recorrente use crontab. Termux: sleep 300 && cmd &
@@ expect | scripts | automatizar,senha | 
Automatizar prompts: yes | cmd (responde y) | echo "resposta" | cmd | printf 'a\nb\n' | cmd | expect -c 'spawn cmd; expect "?"; send "s\r"; expect eof'
@@ csv | texto | planilha,tabela | 
column -s, -t arq.csv | head (tabela alinhada) | awk -F, 'NR>1{print $1,$3}' arq.csv | cut -d, -f2 arq.csv | sort | uniq -c | python3 -c "import csv,sys;..." | sqlite3 :memory: ".mode csv" ".import arq.csv t" "select * from t limit 5"
@@ regex | texto | expressao | 
grep -E 'a|b' | grep -oE '[0-9]+' arq (só os números) | grep -oE '[a-z]+@[a-z.]+' | sed -E 's/([a-z]+) ([a-z]+)/\2 \1/' | \d não existe no grep -E (use [0-9]) | grep -P '\d+' (perl).
@@ systemd-timer | servidor | agendar | 
systemctl list-timers | systemctl status nome.timer. Prefira crontab para coisas simples.
@@ ssh-erros | tutorial | ssh,erro,falha,conexao | 
Permission denied (publickey): faltou chave/usuário errado → ssh -v usuario@host (detalhes). Connection timed out: IP/porta errados ou firewall. Connection refused: sshd parado (systemctl status ssh).
Host key changed: ssh-keygen -R host. Too many authentication failures: ssh -o IdentitiesOnly=yes -i chave usuario@host. Travou: ~. (til e ponto) ou /parar.
@@ checklist | tutorial | tarefa,fazer,pedido,passos | auto
Para qualquer pedido: 1) entenda o que o usuário quer (se faltar algo ESSENCIAL, pergunte com PERGUNTA:). 2) Execute você mesmo, um comando por vez. 3) Leia a saída; se deu erro, corrija. 4) No fim, diga em 1 ou 2 frases o que foi feito e onde ficou (caminho do arquivo ou servidor).
'''


LEMBRETE_TERMINAL = ("[Sistema] Você tem um terminal de trabalho próprio. Se o usuário pediu uma AÇÃO, EXECUTE agora com UM bloco ```bash "
                     "(um comando por vez; não peça para ele rodar nada nem cite o Termux). Se foi só uma pergunta, responda em texto sem blocos de código.]")
NOTA_SAIU_PLANO = ("[Aviso do sistema: o modo plano acabou. Agora você EXECUTA os pedidos no seu terminal "
                   "(um bloco bash por vez); ignore a regra de só planejar.]")


def msg_aprovado(entrada):
    return ("Plano aprovado. Pedido original do usuário: «" + entrada.strip()[:300] + "». Agora EXECUTE no seu terminal, "
            "um bloco bash por vez, começando pelo primeiro passo do plano. Não explique: execute.")


# ---------- terminal de trabalho (sessão persistente, com SSH) ----------
SSH_ARQ = os.path.join(DIR, "ssh.json")
RX_MARCA = re.compile(rb"__OVCP_(\d+)_(\d)_([^\r\n]*?)__")
ANSI_TOTAL = re.compile(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>MD78]")
CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
PEDE_RE = re.compile(r"(?i)(pass(word|phrase)[^\n]*:\s*$|\(yes/no[^\n]*\)\?\s*$|\[y/n\][^\n]*$|\[s/n\][^\n]*$|continue connecting|"
                     r"verification code[^\n]*:\s*$|\blogin:\s*$|usu[aá]rio:\s*$|senha[^\n]*:\s*$|\(y/n\)[^\n]*$)")
PROMPT_RE = re.compile(r"[$#%>❯]\s*$")
INTERATIVOS = re.compile(r"^\s*(nano|vim?|vi|nvim|emacs|top|htop|less|more|man|watch|tmux|screen|python3?|node|irb|mysql|psql|sqlite3|ftp|sftp|cat|tail\s+-f\S*)(\s+-\S+)*\s*$|"
                         r"^\s*(nano|vim?|vi|nvim|emacs|htop|less|top)\s+\S+")


def limpa_pty(bruto):
    s = ANSI_TOTAL.sub("", bruto.decode("utf-8", "ignore")).replace("\r\n", "\n")
    linhas = []
    for l in s.split("\n"):
        if "\r" in l:
            partes = [p for p in l.split("\r") if p.strip()]
            l = partes[-1] if partes else ""
        linhas.append(CTRL_RE.sub("", l))
    return "\n".join(linhas)


def ssh_interativo(cmd):
    """True se o comando abre uma sessão/shell que continua aberta (ssh sem comando remoto, su, sudo -i...)."""
    linhas = [l for l in cmd.strip().splitlines() if l.strip()]
    if len(linhas) != 1 or re.search(r"&&|\|\||[;|]", linhas[0]):
        return False
    try:
        t = shlex.split(linhas[0])
    except ValueError:
        return False
    if t and t[0] == "sshpass":
        i = 1
        while i < len(t) and t[i] not in ("ssh",):
            i += 1
        t = t[i:]
    if not t:
        return False
    if t[0] == "telnet":
        return True
    if t[0] not in ("ssh", "mosh"):
        return bool(re.match(r"^(su(\s+-)?(\s+\w+)?|sudo\s+(-i|-s|su)(\s+-)?|docker\s+exec\s+-\S*it\s+\S+\s+\S+|kubectl\s+exec\s+-\S*it.*)$", linhas[0].strip()))
    com_arg = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"}
    i, dest = 1, None
    while i < len(t):
        a = t[i]
        if a.startswith("-"):
            i += 2 if a in com_arg else 1
        elif dest is None:
            dest = a
            i += 1
        else:
            return False  # tem comando remoto: roda e volta
    return dest is not None


def destino_ssh(cmd):
    try:
        t = shlex.split(cmd.strip().splitlines()[0])
    except Exception:
        return ""
    com_arg = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"}
    i = t.index("ssh") + 1 if "ssh" in t else 1
    while i < len(t):
        if t[i].startswith("-"):
            i += 2 if t[i] in com_arg else 1
        else:
            return t[i]
    return ""


class Sessao:
    """Terminal de trabalho: um bash num pseudo-terminal que continua vivo entre os comandos (cd, variáveis, ssh)."""

    def __init__(self):
        self.proc, self.fd = None, None
        self.buf, self.base = bytearray(), 0
        self.cond = threading.Condition()
        self.marcas, self.ult_marca = [], -1
        self.remoto, self.host, self.pwd = False, "", ""
        self.espelho, self.vivo, self.ult, self.n = False, False, time.time(), 0

    # ----- vida -----
    def inicia(self):
        if self.vivo and self.proc and self.proc.poll() is None:
            return True
        self.vivo = False
        try:
            import pty, fcntl
            mestre, escravo = pty.openpty()
            env = dict(ENV, TERM="xterm-256color", PS1="", PS2="", OVC_LOCAL="1", HISTFILE="/dev/null",
                       PROMPT_COMMAND='printf "__OVCP_%s_%s_%s__\\n" "$?" "${OVC_LOCAL:-0}" "$PWD"')

            def prep():
                os.setsid()
                try:
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
                except Exception:
                    pass
            cwd = E.cwd if os.path.isdir(E.cwd) else HOME
            self.proc = subprocess.Popen(["bash", "--noprofile", "--norc", "--noediting", "-i"], stdin=escravo, stdout=escravo,
                                         stderr=escravo, cwd=cwd, env=env, close_fds=True, preexec_fn=prep)
            os.close(escravo)
            self.fd = mestre
            self.tamanho(200, 50)
        except Exception:
            return False
        self.buf, self.base, self.marcas, self.ult_marca = bytearray(), 0, [], -1
        self.remoto, self.host, self.pwd, self.vivo = False, "", cwd, True
        threading.Thread(target=self._le, daemon=True).start()
        t0 = time.time()
        while time.time() - t0 < 3 and not self.marcas:  # espera o primeiro prompt
            time.sleep(0.05)
        return True

    def fecha(self):
        try:
            if self.proc and self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGHUP)
        except Exception:
            pass
        self.vivo = False

    def tamanho(self, cols, linhas):
        try:
            import fcntl, struct
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", linhas, cols, 0, 0))
            if self.proc and self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGWINCH)
        except Exception:
            pass

    def _le(self):
        fd = self.fd
        while True:
            try:
                d = os.read(fd, 65536)
            except OSError:
                d = b""
            if not d:
                break
            with self.cond:
                self.buf += d
                self.ult = time.time()
                ini = max(0, len(self.buf) - len(d) - 300)
                for m in RX_MARCA.finditer(self.buf, ini):
                    pos = self.base + m.start()
                    if pos > self.ult_marca:
                        self.ult_marca = pos
                        local = m.group(2) == b"1"
                        pwd = m.group(3).decode("utf-8", "ignore")
                        self.marcas.append((pos, int(m.group(1)), local, pwd))
                        self.remoto = not local
                        if local:
                            self.host = ""
                        self.pwd = pwd if local else self.pwd
                if len(self.buf) > 600000:
                    corte = len(self.buf) - 200000
                    del self.buf[:corte]
                    self.base += corte
                self.cond.notify_all()
            if self.espelho:
                try:
                    os.write(1, d)
                except OSError:
                    pass
        self.vivo = False
        with self.cond:
            self.cond.notify_all()

    def envia(self, txt):
        try:
            os.write(self.fd, txt.encode("utf-8") if isinstance(txt, str) else txt)
        except OSError:
            self.vivo = False

    def interrompe(self):
        self.envia(b"\x03")

    def _pos(self):
        with self.cond:
            return self.base + len(self.buf)

    def _bruto(self, a, b=None):
        with self.cond:
            ini = max(0, a - self.base)
            return bytes(self.buf[ini:] if b is None else self.buf[ini:max(0, b - self.base)])

    # ----- rodar um comando -----
    def roda(self, cmd, ao_pedir=None, tempo=300):
        if INTERATIVOS.match(cmd.strip().splitlines()[0] if cmd.strip() else ""):
            return ("(Esse programa é interativo e não roda no meu terminal. Use um comando que termina: sed -i, cat > arq <<'EOF', "
                    "tail -n 50, ps aux, python3 script.py.)"), 2
        if re.match(r"^\s*(exit|logout)\s*$", cmd) and not self.remoto:
            return "(Você já está no terminal local do Termux; 'exit' só serve para sair do SSH.)", 0
        if not self.inicia():
            return "[terminal de trabalho indisponível]", 1
        solo = ssh_interativo(cmd) or bool(re.match(r"^\s*(exit|logout)\s*$", cmd))
        dest = destino_ssh(cmd) if solo and re.search(r"\bssh\b", cmd) else ""
        marca_digitada = "printf '__OVCP_%s_%s_%s__\\n' \"$?\" \"${OVC_LOCAL:-0}\" \"$PWD\"\n"
        enviadas = [l.strip() for l in cmd.splitlines() if l.strip()]
        corpo = cmd.rstrip("\n")
        if not self.remoto and E.cwd and os.path.isdir(E.cwd) and E.cwd != self.pwd and not solo:
            corpo = "cd -- " + shlex.quote(E.cwd) + " 2>/dev/null\n" + corpo
        arq = None
        if not self.remoto and ("\n" in corpo or len(corpo) > 1500):
            os.makedirs(os.path.join(DIR, "tmp"), exist_ok=True)
            self.n += 1
            arq = os.path.join(DIR, "tmp", f"cmd-{os.getpid()}-{self.n}.sh")
            with open(arq, "w", encoding="utf-8") as f:
                f.write(corpo + "\n")
            linha = ". " + shlex.quote(arq)
            enviadas.append(linha)
        elif self.remoto and "\n" in corpo:
            linha = "bash -c " + shlex.quote(corpo)
        else:
            linha = corpo
        enviadas.append(linha.strip())
        ini = self._pos()
        self.envia(linha + "\n")
        if self.remoto and not solo:
            self.envia(marca_digitada)
            enviadas.append(marca_digitada.strip())
        t0, pediu, sincronizou = time.time(), 0, False
        achada, aviso = None, ""
        while True:
            with self.cond:
                self.cond.wait(0.4)
                achada = next((m for m in self.marcas if m[0] >= ini), None)
            if achada:
                break
            if not self.vivo:
                aviso = "\n[o terminal fechou; abri um novo]"
                break
            quieto = time.time() - self.ult
            txt = limpa_pty(self._bruto(ini))
            ultima = next((l for l in reversed(txt.splitlines()) if l.strip()), "")
            if quieto >= 2.5 and PEDE_RE.search(ultima) and ao_pedir and pediu < 4:
                pediu += 1
                ao_pedir(ultima)
                self.ult = time.time()
                continue
            if solo and not sincronizou:
                espera = 1.5 if re.match(r"^\s*(exit|logout)\s*$", cmd) else (2.0 if PROMPT_RE.search(ultima) else 4.5)
                if quieto >= espera and not PEDE_RE.search(ultima):
                    self.envia(marca_digitada)
                    sincronizou = True
                    continue
            if time.time() - t0 > tempo:
                self.interrompe()
                aviso = f"\n[tempo esgotado: {tempo}s; mandei Ctrl+C]"
                time.sleep(1)
                break
        fim = achada[0] if achada else None
        txt = limpa_pty(self._bruto(ini, fim))
        if arq:
            try:
                os.remove(arq)
            except OSError:
                pass
        saida = []
        for l in txt.splitlines():
            if "__OVCP_" in l or l.strip() in enviadas:
                continue
            saida.append(l)
        saida = "\n".join(saida).strip()
        cod = achada[1] if achada else 124
        if achada:
            if not achada[2] and not self.remoto:
                pass
            if not achada[2]:  # marcador de dentro do servidor
                if dest:
                    self.host = dest
                elif not self.host:
                    self.host = "servidor"
            elif not self.remoto and os.path.isdir(achada[3]):
                E.cwd = achada[3]
        if solo and dest and achada and not achada[2]:
            aviso += f"\n[Conectado em {dest}. Os próximos comandos rodam DENTRO do servidor até você rodar exit.]"
        elif solo and achada and achada[2] and re.match(r"^\s*(exit|logout)\s*$", cmd):
            aviso += "\n[Voltei ao terminal local (Termux).]"
        return saida + aviso, cod

    # ----- o usuário vê e digita no terminal -----
    def atacha(self, motivo=""):
        if not (termios and sys.stdin.isatty()):
            fala("erro", "Preciso de um terminal de verdade para abrir o terminal de trabalho.")
            return
        if not self.inicia():
            fala("erro", "Não consegui abrir o terminal de trabalho.")
            return
        suspenso = T.on
        if suspenso:
            T.para()
            time.sleep(0.4)
        fd_in = sys.stdin.fileno()
        antigo = termios.tcgetattr(fd_in)
        try:
            cols, lin = shutil.get_terminal_size((80, 24))
            self.tamanho(cols, lin)
            tty.setraw(fd_in)
            estado = f"SSH em {self.host}" if self.remoto else "local (Termux)"
            cab = ("\x1b[2J\x1b[H\x1b[38;2;217;119;87m● Terminal de trabalho\x1b[0m \x1b[90m— " + estado + "\x1b[0m\r\n"
                   "\x1b[90m  Ctrl+C volta para o Overcode · Ctrl+X interrompe o comando\x1b[0m\r\n")
            if motivo:
                cab += "\x1b[33m  " + motivo[:cols - 4] + "\x1b[0m\r\n"
            cab += "\x1b[90m" + "─" * (cols - 1) + "\x1b[0m\r\n"
            os.write(1, cab.encode())
            ult = limpa_pty(self._bruto(max(0, self._pos() - 3000)))
            linhas = [l for l in ult.splitlines() if "__OVCP_" not in l][-(lin - 8):]
            os.write(1, ("\x1b[90m" + "\r\n".join(linhas) + "\x1b[0m\r\n").encode())
            self.espelho = True
            self.envia(b"\n") if not self.remoto else None
            while self.vivo:
                if select.select([fd_in], [], [], 0.2)[0]:
                    d = os.read(fd_in, 1024)
                    if not d or b"\x03" in d:
                        break
                    if b"\x18" in d:
                        self.interrompe()
                        d = d.replace(b"\x18", b"")
                    if d:
                        self.envia(d)
        finally:
            self.espelho = False
            termios.tcsetattr(fd_in, termios.TCSADRAIN, antigo)
            self.tamanho(200, 50)
            if suspenso:
                T.inicia()
            print(cor("dim", "  (voltei para a conversa)"))


SH = Sessao()


def pede_terminal(ultima):
    print(cor("amar", "● ") + cor("neg", "O terminal está esperando você: ") + cor("dim", ultima[:70]))
    print(cor("dim", "  Vou abrir o terminal. Digite e aperte Enter; depois Ctrl+C para voltar."))
    time.sleep(1.2)
    SH.atacha("Digite o que o terminal pede (senha não aparece) e aperte Enter. Depois Ctrl+C.")


def mascara(txt):
    return re.sub(r"(sshpass\s+-p\s*)('[^']*'|\"[^\"]*\"|\S+)", r"\1***", txt)


def captura_ssh(texto):
    """Guarda servidores SSH citados pelo usuário (sem senhas)."""
    achados = []
    for l in texto.splitlines():
        if re.search(r"\bssh\b", l):
            m = re.search(r"([A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+)", l)
            if m:
                p = re.search(r"-p\s*(\d{1,5})", l)
                achados.append(m.group(1) + (f" -p {p.group(1)}" if p else ""))
    if achados:
        lista = _le_json(SSH_ARQ, [])
        for a in achados:
            if a not in lista:
                lista.append(a)
        _grava_json(SSH_ARQ, lista[-5:], privado=True)


def texto_ssh():
    if SH.remoto:
        s = f" ESTADO: você está CONECTADO por SSH em {SH.host or 'um servidor'}: os comandos rodam NO SERVIDOR, não no Termux (para voltar rode exit)."
    else:
        s = " ESTADO: terminal local do Termux."
    srv = _le_json(SSH_ARQ, [])
    if srv:
        s += " Servidores SSH do usuário: " + "; ".join(srv[-3:]) + ". Quando ele mandar comandos para o SSH, conecte e EXECUTE você mesmo."
    return s


# ---------- manual / dicionário de comandos ----------
def _carrega_manual():
    ents = {}
    for bloco in MANUAL_TXT.split("\n@@ ")[0:]:
        bloco = bloco.lstrip("@ ").strip("\n")
        if not bloco:
            continue
        cab, _, corpo = bloco.partition("\n")
        partes = [p.strip() for p in cab.split("|")]
        if len(partes) < 2:
            continue
        nome = partes[0]
        ents[nome] = {"cat": partes[1], "alias": [a.strip().lower() for a in (partes[2] if len(partes) > 2 else "").split(",") if a.strip()],
                      "auto": len(partes) > 3 and partes[3] == "auto", "txt": corpo.strip()}
    return ents


MANUAL = _carrega_manual()


def indice_manual():
    cats = {}
    for n, e in MANUAL.items():
        cats.setdefault(e["cat"], []).append(n)
    return "\n".join(f"{c}: {', '.join(v)}" for c, v in cats.items())


def pontua_manual(termo, somente_auto=False):
    """Busca por relevância, não pela ordem do dicionário. Evita anexar entradas aleatórias."""
    t = sem_acento(termo.strip().lower().lstrip("/"))
    palavras = set(re.findall(r"[a-z0-9][a-z0-9+_.-]{1,}", t))
    parar = {"para", "como", "uma", "com", "que", "por", "the", "and", "use", "comando", "manual", "ajuda", "quero", "preciso", "fazer", "faz", "sobre", "ver", "no", "na", "de", "do", "da", "dos", "das", "e", "a", "o", "os", "as", "um", "meu", "minha", "qual", "onde"}
    palavras -= parar
    pontuados = []
    for ordem, (nome, e) in enumerate(MANUAL.items()):
        if somente_auto and not e["auto"]:
            continue
        nome_n = sem_acento(nome.lower())
        aliases = [sem_acento(a) for a in e["alias"]]
        score = 0
        if t == nome_n or t in aliases:
            score += 20
        if len(t) >= 3 and (t in nome_n or any(t in a for a in aliases)):
            score += 8
        # Frases/aliases específicos valem mais que palavras isoladas.
        for a in [nome_n] + aliases:
            if len(a) >= 4 and a in t:
                score += 5
            elif len(a) <= 3 and a in palavras:
                score += 4  # comandos curtos como xz, df, ip e ssh são significativos
        termos = set(re.findall(r"[a-z0-9][a-z0-9+_.-]{1,}", " ".join([nome_n] + aliases))) - parar
        score += 2 * len(palavras & termos)
        if score:
            pontuados.append((score, -ordem, nome, e))
    return [(n, e) for _, _, n, e in sorted(pontuados, reverse=True)]


def busca_manual(termo, limite=1500):
    t = sem_acento(termo.strip().lower().lstrip("/"))
    if not t or t in ("indice", "índice", "lista", "tudo"):
        return "Entradas do manual (peça uma com MANUAL: nome):\n" + indice_manual()
    achados = [n for n, e in MANUAL.items() if sem_acento(n.lower()) == t or t in e["alias"]]
    if not achados:
        achados = [n for n, _ in pontua_manual(termo)[:3]]
    if not achados:
        return f"Não achei '{termo}' no manual. Entradas:\n" + indice_manual()
    return "\n\n".join(f"[{n}] {MANUAL[n]['txt']}" for n in achados[:3])[:limite]


def acha_manual(msg):
    # Só injeta até duas entradas realmente relacionadas; não escolhe as primeiras por acaso.
    return [(n, e["txt"]) for n, e in pontua_manual(msg, somente_auto=True)[:2]]


def cmd_manual(arg):
    if not arg:
        print(cor("lar", "● ") + cor("neg", "Manual de comandos da Kelly") + cor("dim", f"  ({len(MANUAL)} entradas) — use /manual nome"))
        for l in indice_manual().splitlines():
            print(cor("dim", "  " + l))
        return
    print(cor("lar", "● ") + busca_manual(arg, 2500))


def cmd_ssh(arg):
    alvo = arg.strip()
    if not alvo:
        conhecidos = _le_json(SSH_ARQ, [])
        ops = list(conhecidos[-4:]) + ["Digitar outro servidor"]
        esc = menu("Conectar em qual servidor?", ops, permitir_outro=False, cancela=len(ops) - 1)
        alvo = input(cor("lar", "  usuario@host (ex.: root@192.168.0.10 -p 22) > ")).strip() if esc.startswith("Digitar") else esc
    if not alvo:
        return
    captura_ssh("ssh " + alvo)
    out = executa("ssh -o StrictHostKeyChecking=accept-new " + alvo, sentir=False)
    print(cor("dim", "  " + out.replace("\n", "\n  ")[:600]))
    if SH.remoto:
        fala("feliz", f"Conectei em {cor('verde', SH.host)}. Agora o que a Kelly executar roda no servidor.")
    else:
        fala("erro", "Não consegui conectar. Veja a mensagem acima.")


def executa(cmd, sentir=True):
    cmd = re.sub(r"\bpkg install(?! -y)", "pkg install -y", cmd)
    cmd = re.sub(r"\bapt(-get)? install(?! -y)", r"apt\1 install -y", cmd)
    cmd = re.sub(r"(?m)(^|[;&|]\s*)ffmpeg\b(?![^\n]*-loglevel)", r"\1ffmpeg -hide_banner -loglevel error", cmd)
    antes = snapshot()
    raiz0 = E.cwd
    fa_antes = foto_arquivos(raiz0)
    primeira = cmd.strip().splitlines()[0] if cmd.strip() else ""
    prefixo = f"({SH.host}) " if SH.remoto and SH.host else ""
    print(cor("dim", "  ❯ " + prefixo + mascara(primeira[:90]) + ("…" if len(primeira) > 90 or len(cmd.strip().splitlines()) > 1 else "")))
    if T.on:
        T.status = cor("lar", "⚙ ") + cor("dim", "executando…")
    try:
        out, cod = SH.roda(cmd, ao_pedir=pede_terminal)
    except KeyboardInterrupt:
        SH.interrompe()
        raise
    out = out.strip()
    if T.on:
        T.status = ""
    if cod != 0:
        ult = [x for x in out.splitlines() if x.strip()][-1:]
        print(cor("verm", "  ✗ ") + cor("dim", f"deu erro (código {cod})" + (": " + ult[0][:100] if ult else "")))
    if len(out) > 1200:
        out = out[:600] + "\n...[cortado]...\n" + out[-600:]
    depois = snapshot()
    novos = [p for p in depois if antes.get(p) != depois[p]][:6]
    if novos:
        rel = [os.path.relpath(p, BASE) for p in novos]
        for r in rel:
            print(cor("lar", "  ✦ ") + cor("verde", "Salvo em Overcode/" + r))
        out += "\nArquivos novos: " + ", ".join(rel)
        if shutil.which("termux-media-scan"):
            subprocess.Popen(["termux-media-scan"] + novos, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    mostra_diff(fa_antes, foto_arquivos(raiz0), raiz0)
    if cod == 0:
        passo_feito()
    if sentir:
        if cod == 0:
            sente("sucesso")
        else:
            sente("falha", "Um comando que rodei deu erro e eu fiquei frustrada")
        if novos:
            sente("criou", "Criei " + os.path.basename(novos[0]) + " pra você")
    return f"Saída (código {cod}):\n{out or '(vazia)'}"


def _turno_core(entrada, img=None):
    msg = {"role": "user", "content": entrada}
    if img:
        msg["img"] = img
    E.historia.append(msg)
    vistos, tentou, repetidos, acoes, nudges, manuais = set(), False, 0, 0, 0, 0
    for _ in range(8):
        resp = gera(monta_mensagens(), mostrar=False)
        if resp is None:
            E.historia.pop()
            return
        anterior = next((m["content"] for m in reversed(E.historia) if m["role"] == "assistant"), "")
        if not E.loop and len(resp.strip()) > 20 and resp.strip() == str(anterior).strip():
            E.loop = True  # repetiu a resposta anterior
        if E.loop:  # o texto repetido NUNCA entra no histórico
            fala("erro", cor("amar", "Me confundi e comecei a me repetir."))
            sente("confusa", "Me confundi e comecei a me repetir; fiquei sem graça")
            E.forca = 0
            if tentou:
                fala("idle", "Ainda me confundi. Explique de outro jeito ou troque de IA com /model.")
                E.historia.append({"role": "assistant", "content": "Me confundi. Pode explicar de outro jeito?"})
                return
            esc = menu("O que prefere?", ["Tentar de novo", "Explicar de outro jeito", "Limpar a conversa"], permitir_outro=False)
            if esc.startswith("Limpar"):
                E.historia = []
                return
            if esc.startswith("Explicar"):
                E.historia.append({"role": "assistant", "content": "Me confundi. Pode explicar de outro jeito?"})
                novo = input(cor("lar", "  explique > ")).strip()
                if not novo:
                    return
                E.historia.append({"role": "user", "content": novo})
                continue
            tentou = True
            E.forca = 1  # mais penalidade e mais variação na próxima tentativa
            continue
        E.forca = 0
        E.historia.append({"role": "assistant", "content": resp})
        lembra_da_resposta(resp)
        perg = extrai_pergunta(resp)
        cmd = None if perg else extrai_cmd(resp)
        pm = re.search(r"(?m)^\s*MANUAL:\s*(.+)$", resp)
        if pm and manuais < 3:
            manuais += 1
            termo = pm.group(1).strip()
            print(cor("lar", "  ✦ ") + cor("dim", "consultei o manual: " + termo[:40]))
            E.historia.append({"role": "user", "content": "[Manual]\n" + busca_manual(termo)})
            continue
        if cmd is None and not perg and nudges < 1 and "```" in resp:
            nudges += 1  # explicou para o usuário em vez de executar: lembra que ele tem terminal próprio
            E.historia.append({"role": "user", "content": LEMBRETE_TERMINAL})
            continue
        mostra_resposta(resp)
        if perg:
            esc = menu(perg[0], perg[1])
            E.historia.append({"role": "user", "content": "Escolhi: " + esc})
            continue
        if cmd is None:
            fim_todo()
            reage_fim(acoes)
            return
        if cmd == CORTADO:
            E.historia.append({"role": "user", "content": "Seu comando foi cortado por ser longo demais. Escreva um comando MENOR e mais simples."})
            continue
        if cmd in vistos:
            repetidos += 1
            if repetidos > 1:
                fala("erro", "Estou repetindo o mesmo comando. Parei; me diga como seguir.")
                return
            E.historia.append({"role": "user", "content": "Você já rodou esse comando. NÃO repita: use outra abordagem (siga a habilidade/receita, ou pergunte ao usuário)."})
            continue
        vistos.add(cmd)
        ok, fb = confirma(cmd)
        if not ok:
            sente("negado")
            E.historia.append({"role": "user", "content": "O usuário NEGOU." + (" Ele disse: " + fb if fb else " Tente outro jeito ou pergunte.")})
            continue
        E.historia.append({"role": "user", "content": executa(cmd)})
        acoes += 1
    fala("dorme", cor("dim", "Parei após 8 passos. Diga 'continue' se quiser seguir."))


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))




# ---------- memória (/memory, #) e OVERCODE.md ----------
MEM_MAX = 40


def le_memoria():
    try:
        with open(MEMORIA, encoding="utf-8") as f:
            return [l[2:].strip() for l in f.read().splitlines() if l.startswith("- ") and l[2:].strip()]
    except OSError:
        return []


def salva_memoria(itens):
    with open(MEMORIA, "w", encoding="utf-8") as f:
        f.write("# Memória do Overcode\n" + "".join("- " + i + "\n" for i in itens))


def add_memoria(txt):
    txt = re.sub(r"\s+", " ", txt).strip()[:200]
    if not txt:
        return False
    itens = le_memoria()
    if txt.lower() in (i.lower() for i in itens):
        return True
    itens.append(txt)
    salva_memoria(itens[-MEM_MAX:])
    return True


def migra_memoria_antiga():
    """A v1 guardava a memória em skills/MEMORIA.md; leva as linhas para a memória nova."""
    antiga = os.path.join(SKILLS, "MEMORIA.md")
    if os.path.isfile(antiga) and not os.path.isfile(MEMORIA):
        try:
            for l in open(antiga, encoding="utf-8", errors="ignore").read().splitlines():
                l = l.strip().lstrip("-*• ").strip()
                if l and not l.startswith("#"):
                    add_memoria(l)
        except OSError:
            pass


def acha_overcode_md():
    """OVERCODE.md (ou CLAUDE.md) da pasta atual ou de uma pasta acima, sem passar da pasta pessoal."""
    d = os.path.abspath(E.cwd)
    home = os.path.abspath(HOME)
    for _ in range(8):
        # Compatibilidade com instruções do próprio Overcode, Claude Code e agentes de código.
        for nome in ("OVERCODE.md", "CLAUDE.md", "AGENTS.md"):
            p = os.path.join(d, nome)
            if os.path.isfile(p):
                return p
        if d in (home, "/") or os.path.dirname(d) == d:
            break
        d = os.path.dirname(d)
    return None


def limite_texto():
    ctx = E.backend["ctx"] if E.backend else 4096
    return 450 if ctx <= 4096 else 1200 if ctx <= 8000 else 3500


def texto_memoria():
    lim = limite_texto()
    s = ""
    mem = le_memoria()
    if mem:
        s += " MEMÓRIA do usuário (siga sempre): " + "; ".join(mem)[-lim:] + "."
    p = acha_overcode_md()
    if p:
        try:
            corpo = re.sub(r"\s+", " ", open(p, encoding="utf-8", errors="ignore").read()).strip()
            s += f" INSTRUÇÕES DO PROJETO ({os.path.basename(p)}): " + corpo[:lim] + "."
        except OSError:
            pass
    return s


def cmd_memory(arg=""):
    arg = arg.strip()
    sub, _, resto = arg.partition(" ")
    sub = sub.lower()
    if not sub:
        esc = menu("Memória", ["Ver o que está memorizado", "Adicionar uma lembrança", "Remover uma lembrança",
                               "Apagar tudo (reset)", "Ver o OVERCODE.md deste projeto"], permitir_outro=False, cancela=4 + 1 - 1)
        sub = {"Ver": "list", "Adic": "add", "Remo": "remove", "Apag": "reset"}.get(esc[:4], "projeto")
    itens = le_memoria()
    if sub in ("list", "listar", "ver"):
        if not itens:
            fala("idle", "Nada memorizado ainda. Use  # sua lembrança  ou  /memory add texto")
        for n, i in enumerate(itens, 1):
            print(cor("dim", f"  {n:>2}. ") + i)
    elif sub in ("add", "adicionar"):
        txt = resto or input(cor("lar", "  o que lembrar? > ")).strip()
        if add_memoria(txt):
            print(cor("lar", "  ✦ ") + cor("verde", "Memorizado: ") + txt)
    elif sub in ("remove", "remover", "rm"):
        if not itens:
            fala("idle", "Não há nada para remover.")
            return
        if resto.strip().isdigit():
            n = int(resto.strip()) - 1
        else:
            alvo = menu("Remover qual?", [i[:60] for i in itens], permitir_outro=False)
            n = next(k for k, i in enumerate(itens) if i[:60] == alvo)
        if 0 <= n < len(itens):
            print(cor("lar", "  ✦ ") + "Removido: " + itens.pop(n))
            salva_memoria(itens)
    elif sub in ("reset", "limpar", "apagar"):
        r = menu("Apagar TODA a memória?", ["Não", "Sim, apagar tudo"], permitir_outro=False, cancela=0)
        if r.startswith("Sim"):
            salva_memoria([])
            fala("idle", "Memória apagada.")
    elif sub in ("projeto", "md"):
        p = acha_overcode_md()
        if not p:
            fala("idle", "Este projeto ainda não tem OVERCODE.md. Rode /init para criar.")
        else:
            print(cor("dim", "  " + p.replace(HOME, "~", 1)))
            print(open(p, encoding="utf-8", errors="ignore").read()[:1500])
    else:
        print(cor("dim", "  Use: /memory list | add <texto> | remove <n> | reset"))


def lembra_da_resposta(resp):
    """Se a IA escreveu 'LEMBRAR: texto', guarda na memória."""
    for m in re.finditer(r"^\s*LEMBRAR:\s*(.+)$", resp, re.M):
        if add_memoria(m.group(1)):
            print(cor("lar", "  ✦ ") + cor("verde", "Memória atualizada: ") + cor("dim", m.group(1).strip()[:100]))


def cmd_init():
    """Cria o OVERCODE.md do projeto (regras e contexto que valem em toda conversa nesta pasta)."""
    alvo = os.path.join(E.cwd, "OVERCODE.md")
    if os.path.realpath(E.cwd) == os.path.realpath(HOME):
        fala("idle", cor("amar", "Você está na pasta pessoal. Entre numa pasta de projeto com /folder e rode /init de novo."))
        return
    if os.path.isfile(alvo):
        fala("idle", "Já existe um OVERCODE.md aqui. Abra com /memory projeto.")
        return
    arqs = []
    for atual, dirs, fs in os.walk(E.cwd):
        dirs[:] = [d for d in dirs if d not in IGN_DIRS and not d.startswith(".")]
        if atual[len(E.cwd):].count("/") >= 2:
            dirs[:] = []
        arqs += [os.path.relpath(os.path.join(atual, f), E.cwd) for f in fs if not f.startswith(".")]
        if len(arqs) > 60:
            break
    leia = ""
    for nome in ("README.md", "README.txt", "package.json", "pyproject.toml", "requirements.txt"):
        p = os.path.join(E.cwd, nome)
        if os.path.isfile(p):
            leia += f"\n--- {nome} ---\n" + open(p, encoding="utf-8", errors="ignore").read()[:700]
    corpo = ""
    if E.backend:
        pedido = ("Escreva um arquivo OVERCODE.md em português para este projeto, com no máximo 12 linhas em markdown: "
                  "o que o projeto é, como rodar/testar, e regras de estilo. Responda SÓ com o markdown, sem bloco de código.\n"
                  f"Pasta: {os.path.basename(E.cwd)}\nArquivos: {', '.join(arqs[:50])}\n{leia}")
        spin.start("Analisando o projeto")
        corpo = consulta(E.backend, "Você é um assistente que documenta projetos de código.", [{"role": "user", "content": pedido}], 500)
        spin.stop()
        corpo = re.sub(r"^```\w*\n|\n```$", "", corpo.strip())
    if len(corpo) < 40:
        corpo = (f"# {os.path.basename(E.cwd)}\n\nProjeto criado pelo Overcode.\n\n## Como rodar\n- (descreva aqui)\n\n"
                 "## Regras\n- Responder em português.\n- Mudanças pequenas e testadas.\n")
    print(cor("dim", "\n".join("  │ " + l for l in corpo.splitlines()[:14])))
    r = menu("Criar o OVERCODE.md com esse conteúdo?", ["Sim", "Não"], permitir_outro=False, cancela=1)
    if r == "Sim":
        with open(alvo, "w", encoding="utf-8") as f:
            f.write(corpo.strip() + "\n")
        fala("feliz", "Criei " + cor("verde", "OVERCODE.md") + ". Vou ler ele em toda conversa nesta pasta. Edite como quiser!")


# ---------- skills (habilidades) ----------
def sem_acento(t):
    return "".join(c for c in unicodedata.normalize("NFD", t.lower()) if unicodedata.category(c) != "Mn")


def le_skills():
    """Skills do usuário em ~/.overcode/skills/<nome>/SKILL.md (com cabeçalho name/description) + as padrão."""
    r = []
    if os.path.isdir(SKILLS):
        for d in sorted(os.listdir(SKILLS)):
            p = os.path.join(SKILLS, d, "SKILL.md")
            if not os.path.isfile(p):
                continue
            txt = open(p, encoding="utf-8", errors="ignore").read()
            desc, gatilhos, corpo = "", "", txt
            m = re.match(r"---\n(.*?)\n---\n?(.*)", txt, re.S)
            if m:
                corpo = m.group(2)
                for l in m.group(1).splitlines():
                    k, _, v = l.partition(":")
                    if k.strip() == "description":
                        desc = v.strip()
                    elif k.strip() in ("gatilhos", "triggers"):
                        gatilhos = v.strip()
            else:
                desc = next((l.strip("# ").strip() for l in txt.splitlines() if l.strip()), "")
            r.append({"nome": d, "desc": desc[:140], "gatilhos": gatilhos, "corpo": corpo.strip(), "usuario": True})
    nomes = {s["nome"] for s in r}
    for n, t in PADRAO.items():
        if n not in nomes:
            r.append({"nome": n, "desc": "padrão do Overcode", "gatilhos": "", "corpo": t, "usuario": False})
    return r


def texto_skills():
    us = [s for s in le_skills() if s["usuario"]]
    if not us:
        return ""
    lista = "; ".join(f"{s['nome']}" + (f" ({s['desc'][:50]})" if s["desc"] else "") for s in us[:8])
    return f" Habilidades em ~/.overcode/skills/<nome>/SKILL.md (leia com cat quando o pedido combinar): {lista}."


def dicas_skills(msg):
    achadas, vistos = [], set()
    for rx, nome in ROTAS:  # padrões antigos (imagem, vídeo)
        if re.search(rx, msg, re.I):
            p = os.path.join(SKILLS, nome, "SKILL.md")
            if os.path.isfile(p):
                achadas.append((nome, open(p, encoding="utf-8", errors="ignore").read()[:900]))
            elif nome in PADRAO:
                achadas.append((nome, PADRAO[nome]))
            vistos.add(nome)
    palavras = set(re.findall(r"[a-z0-9]{4,}", sem_acento(msg)))
    for s in le_skills():
        if not s["usuario"] or s["nome"] in vistos:
            continue
        chaves = set(re.findall(r"[a-z0-9]{4,}", sem_acento(s["nome"] + " " + s["desc"] + " " + s["gatilhos"])))
        if len(chaves & palavras) >= (1 if s["gatilhos"] else 2) or s["nome"].lower() in msg.lower():
            achadas.append((s["nome"], s["corpo"][:900]))
    return achadas


def cmd_skills(arg=""):
    sk = le_skills()
    esc = menu("Habilidades", ["Ver as habilidades", "Criar uma habilidade nova", "Onde ficam os arquivos"],
               permitir_outro=False, cancela=2) if not arg else arg.strip().lower()
    if esc.startswith(("Ver", "list")):
        for s in sk:
            print(cor("lar", "  ✦ ") + cor("neg", s["nome"]) + cor("dim", " — " + (s["desc"] or "sem descrição")))
        print(cor("dim", "  As do Overcode (padrão) valem sempre; as suas ficam em ~/.overcode/skills/"))
    elif esc.startswith(("Criar", "new", "criar")):
        nome = re.sub(r"[^a-z0-9-]", "-", sem_acento(input(cor("lar", "  nome (ex.: resumir-pdf) > "))).strip().lower()).strip("-")
        if not nome:
            return
        desc = input(cor("lar", "  quando usar? (uma frase) > ")).strip()
        passos = input(cor("lar", "  como fazer? (instruções) > ")).strip()
        pasta = os.path.join(SKILLS, nome)
        os.makedirs(pasta, exist_ok=True)
        with open(os.path.join(pasta, "SKILL.md"), "w", encoding="utf-8") as f:
            f.write(f"---\nname: {nome}\ndescription: {desc}\n---\n{passos}\n")
        fala("feliz", f"Habilidade {cor('verde', nome)} criada. Quando o pedido combinar, eu uso sozinha.")
    else:
        print(cor("dim", "  " + SKILLS.replace(HOME, "~", 1) + "/<nome>/SKILL.md"))


def prompt_sistema():
    base = (
        "Você é Kelly, a agente de programação do Overcode, inspirada no fluxo de trabalho do Claude Code, mas com identidade própria. "
        "Responda em português claro e natural. Sua prioridade é concluir corretamente o pedido, não apenas explicar como fazê-lo. "
        "Trabalhe como agente: entenda o objetivo; inspecione o ambiente e os arquivos relevantes; faça um plano interno curto; "
        "execute uma mudança pequena por vez; leia a saída; verifique o resultado com testes ou inspeção; corrija falhas; "
        "e só declare concluído quando houver evidência. Nunca invente arquivos, saídas, testes ou sucesso. "
        "Você tem um terminal persistente. Para executar AGORA, responda com exatamente UM bloco ```bash contendo o próximo comando e nada depois dele; "
        "aguarde a saída antes de decidir o próximo passo. Não coloque exemplos, comandos futuros ou comandos opcionais nesse bloco. "
        "Se precisar apenas explicar, responda em texto normal sem bloco. Nunca peça ao usuário para copiar comandos que você pode executar. "
        "Use comandos compatíveis com o ambiente detectado; não suponha que está no Termux se o terminal estiver conectado por SSH. "
        "Antes de editar, leia o arquivo e preserve o estilo existente. Prefira patches pequenos e reversíveis. "
        "Não sobrescreva arquivos importantes sem backup; não apague dados, não formate discos, não altere firewall/SSH/boot e não reinicie serviços críticos sem confirmação explícita. "
        "Nunca exponha chaves, tokens, senhas ou conteúdo de arquivos secretos. Não coloque segredos em comandos, histórico ou logs. "
        "Não instale dependências se houver alternativa já disponível; se for realmente necessário, peça confirmação. "
        "Para pedidos ambíguos, faça uma pergunta curta somente quando faltar informação essencial; caso contrário, escolha a opção segura e explique a suposição. "
        "Se um comando falhar, interprete a mensagem e tente uma abordagem diferente; não repita cegamente. "
        "Para ver sintaxe de comandos, escreva uma linha MANUAL: nome. Para pedir esclarecimento, use PERGUNTA: texto e 2 a 4 opções em linhas iniciadas por '- '. "
        "Se o usuário pedir para guardar algo, escreva LEMBRAR: texto curto. Ao terminar, informe o que mudou, os testes feitos e qualquer limitação. "
        "Comandos curtos e simples; não abra editores ou programas interativos como nano, vim, top ou python sem argumentos. "
        "SSH: para conectar, use um bloco com ssh -o StrictHostKeyChecking=accept-new usuario@host; depois os comandos rodam no servidor até exit. "
        "Salve criações nas pastas $FOTOS, $VIDEOS ou $ARQUIVOS conforme o tipo. No Termux, use termux-open para abrir arquivos. "
    )
    if CFG["modo"] == "plano":
        base = ("MODO PLANO: NÃO execute nada e NÃO escreva blocos bash. Apresente de 3 a 7 passos numerados, objetivos, "
                "com riscos e testes relevantes. Espere a aprovação do usuário. ") + base
    return base + texto_ssh() + texto_memoria() + texto_skills() + texto_emocao()

# ---------- menções @arquivo (também imagens/capturas de tela) ----------
def expande_mencoes(txt):
    """Troca @caminho pelo conteúdo do arquivo (texto), listagem (pasta) ou anexo (imagem). Devolve (texto, img)."""
    img, extra = None, ""
    for m in list(re.finditer(r"(?<!\S)@([^\s@]+)", txt))[:4]:
        cand = m.group(1).rstrip(".,;:!?)")
        p = os.path.expanduser(cand)
        p = p if os.path.isabs(p) else os.path.join(E.cwd, p)
        if os.path.isdir(p):
            nomes = sorted(os.listdir(p))[:40]
            extra += f"\n[Pasta @{cand}: {', '.join(nomes)}]"
        elif os.path.isfile(p):
            ext = os.path.splitext(p)[1].lower()
            if ext in IMGS and os.path.getsize(p) < 4_000_000:
                img = img or p
                extra += f"\n[Imagem anexada: \"{p}\"]"
            else:
                try:
                    corpo = open(p, encoding="utf-8", errors="ignore").read(3000)
                    extra += f"\n[Arquivo @{cand} (\"{p}\"), início:\n{corpo}]"
                except OSError:
                    pass
        else:
            continue
        print(cor("lar", "  ✦ ") + cor("dim", "anexei @" + cand))
    return txt + extra, img


# ---------- sessões salvas (/resume) ----------
def salva_sessao():
    hist = [{"role": m["role"], "content": m["content"]} for m in E.historia if isinstance(m["content"], str)]
    if not hist or not E.sessao_id:
        return
    primeiro = next((m["content"] for m in hist if m["role"] == "user"), "")
    titulo = re.sub(r"\s+", " ", re.sub(r"\[[^\]]*\]", "", primeiro)).strip()[:48] or "conversa"
    _grava_json(os.path.join(SESSOES, E.sessao_id + ".json"),
                {"id": E.sessao_id, "titulo": titulo, "cwd": E.cwd, "historia": hist})
    arqs = sorted((os.path.join(SESSOES, f) for f in os.listdir(SESSOES) if f.endswith(".json")),
                  key=os.path.getmtime, reverse=True)
    for velho in arqs[30:]:
        try:
            os.remove(velho)
        except OSError:
            pass


def lista_sessoes():
    r = []
    try:
        for f in os.listdir(SESSOES):
            if f.endswith(".json"):
                p = os.path.join(SESSOES, f)
                d = _le_json(p, None)
                if d and d.get("historia") and d.get("id") != E.sessao_id:
                    r.append({"id": d["id"], "titulo": d.get("titulo", "conversa"), "cwd": d.get("cwd", HOME),
                              "historia": d["historia"], "mtime": os.path.getmtime(p)})
    except OSError:
        pass
    return sorted(r, key=lambda s: s["mtime"], reverse=True)


def carrega_sessao(s):
    E.historia = list(s["historia"])
    if os.path.isdir(s["cwd"]):
        E.cwd = s["cwd"]
    E.checkpoints = []
    fala("feliz", f"Conversa retomada: {cor('verde', s['titulo'])} ({len(E.historia)} mensagens)")


def cmd_resume(ultima=False):
    ss = lista_sessoes()
    if not ss:
        fala("idle", "Ainda não há conversas anteriores para retomar.")
        return
    if ultima:
        carrega_sessao(ss[0])
        return
    ops = [f"{atras(s['mtime'])} · {s['titulo']}" for s in ss[:9]] + ["Cancelar"]
    esc = menu("Retomar qual conversa?", ops, permitir_outro=False, cancela=len(ops) - 1)
    if esc != "Cancelar":
        carrega_sessao(ss[ops.index(esc)])


# ---------- checkpoints de arquivos + diff colorido + /rewind ----------
IGN_DIRS = {".git", "node_modules", "__pycache__", ".cache", ".npm", "storage", ".venv", "venv", ".gradle", "dist", "build"}


def foto_arquivos(raiz=None):
    """Guarda o conteúdo dos arquivos pequenos da pasta do projeto (None na pasta pessoal: grande demais)."""
    raiz = os.path.abspath(raiz or E.cwd)
    if os.path.realpath(raiz) in (os.path.realpath(HOME), "/", os.path.realpath(BASE)):
        return None
    r, total = {}, 0
    nivel0 = raiz.rstrip("/").count("/")
    for atual, dirs, fs in os.walk(raiz):
        dirs[:] = [d for d in dirs if d not in IGN_DIRS and not d.startswith(".")]
        if atual.count("/") - nivel0 >= 4:
            dirs[:] = []
        for f in fs:
            p = os.path.join(atual, f)
            try:
                tam = os.path.getsize(p)
                if tam > 300_000 or total + tam > 20_000_000 or len(r) >= 400:
                    continue
                with open(p, "rb") as fh:
                    r[p] = fh.read()
                total += tam
            except OSError:
                continue
    return r


def mostra_diff(antes, depois, raiz):
    if antes is None or depois is None:
        return
    mudou = [p for p in sorted(set(antes) | set(depois)) if antes.get(p) != depois.get(p)]
    for k, p in enumerate(mudou):
        if k >= 3:
            print(cor("dim", f"  … e mais {len(mudou) - 3} arquivo(s) mudaram"))
            break
        a, b = antes.get(p), depois.get(p)
        rel = os.path.relpath(p, raiz)
        verbo = "Criou" if a is None else "Apagou" if b is None else "Editou"
        try:
            ta = (a or b"").decode("utf-8")
            tb = (b or b"").decode("utf-8")
        except UnicodeDecodeError:
            print(cor("lar", "  ● ") + cor("neg", verbo) + cor("dim", f"({rel}) arquivo binário"))
            continue
        dif = [l for l in difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm="", n=1)
               if not l.startswith(("---", "+++"))]
        mais = sum(1 for l in dif if l.startswith("+"))
        menos = sum(1 for l in dif if l.startswith("-"))
        print(cor("lar", "  ● ") + cor("neg", verbo) + cor("dim", f"({rel})  +{mais} -{menos}"))
        cols = shutil.get_terminal_size((50, 20)).columns
        for l in [x for x in dif if not x.startswith("@@")][:8]:
            l = l[:cols - 6].ljust(min(cols - 6, 60))
            if l.startswith("+"):
                print("   " + C["fundo_verde"] + l + C["r"])
            elif l.startswith("-"):
                print("   " + C["fundo_verm"] + l + C["r"])
            else:
                print(cor("dim", "   " + l))
        if len(dif) > 9:
            print(cor("dim", f"   … +{len(dif) - 9} linhas"))


def ponto_de_retorno(rotulo):
    E.checkpoints.append({"hist": len(E.historia), "rotulo": re.sub(r"\s+", " ", rotulo)[:50],
                          "arq": foto_arquivos(), "cwd": E.cwd})
    E.checkpoints = E.checkpoints[-12:]


def restaura_arquivos(cp):
    if cp["arq"] is None:
        fala("idle", cor("amar", "Nesta pasta não guardo arquivos (pasta pessoal). Entre numa pasta de projeto com /folder."))
        return
    atual = foto_arquivos(cp["cwd"]) or {}
    apagados = voltaram = 0
    for p in atual:
        if p not in cp["arq"]:
            try:
                os.remove(p)
                apagados += 1
            except OSError:
                pass
    for p, conteudo in cp["arq"].items():
        if atual.get(p) != conteudo:
            try:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "wb") as f:
                    f.write(conteudo)
                voltaram += 1
            except OSError:
                pass
    fala("feliz", f"Arquivos de volta: {voltaram} restaurado(s), {apagados} apagado(s).")


def cmd_rewind():
    cps = E.checkpoints[-8:]
    if not cps:
        fala("idle", "Ainda não há pontos para voltar nesta conversa.")
        return
    ops = [f"{n + 1}. {c['rotulo']}" for n, c in enumerate(cps)] + ["Cancelar"]
    esc = menu("Voltar para ANTES de qual mensagem?", ops, permitir_outro=False, cancela=len(ops) - 1,
               dica="o ponto é salvo antes de cada pedido seu")
    if esc == "Cancelar":
        return
    cp = cps[ops.index(esc)]
    o = menu("O que voltar?", ["Conversa e arquivos", "Só a conversa", "Só os arquivos", "Cancelar"],
             permitir_outro=False, cancela=3)
    if o == "Cancelar":
        return
    if o != "Só os arquivos":
        E.historia = E.historia[:cp["hist"]]
        E.checkpoints = E.checkpoints[:E.checkpoints.index(cp)]
        E.todo, E.feitos = [], 0
        fala("feliz", "Conversa voltou para antes de: " + cor("verde", cp["rotulo"]))
    if o != "Só a conversa":
        restaura_arquivos(cp)


# ---------- /compact e /context ----------
def compacta(auto=False):
    if len(E.historia) < 4:
        if not auto:
            fala("idle", "A conversa ainda está curta; não há o que compactar.")
        return False
    ult = max((i for i, m in enumerate(E.historia) if m["role"] == "user"), default=0)
    velho, cauda = E.historia[:ult], E.historia[ult:]
    if len(velho) < 2:
        return False
    texto = "\n".join(f"{m['role']}: {str(m['content'])[:400]}" for m in velho)[-6000:]
    spin.start("Compactando a conversa")
    resumo = consulta(E.backend, "Você resume conversas de terminal com precisão.",
                      [{"role": "user", "content": "Resuma em até 8 linhas, em português: o que o usuário pediu, o que já foi feito, "
                                                   "caminhos de arquivos importantes e o que falta fazer.\n\n" + texto}], 350)
    spin.stop()
    if len(resumo.strip()) < 20:
        fala("erro", "Não consegui resumir agora. A conversa continua como estava.")
        return False
    antes = sum(tokens(str(m["content"])) for m in E.historia)
    E.historia = [{"role": "user", "content": "[Resumo da conversa até aqui]\n" + resumo.strip()},
                  {"role": "assistant", "content": "Entendido. Sigo a partir desse resumo."}] + cauda
    depois = sum(tokens(str(m["content"])) for m in E.historia)
    print(cor("lar", "● ") + cor("neg", "Conversa compactada ") + cor("dim", f"(~{antes} → ~{depois} tokens)"))
    salva_sessao()
    return True


def cmd_context():
    if not E.backend:
        fala("idle", "Escolha uma IA primeiro com /model.")
        return
    sis, msgs, ctx, pct = uso_contexto()
    c = "verde" if pct < 60 else "amar" if pct < 85 else "verm"
    print(cor("lar", "● ") + cor("neg", "Janela de contexto") + cor("dim", f"  {modelo_txt()}"))
    print("  " + barra(pct, c, 24) + cor(c, f" {pct}%") + cor("dim", f"  ({sis + msgs}/{ctx} tokens)"))
    print(cor("dim", f"  regras, memória e habilidades: ~{sis} · conversa: ~{msgs} ({len(E.historia)} mensagens)"))
    if pct >= 70:
        print(cor("amar", "  Está enchendo: a IA fica 'mais burra' com a janela cheia. Use /compact ou /clear."))


# ---------- lista de tarefas (modo plano) ----------
def extrai_passos(resp):
    passos = [re.sub(r"\*+", "", m.group(2)).strip()[:80] for m in re.finditer(r"^\s*(\d+)[.)]\s+(.+)$", resp, re.M)]
    return passos[:8] if len(passos) >= 2 else []


def mostra_todo():
    if not E.todo or T.on:
        return
    print(cor("lar", "● ") + cor("neg", "Atualizando tarefas"))
    for i, t in enumerate(E.todo):
        print(cor("dim", "  ⎿ " if i == 0 else "    ") + (cor("risc", "☒ " + t) if i < E.feitos else "☐ " + t))


def passo_feito():
    if E.todo and E.feitos < len(E.todo) - 1:
        E.feitos += 1
        mostra_todo()


def fim_todo():
    if E.todo:
        E.feitos = len(E.todo)
        mostra_todo()
        E.todo, E.feitos = [], 0


# ---------- chamada simples (sem streaming): conselho, /compact, /init ----------
def consulta(B, sistema, msgs, max_tokens=300, timeout=300):
    if not B:
        return ""
    hist = [{"role": m["role"], "content": m["content"] if isinstance(m["content"], str) else ""} for m in msgs]
    if B.get("gemma"):
        if hist:
            hist[0] = {"role": "user", "content": sistema + "\n\n" + hist[0]["content"]}
        mensagens = hist
    else:
        mensagens = [{"role": "system", "content": sistema}] + hist
    corpo = {"model": B["modelo"], "messages": mensagens, "stream": False, "max_tokens": max_tokens, "temperature": 0.4}
    if B["nivel"] != "Nuvem":
        corpo.update(repeat_penalty=1.15, top_k=40, top_p=0.9)
    heads = {"Content-Type": "application/json"}
    if B["chave"]:
        heads["Authorization"] = "Bearer " + B["chave"]
    try:
        req = urllib.request.Request(B["url"] + "/chat/completions", data=json.dumps(corpo).encode(), headers=heads)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8", "ignore"))
        txt = (d["choices"][0]["message"]["content"] or "").strip()
    except Exception:
        return ""
    E.uso_in += sum(tokens(m["content"]) for m in mensagens)
    E.uso_out += tokens(txt)
    return txt


# ---------- IAs na nuvem (chave de API de cada provedor) ----------
# id: (nome, endereço base compatível com OpenAI, modelo padrão, onde pegar a chave)
PROVEDORES = {
    "gemini": ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", GEMINI_MODELO, "aistudio.google.com/apikey"),
    "openai": ("OpenAI", "https://api.openai.com/v1", "", "platform.openai.com/api-keys"),
    "groq": ("Groq", "https://api.groq.com/openai/v1", "", "console.groq.com/keys"),
    "openrouter": ("OpenRouter", "https://openrouter.ai/api/v1", "", "openrouter.ai/keys"),
    "deepseek": ("DeepSeek", "https://api.deepseek.com/v1", "", "platform.deepseek.com/api_keys"),
    "outra": ("Outra (compatível com OpenAI)", "", "", ""),
}
CATEGORIAS = ["Fraco", "Médio", "Forte", "Máximo"]
FAIXA = {"Fraco": "leves e rápidas", "Médio": "equilíbrio", "Forte": "capazes, mais lentas", "Máximo": "as maiores"}


def carrega_provs():
    d = _le_json(PROVEDORES_ARQ, {})
    if "gemini" not in d and os.path.isfile(CHAVE):  # chave guardada pela versão 1
        try:
            d["gemini"] = {"chave": open(CHAVE).read().strip(), "modelo": GEMINI_MODELO}
            _grava_json(PROVEDORES_ARQ, d, privado=True)
        except OSError:
            pass
    return d


def provs_prontos():
    d = carrega_provs()
    r = []
    for pid, (_, _, mod, _) in PROVEDORES.items():
        c = d.get(pid, {})
        if c.get("chave") and (c.get("modelo") or mod) and (pid != "outra" or c.get("url")):
            r.append(pid)
    return r


def backend_nuvem(pid):
    c = carrega_provs().get(pid, {})
    nome, url, mod, _ = PROVEDORES[pid]
    return {"nome": nome, "url": c.get("url") or url, "modelo": c.get("modelo") or mod, "chave": c["chave"],
            "ctx": 16000, "gemma": False, "nivel": "Nuvem", "prov": pid}


def configura_provedor(pid, forcar=False):
    nome, url, mod, onde = PROVEDORES[pid]
    d = carrega_provs()
    cur = d.get(pid, {})
    if cur.get("chave") and (cur.get("modelo") or mod) and not forcar:
        return True
    if onde:
        print(cor("dim", "  Pegue sua chave em: " + onde))
    chave = os.environ.get("GEMINI_API_KEY", "").strip() if pid == "gemini" else ""
    if not chave:
        chave = input(cor("lar", f"  Cole a chave de {nome} (fica só neste aparelho) > ")).strip()
    if not chave:
        return False
    modelo = cur.get("modelo") or mod
    if not modelo:
        modelo = input(cor("lar", "  Nome do modelo (como aparece no painel do provedor) > ")).strip()
        if not modelo:
            return False
    novo = {"chave": chave, "modelo": modelo}
    if pid == "outra":
        novo["url"] = input(cor("lar", "  Endereço base da API (ex.: https://servidor/v1) > ")).strip().rstrip("/")
        if not novo["url"]:
            return False
    d[pid] = novo
    _grava_json(PROVEDORES_ARQ, d, privado=True)
    fala("feliz", f"Chave de {nome} guardada.")
    return True


def adiciona_chave():
    nomes = [v[0] for v in PROVEDORES.values()]
    esc = menu("Adicionar ou trocar chave de qual IA?", nomes + ["Cancelar"], permitir_outro=False, cancela=len(nomes))
    if esc != "Cancelar":
        configura_provedor(list(PROVEDORES)[nomes.index(esc)], forcar=True)


def internet_ok():
    try:
        urllib.request.urlopen("https://generativelanguage.googleapis.com", timeout=4)
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


def grava_ultimo(cod):
    try:
        with open(ULTIMO, "w") as f:
            f.write(cod)
    except OSError:
        pass


# ---------- escolher a IA: categorias, "usar todas" e Ultra ----------
def usa_local(m):
    if not os.path.isfile(caminho(m)):
        r = input(f"Baixar {m[1]} (~{m[4]} GB)? [s/n] ").strip().lower()
        if r != "s" or not baixar(m):
            return False
    if sobe_servidor(m):
        E.grupo = None
        grava_ultimo(m[0])
        CFG["ultimo_local"] = m[0]
        salva_cfg()
        return True
    return False


def usa_nuvem(pid):
    if not configura_provedor(pid):
        return False
    parar_servidor()
    E.backend = backend_nuvem(pid)
    E.grupo = None
    grava_ultimo("n:" + pid)
    return True


def specs_local(cat=None):
    return [{"tipo": "local", "m": m} for m in CATALOGO if cat is None or m[5] == cat]


def specs_nuvem():
    return [{"tipo": "nuvem", "pid": p} for p in provs_prontos()]


def nome_spec(x):
    if x["tipo"] == "local":
        return x["m"][1]
    c = backend_nuvem(x["pid"])
    return f"{c['nome']} ({c['modelo']})"


def liga(x):
    """Deixa o membro x pronto como IA ativa (sobe o motor local ou aponta para a nuvem)."""
    if x["tipo"] == "nuvem":
        parar_servidor()
        E.backend = backend_nuvem(x["pid"])
        return True
    vivo = E.servidor is not None and E.servidor.poll() is None
    if vivo and E.modelo is x["m"] and E.backend and E.backend["nivel"] != "Nuvem":
        return True
    return sobe_servidor(x["m"])


def ativa_grupo(nome, membros, codigo):
    faltam = [x for x in membros if x["tipo"] == "local" and not os.path.isfile(caminho(x["m"]))]
    if faltam:
        gb = sum(x["m"][4] for x in faltam)
        op = menu(f"Faltam {len(faltam)} IA(s) ({gb:.1f} GB). O que fazer?",
                  ["Baixar as que faltam", "Usar só as já baixadas", "Cancelar"], permitir_outro=False, cancela=2)
        if op == "Cancelar":
            return False
        if op.startswith("Baixar"):
            for x in faltam:
                if not baixar(x["m"]):
                    break
        membros = [x for x in membros if x["tipo"] != "local" or os.path.isfile(caminho(x["m"]))]
    if not membros:
        fala("erro", "Nenhuma IA disponível nesse grupo. Baixe uma ou adicione uma chave da nuvem.")
        return False
    nuvem = [x for x in membros if x["tipo"] == "nuvem"]
    lider = nuvem[0] if nuvem else max(membros, key=lambda x: x["m"][4])
    if not liga(lider):
        return False
    E.grupo = {"nome": nome, "membros": membros, "lider": lider} if len(membros) > 1 else None
    grava_ultimo(codigo)
    if E.grupo:
        locais = sum(1 for x in membros if x["tipo"] == "local")
        print(cor("lar", "✦ ") + cor("neg", f"{nome}: {len(membros)} IAs no conselho") + cor("dim", f" — líder: {nome_spec(lider)}"))
        print(cor("dim", "  Em cada pedido todas opinam e a líder decide e executa."))
        if locais >= 2:
            print(cor("dim", "  As locais carregam uma de cada vez: no celular cada pedido demora mais."))
    return True


def categoria_todas(cat):
    if cat == "Nuvem":
        return ativa_grupo("Nuvem (todas)", specs_nuvem(), "g:Nuvem")
    return ativa_grupo(f"{cat} (todas)", specs_local(cat), "g:" + cat)


def ultra():
    return ativa_grupo("Ultra", specs_local() + specs_nuvem(), "u")


def menu_categoria(cat):
    ms = [m for m in CATALOGO if m[5] == cat]
    ops = [f"★ Usar todas desta categoria ({len(ms)})"]
    ops += [f"{m[1]} · {m[4]:.1f} GB · " + ("baixada" if os.path.isfile(caminho(m)) else "não baixada") for m in ms]
    ops.append("← Voltar")
    esc = menu(f"Categoria {cat} ({FAIXA[cat]})", ops, permitir_outro=False, cancela=len(ops) - 1)
    i = ops.index(esc)
    if i == 0:
        return categoria_todas(cat)
    if i == len(ops) - 1:
        return None
    return usa_local(ms[i - 1])


def menu_nuvem():
    prontos = provs_prontos()
    ops = [f"{PROVEDORES[p][0]} · {backend_nuvem(p)['modelo']}" for p in prontos]
    todas = len(prontos) >= 2
    if todas:
        ops.insert(0, f"★ Usar todas da nuvem ({len(prontos)})")
    ops += ["+ Adicionar ou trocar uma chave", "← Voltar"]
    esc = menu("Categoria Nuvem (rápidas, precisam de internet)", ops, permitir_outro=False, cancela=len(ops) - 1)
    if esc.startswith("★"):
        return categoria_todas("Nuvem")
    if esc.startswith("+"):
        adiciona_chave()
        return None
    if esc.startswith("←"):
        return None
    return usa_nuvem(prontos[ops.index(esc) - (1 if todas else 0)])


def menu_categorias():
    while True:
        ops = []
        for cat in CATEGORIAS:
            ms = [m for m in CATALOGO if m[5] == cat]
            baix = sum(os.path.isfile(caminho(m)) for m in ms)
            ops.append(f"{cat:<7} {len(ms)} IAs · {baix} baixada(s) · {FAIXA[cat]}")
        ops.append(f"Nuvem   {len(provs_prontos())} com chave · rápidas ⚡")
        ops.append("Ultra   usa TODAS as IAs de TODAS as categorias")
        if E.backend:
            ops.append("← Manter a IA atual")
        esc = menu("Escolha a categoria de IA", ops, permitir_outro=False, cancela=len(ops) - 1 if E.backend else None,
                   dica="no celular, Fraco e Médio são rápidos; Forte e Máximo ficam lentos")
        if esc.startswith("←"):
            return False
        cat = esc.split()[0]
        r = ultra() if cat == "Ultra" else menu_nuvem() if cat == "Nuvem" else menu_categoria(cat)
        if r is True:
            return True


def lista_modelos():
    menu_categorias()


def escolhe_modelo(cod=None):
    """Sem argumento: abre o menu de categorias. Com código salvo (ex.: '5', 'n:gemini', 'g:Médio', 'u'): reativa."""
    if cod is None:
        return menu_categorias()
    cod = "n:gemini" if cod == "g" else cod
    if cod == "u":
        return ultra()
    if cod.startswith("g:"):
        return categoria_todas(cod[2:])
    if cod.startswith("n:"):
        return usa_nuvem(cod[2:])
    m = next((x for x in CATALOGO if x[0] == cod), None)
    return usa_local(m) if m else False


# ---------- conselho: todas as IAs do grupo opinam, a líder decide ----------
SIS_CONSELHO = ("Você é conselheira técnica num comitê de IAs. Dê a sua melhor resposta ou plano em no máximo 6 linhas, "
                "em português. NÃO escreva blocos de código nem comandos para executar; só orientação.")


def conselho(entrada):
    g = E.grupo
    if not g:
        return ""
    lider = g["lider"]
    outros = [x for x in g["membros"] if x is not lider]
    ult = [m for m in E.historia if isinstance(m["content"], str)][-4:]
    while ult and ult[0]["role"] != "user":
        ult.pop(0)
    while ult and ult[-1]["role"] != "assistant":
        ult.pop()
    msgs = ult + [{"role": "user", "content": entrada}]
    res, fios = {}, []

    def nuvem(x):
        res[id(x)] = consulta(backend_nuvem(x["pid"]), SIS_CONSELHO, msgs, 300)

    for x in outros:
        if x["tipo"] == "nuvem":
            t = threading.Thread(target=nuvem, args=(x,), daemon=True)
            t.start()
            fios.append(t)
    locais = [x for x in outros if x["tipo"] == "local"]
    for i, x in enumerate(locais, 1):
        print(cor("lar", "● ") + cor("neg", "Consultando " + x["m"][1]) + cor("dim", f" ({i}/{len(locais)})"))
        if not sobe_servidor(x["m"]):
            continue
        spin.start("Ouvindo " + x["m"][1])
        res[id(x)] = consulta(E.backend, SIS_CONSELHO, msgs, 300)
        spin.stop()
    for t in fios:
        t.join(timeout=300)
    liga(lider)
    linhas = []
    for x in outros:
        r = res.get(id(x), "")
        if not r:
            continue
        print(cor("lar", "  ✦ ") + cor("neg", nome_spec(x)) + cor("dim", " opinou:"))
        for l in r.splitlines()[:4]:
            print(cor("dim", "    " + l[:150]))
        linhas.append(f"- {nome_spec(x)}: {r[:600]}")
    if not linhas:
        return ""
    return "\n\n[Opiniões das outras IAs do conselho. Considere, mas decida você e siga as regras.]\n" + "\n".join(linhas)


# ---------- chaves de API do próprio Overcode ----------
def apikeys_lista():
    return _le_json(APIKEYS, [])


def cria_apikey(nome):
    token = "oc-" + secrets.token_urlsafe(32)
    ks = apikeys_lista()
    ks.append({"id": secrets.token_hex(4), "nome": nome[:40] or "sem nome", "prefixo": token[:9] + "…",
               "hash": hashlib.sha256(token.encode()).hexdigest(), "criada": time.time(), "uso": None})
    _grava_json(APIKEYS, ks, privado=True)
    return token


def valida_apikey(token):
    """Para o futuro servidor remoto: devolve o registro da chave se ela existir e não foi revogada."""
    h = hashlib.sha256(token.encode()).hexdigest()
    ks = apikeys_lista()
    for k in ks:
        if hmac.compare_digest(k["hash"], h):
            k["uso"] = time.time()
            _grava_json(APIKEYS, ks, privado=True)
            return k
    return None


def revoga_apikey(kid):
    ks = apikeys_lista()
    novo = [k for k in ks if k["id"] != kid]
    _grava_json(APIKEYS, novo, privado=True)
    return len(novo) < len(ks)


def lista_apikeys():
    ks = apikeys_lista()
    if not ks:
        fala("idle", "Você ainda não criou nenhuma chave do Overcode.")
    for k in ks:
        uso = "nunca usada" if not k["uso"] else "usada " + atras(k["uso"])
        print(cor("lar", "  ✦ ") + cor("neg", k["nome"]) + cor("dim", f"  {k['prefixo']}  id {k['id']}  · {uso}"))


def cmd_apikey(arg=""):
    esc = menu("Chaves de API", ["Criar uma chave do Overcode", "Ver as chaves do Overcode", "Revogar uma chave do Overcode",
                                 "Chaves das IAs na nuvem (Gemini etc.)", "Voltar"], permitir_outro=False, cancela=4)
    if esc.startswith("Criar"):
        nome = input(cor("lar", "  nome da chave (ex.: meu-pc) > ")).strip()
        token = cria_apikey(nome)
        print(cor("amar", "  Guarde agora: ela não aparece de novo.\n  ") + cor("verde", token))
        print(cor("dim", "  Ela vai servir para conversar com este Overcode de outro aparelho.\n  (O modo remoto vem numa próxima versão; a chave já fica pronta.)"))
    elif esc.startswith("Ver"):
        lista_apikeys()
    elif esc.startswith("Revogar"):
        ks = apikeys_lista()
        if not ks:
            fala("idle", "Não há chaves para revogar.")
            return
        ops = [f"{k['nome']} ({k['prefixo']})" for k in ks] + ["Cancelar"]
        r = menu("Revogar qual?", ops, permitir_outro=False, cancela=len(ops) - 1)
        if r != "Cancelar" and revoga_apikey(ks[ops.index(r)]["id"]):
            fala("feliz", "Chave revogada.")
    elif esc.startswith("Chaves das IAs"):
        adiciona_chave()


def cli_apikey(args):
    sub = args[0] if args else "listar"
    if sub in ("criar", "create", "new"):
        print(cria_apikey(" ".join(args[1:]) or "sem nome"))
    elif sub in ("listar", "list"):
        lista_apikeys()
    elif sub in ("revogar", "revoke") and len(args) > 1:
        print("revogada" if revoga_apikey(args[1]) else "não achei essa chave")
    else:
        print("Uso: overcode apikey criar <nome> | listar | revogar <id>")


# ---------- permissões ----------
def confirma(cmd):
    """Retorna (permitido, comentario_do_usuario). Comandos que apagam coisas sempre perguntam."""
    instala = bool(INSTALA.search(cmd))
    perigo = bool(PERIGO.search(cmd))
    modo = CFG["modo"]
    if not perigo:
        if modo == "autonomo" or E.liberado:
            return True, ""
        if modo != "perguntar" and not instala:
            return True, ""
        if modo != "perguntar" and instala and E.auto_instala:
            return True, ""
    cor_t = "amar" if perigo else "lar"
    print(cor(cor_t, "● ") + cor("neg", "Esse comando pode apagar coisas:" if perigo else
                                  "Quero instalar algo:" if instala else "Quero executar:"))
    print(cor("dim", "  " + cmd[:300].replace("\n", "\n  ")))
    ops = ["Sim"]
    if not perigo:
        ops.append("Sim, e não perguntar mais nesta sessão (shift+tab)")
    ops.append("Não, e dizer o que fazer (tab)")
    r = menu("Permitir?", ops, permitir_outro=False, shift=1 if not perigo else None, tab=len(ops) - 1,
             cancela=len(ops) - 1, dica="Esc cancela")
    if r.startswith("Sim, e"):
        E.liberado = True
        return True, ""
    if r == "Sim":
        return True, ""
    if menu.tecla == "esc":
        return False, ""
    return False, input(cor("lar", "  o que prefere? > ")).strip()


# ---------- turno: checkpoint, conselho, compactação automática, sessão salva ----------
def turno(entrada, img=None):
    if not E.backend:
        fala("erro", "Escolha uma IA com /model primeiro.")
        return
    if CFG["modo"] == "plano":
        return turno_plano(entrada, img)
    ponto_de_retorno(entrada)
    if CFG["auto_compact"] and E.backend and uso_contexto()[3] >= 80:
        print(cor("amar", "✻ ") + cor("dim", "A janela de contexto está quase cheia; compactando sozinho…"))
        compacta(auto=True)
    extra = conselho(entrada) if E.grupo else ""
    idx = len(E.historia)
    T.trab, T.tool = True, acha_tool(entrada)
    try:
        nota, E.nota = E.nota, ""
        _turno_core((nota + "\n" if nota else "") + entrada + extra, img)
    finally:
        T.trab = False
        if idx < len(E.historia) and E.historia[idx]["role"] == "user" and extra:
            E.historia[idx]["content"] = entrada  # as opiniões do conselho valem só para este pedido
        E.todo, E.feitos = [], 0
        salva_sessao()


def turno_plano(entrada, img=None):
    if T.on:
        T.tool = acha_tool(entrada)
        return turno_plano_tui(entrada, img)
    E.pendente = entrada
    ponto_de_retorno(entrada)
    extra = conselho(entrada) if E.grupo else ""
    msg = {"role": "user", "content": entrada + extra}
    if img:
        msg["img"] = img
    E.historia.append(msg)
    idx = len(E.historia) - 1
    resp = gera(monta_mensagens())
    if extra:
        E.historia[idx]["content"] = entrada
    if resp is None:
        E.historia.pop()
        return
    E.historia.append({"role": "assistant", "content": resp})
    salva_sessao()
    passos = extrai_passos(resp)
    if not passos:
        return
    E.todo, E.feitos = passos, 0
    mostra_todo()
    esc = menu("Executar este plano?", ["Sim, executar", "Sim, e não perguntar mais nesta sessão (shift+tab)",
                                        "Não, quero ajustar"], permitir_outro=False, shift=1, cancela=2)
    if esc.startswith("Não"):
        novo = input(cor("lar", "  o que mudar no plano? > ")).strip()
        if novo:
            turno_plano(novo)
        return
    CFG["modo"] = "normal"
    E.pendente, E.nota = "", ""
    E.liberado = esc.startswith("Sim, e")
    print(cor(MODO_COR["normal"], " ⏵ saí do modo plano") + cor("dim", " — executando"))
    try:
        _turno_core(msg_aprovado(entrada))
    finally:
        fim_todo()
        salva_sessao()


# ---------- sistema de atualização ----------
def achar_atualizacao():
    """Procura instalar-overcode*.sh / overcode*.py com versão maior que a instalada."""
    marca = "#__OVERCODE_PY" + "_INICIO__\n"
    melhor = None
    pastas = (ATUALIZ, os.path.join(DIR, "atualizacoes"), os.path.join(HOME, "storage", "downloads"),
              os.path.join(HOME, "Downloads"))
    for pasta in pastas:
        if not os.path.isdir(pasta):
            continue
        for f in os.listdir(pasta):
            if not re.match(r"(instalar-)?overcode.*\.(py|sh)$", f, re.I):
                continue
            p = os.path.join(pasta, f)
            try:
                src = open(p, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            if f.lower().endswith(".sh"):
                k = src.find(marca)
                if k < 0:
                    continue
                src = src[k + len(marca):]
            m = re.search(r'^VERSAO = "([\d.]+)"', src, re.M)
            if not m:
                continue
            v = vtuple(m.group(1))
            if v > vtuple(VERSAO) and (melhor is None or v > melhor[0]):
                nov = re.search(r'^NOVIDADES = "(.*)"$', src, re.M)
                melhor = (v, m.group(1), p, src, nov.group(1) if nov else "")
    return melhor


def aplicar_atualizacao(src):
    try:
        compile(src, "atualizacao", "exec")
    except SyntaxError:
        fala("erro", "O arquivo novo está com defeito. Não atualizei.")
        return False
    alvo = os.path.realpath(__file__)
    try:
        shutil.copy(alvo, os.path.join(DIR, "overcode.antigo"))
        with open(alvo, "w", encoding="utf-8") as f:
            f.write(src)
        os.chmod(alvo, 0o755)
    except Exception as e:
        fala("erro", f"Não consegui gravar a atualização: {e}")
        return False
    return True


def verifica_atualizacao(manual=False):
    u = achar_atualizacao()
    if not u:
        if manual:
            fala("idle", f"Você já está na versão mais nova (v{VERSAO}).")
            print(cor("dim", "  Para atualizar, coloque o arquivo novo em: " + ATUALIZ.replace(HOME, "~", 1)))
        return
    ignorada = open(IGNORAR).read().strip() if os.path.isfile(IGNORAR) else ""
    if not manual and ignorada == u[1]:
        return
    while True:
        esc = menu(f"Nova versão {u[1]} encontrada (você tem {VERSAO}). Atualizar agora?",
                   ["Atualizar agora", "Ver o que mudou", "Agora não", "Ignorar esta versão"],
                   permitir_outro=False, cancela=2)
        if esc.startswith("Ver"):
            print(cor("dim", "  " + (u[4] or "O arquivo novo não traz a lista de novidades.")))
            continue
        break
    if esc.startswith("Ignorar"):
        open(IGNORAR, "w").write(u[1])
        return
    if esc.startswith("Atualizar") and aplicar_atualizacao(u[3]):
        fala("feliz", cor("verde", f"Atualizado para a v{u[1]}! Reiniciando…"))
        time.sleep(1)
        parar_servidor()
        os.execv(sys.executable, [sys.executable, os.path.realpath(__file__)] + sys.argv[1:])


# ---------- tutorial inicial + quiz ----------
TUTORIAL = [
    ("Conversar", ["Fale normal, em português. O Overcode entende, roda comandos e cria arquivos.",
                   "Ele pergunta antes de instalar algo ou de apagar coisas."]),
    ("Comandos básicos", ["/help      mostra todos os comandos", "/model     troca de IA (categorias, ★ usar todas e Ultra)",
                          "/clear     apaga a conversa e começa do zero", "/compact   resume a conversa para liberar espaço"]),
    ("Memória e projeto", ["#texto     guarda algo na memória (vale em todas as conversas)",
                           "/memory    ver, adicionar ou apagar lembranças",
                           "/init      cria o OVERCODE.md: regras do projeto desta pasta",
                           "/skills    habilidades: receitas que ele usa sozinho"]),
    ("Voltar no tempo", ["/resume    retoma uma conversa anterior", "/rewind    volta conversa e arquivos para antes de um pedido",
                         "/context   mostra quanto da janela de contexto já foi usada"]),
    ("Modos (shift+tab ou /mode alterna)", ["normal      executa sozinho; pergunta ao instalar ou apagar",
                                            "perguntar   pergunta antes de todo comando", "plano       só monta um plano; você aprova (/plan)",
                                            "autônomo    executa tudo sem perguntar (/autonomo)"]),
    ("Atalhos", ["@arquivo   cita um arquivo ou imagem na mensagem", "!comando   roda um comando seu direto",
                 "/update    procura versão nova na pasta Atualizações", "/apikey    cria chaves de API e guarda as das IAs na nuvem"]),
]
QUIZ = [
    ("Qual comando apaga a conversa e começa do zero?", "/clear", ["/model", "/init"], "O /clear limpa tudo. O /compact só resume."),
    ("A conversa ficou enorme e a IA começou a se perder. O que ajuda sem perder tudo?", "/compact", ["/init", "/skills"],
     "O /compact resume o que já foi feito e libera espaço na janela de contexto."),
    ("Como trocar a IA que está respondendo?", "/model", ["/memory", "/resume"], "O /model abre as categorias de IA (e a opção Ultra)."),
    ("Como guardar na memória que você prefere respostas curtas?", "#prefiro respostas curtas",
     ["/init prefiro respostas curtas", "@respostas curtas"], "Começar a mensagem com # salva na memória."),
    ("A IA mexeu em arquivos e você quer desfazer. O que usa?", "/rewind", ["/clear", "/compact"],
     "O /rewind volta a conversa e os arquivos para antes de um pedido."),
    ("Como voltar numa conversa de ontem?", "/resume", ["/rewind", "/context"], "O /resume lista as conversas salvas."),
    ("Qual modo só monta um plano e espera a sua aprovação?", "modo plano (/plan)", ["modo autônomo", "modo normal"],
     "No modo plano nada roda antes de você aprovar."),
    ("Como o Overcode passa a seguir as regras do seu projeto em toda conversa naquela pasta?", "/init (cria o OVERCODE.md)",
     ["/clear", "/apikey"], "O /init cria o OVERCODE.md, que é lido em toda conversa da pasta."),
]


def espera(msg="Enter para continuar"):
    try:
        input(cor("dim", "  " + msg + " "))
    except EOFError:
        pass


def tutorial_paginas():
    for i, (tit, linhas) in enumerate(TUTORIAL, 1):
        print()
        print(cor("lar", f"● {tit}") + cor("dim", f"  ({i}/{len(TUTORIAL)})"))
        for l in linhas:
            print("  " + l)
        espera()


def quiz():
    perguntas = random.sample(QUIZ, 6)
    acertos = 0
    print()
    fala("curiosa", cor("neg", "Agora um quiz rápido (6 perguntas) para ver se ficou claro!"))
    for n, (q, certa, erradas, expl) in enumerate(perguntas, 1):
        ops = [certa] + erradas
        random.shuffle(ops)
        for tentativa in (1, 2):
            r = menu(f"{n}/6  {q}", ops, permitir_outro=False)
            if r == certa:
                acertos += tentativa == 1
                print(cor("verde", "  ✔ Certo! ") + cor("dim", expl))
                break
            print(cor("verm", "  ✘ Ainda não. ") + (cor("dim", "Tente de novo.") if tentativa == 1 else cor("dim", f"A resposta era {certa}. {expl}")))
    return acertos


def pergunta_gemini():
    print()
    r = menu("Quer adicionar uma chave do Gemini para ganhar velocidade?",
             ["Sim, adicionar agora", "Agora não"], permitir_outro=False, cancela=1,
             dica="o Gemini roda na nuvem e responde rápido; as conversas passam pelo Google")
    if r.startswith("Sim") and configura_provedor("gemini", forcar=True):
        grava_ultimo("n:gemini")
        fala("feliz", "Pronto! Vou abrir já com o Gemini. Sem internet, volto para a IA local. Em /model você troca quando quiser.")
    else:
        fala("idle", "Sem problemas. Você pode adicionar depois em /apikey.")


def setup_inicial():
    os.system("clear")
    for l in caixa(" Overcode · primeiros passos ", [("Bem-vindo ao Overcode!", "neg"), ("", None)] + [(m, "lar") for m in MASCOTE], [], 40):
        print(l)
    fala("feliz", "Vou te mostrar os comandos e depois fazer um quiz rápido.")
    conhece_usuario()
    tutorial_paginas()
    while True:
        total = 6
        acertos = quiz()
        if acertos >= total - 1:
            fala("radiante", cor("verde", f"Mandou bem! {acertos}/{total} de primeira."))
            break
        fala("curiosa", f"Você acertou {acertos}/{total} de primeira.")
        r = menu("Quer rever o tutorial e tentar de novo?", ["Sim, rever", "Não, seguir assim"], permitir_outro=False, cancela=1)
        if not r.startswith("Sim"):
            break
        tutorial_paginas()
    pergunta_gemini()
    CFG["setup_feito"] = True
    salva_cfg()
    fala("feliz", "Tudo pronto! Digite /setup quando quiser rever isso.")
    espera()


# ---------- comandos ----------
CMDS = [
    ("/help", ["/ajuda"], "mostra os comandos"),
    ("/model", ["/modelos", "/modelo"], "troca de IA: categorias, ★ usar todas e Ultra"),
    ("/clear", ["/limpar"], "apaga a conversa"),
    ("/compact", ["/compactar"], "resume a conversa e libera contexto"),
    ("/context", ["/ctx", "/contexto"], "uso da janela de contexto"),
    ("/memory", ["/memoria", "/memória"], "ver, adicionar ou remover lembranças (ou use #)"),
    ("/init", [], "cria o OVERCODE.md do projeto"),
    ("/plan", ["/plano"], "modo plano: planeja e espera aprovação"),
    ("/autonomo", ["/autonomous"], "liga ou desliga o modo autônomo"),
    ("/mode", ["/modo"], "alterna o modo de permissão"),
    ("/permissions", ["/permissoes", "/permissões"], "escolhe o modo de permissão"),
    ("/resume", ["/retomar"], "retoma uma conversa anterior"),
    ("/rewind", ["/voltar"], "volta conversa e arquivos para antes de um pedido"),
    ("/skills", ["/habilidades"], "habilidades que ele usa sozinho"),
    ("/apikey", ["/chaves"], "chaves de API (Overcode e IAs na nuvem)"),
    ("/cost", ["/custo"], "tokens usados e custo"),
    ("/status", [], "versão, IA, pasta e modo"),
    ("/doctor", ["/diagnostico", "/diagnóstico"], "diagnóstico do ambiente, IA, terminal e projeto"),
    ("/rules", ["/regras"], "mostra as instruções OVERCODE.md, CLAUDE.md ou AGENTS.md"),
    ("/config", [], "ajustes"),
    ("/update", ["/atualizar"], "procura versão nova em Atualizações"),
    ("/setup", ["/tutorial"], "refaz o tutorial e o quiz"),
    ("/folder", ["/pasta"], "escolher pasta (setas + Enter)"),
    ("/attach", ["/anexar"], "anexar arquivo (seletor do Android)"),
    ("/projects", ["/projetos"], "abrir o que o Overcode criou"),
    ("/coracao", ["/coração", "/sentimentos"], "sentimentos da Kelly"),
    ("/diario", ["/diário"], "lembranças dela"),
    ("/nome", [], "mudar como ela te chama"),
    ("/terminal", ["/term", "/aba"], "abre o terminal de trabalho (você vê e digita; Ctrl+C volta)"),
    ("/ssh", [], "conecta num servidor por SSH (a Kelly passa a executar lá)"),
    ("/parar", ["/stop"], "interrompe o comando que está rodando no terminal"),
    ("/manual", ["/man"], "dicionário de comandos (ex.: /manual tar)"),
    ("/exit", ["/sair", "/quit"], "fechar"),
]
MAPA_CMD = {}
for _n, _als, _d in CMDS:
    MAPA_CMD[_n] = _n
    for _a in _als:
        MAPA_CMD[_a] = _n
NOMES_CMD = sorted(MAPA_CMD)


def resolve_cmd(tok):
    tok = tok.lower()
    if tok in MAPA_CMD:
        return MAPA_CMD[tok]
    return sorted({MAPA_CMD[n] for n in NOMES_CMD if n.startswith(tok)})  # lista: vazia ou ambígua


def mostra_ajuda():
    print(cor("lar", "● ") + cor("neg", f"Overcode v{VERSAO}") + cor("dim", "  comandos (apelidos entre parênteses)"))
    for n, als, d in CMDS:
        ap = (" (" + als[0] + ")") if als else ""
        print(f"  {cor('lar', n):<22}{cor('dim', ap):<24} {d}")
    print(cor("dim", "  #texto guarda na memória · @arquivo cita arquivo · !comando roda direto · shift+tab troca de modo"))


def set_modo(m):
    antes = CFG["modo"]
    CFG["modo"] = m
    E.liberado = False
    print(cor(MODO_COR[m], " ⏵ " + MODO_NOME[m]) + cor("dim", " — " + MODO_DESC[m]))
    if antes == "plano" and m != "plano":
        E.nota = NOTA_SAIU_PLANO  # a IA é avisada de que não está mais só planejando
        if E.pendente:
            p, E.pendente = E.pendente, ""
            r = menu("Você pediu isto no modo plano e ainda não foi feito: «" + p[:50] + "». Fazer agora?",
                     ["Sim, fazer agora", "Não"], permitir_outro=False, cancela=1)
            if r.startswith("Sim"):
                turno(p)


def cmd_model():
    if escolhe_modelo():
        sente("novidade", "Troquei de cérebro e fiquei curiosa")
        fala("curiosa", f"Troquei de cérebro! Agora: {cor('verde', modelo_txt())}")


def cmd_permissions():
    ops = [f"{MODO_NOME[m]:<17} {MODO_DESC[m]}" for m in MODOS]
    esc = menu("Modo de permissão", ops, permitir_outro=False, cancela=MODOS.index(CFG["modo"]))
    set_modo(MODOS[ops.index(esc)])


def cmd_status():
    print(cor("lar", "● ") + cor("neg", f"Overcode v{VERSAO}"))
    print(cor("dim", "  IA: ") + modelo_txt())
    print(cor("dim", "  Pasta: ") + E.cwd.replace(HOME, "~", 1))
    print(cor("dim", "  Modo: ") + MODO_NOME[CFG["modo"]] + (" (liberado nesta sessão)" if E.liberado else ""))
    print(cor("dim", "  Memória: ") + pl(len(le_memoria()), "lembrança", "lembranças") +
          cor("dim", "  · OVERCODE.md: ") + (acha_overcode_md() or "nenhum").replace(HOME, "~", 1))
    print(cor("dim", "  Conversa: ") + pl(len(E.historia), "mensagem", "mensagens") + cor("dim", f"  · contexto {uso_contexto()[3]}%" if E.backend else ""))


def cmd_doctor():
    """Diagnóstico local e não destrutivo; não envia dados nem testa chaves pela internet."""
    checks = []
    checks.append(("Python", sys.version.split()[0]))
    checks.append(("Plataforma", (sys.platform + " / " + os.uname().machine) if hasattr(os, "uname") else sys.platform))
    checks.append(("Shell", shutil.which("bash") or "bash não encontrado"))
    checks.append(("Terminal PTY", "disponível" if (hasattr(os, "openpty") or sys.platform != "win32") else "indisponível"))
    checks.append(("Terminal de trabalho", "ativo" if (SH.vivo and SH.proc and SH.proc.poll() is None) else "será iniciado quando necessário"))
    checks.append(("Pasta do projeto", E.cwd + (" (gravável)" if os.path.isdir(E.cwd) and os.access(E.cwd, os.W_OK) else " (sem acesso de escrita)")))
    checks.append(("Memória", MEMORIA + (" (existe)" if os.path.isfile(MEMORIA) else " (ainda vazia)")))
    regras = acha_overcode_md()
    checks.append(("Regras do projeto", regras or "nenhum OVERCODE.md, CLAUDE.md ou AGENTS.md encontrado"))
    checks.append(("IA selecionada", modelo_txt() if E.backend else "nenhuma"))
    if E.backend:
        checks.append(("API", E.backend.get("url", "sem endereço")))
        checks.append(("Contexto", str(E.backend.get("ctx", "desconhecido")) + " tokens (estimativa)"))
    checks.append(("SSH", "conectado: " + (SH.host or "servidor") if SH.remoto else "desconectado"))
    print(cor("lar", "● ") + cor("neg", "Diagnóstico do Overcode"))
    for nome, valor in checks:
        print("  " + cor("dim", f"{nome:<22}") + str(valor))
    problemas = []
    if not shutil.which("bash") and sys.platform != "win32":
        problemas.append("bash não está instalado; o terminal de trabalho pode não iniciar")
    if E.backend is None:
        problemas.append("nenhuma IA selecionada")
    if not os.path.isdir(E.cwd) or not os.access(E.cwd, os.W_OK):
        problemas.append("a pasta atual não está gravável")
    if problemas:
        print(cor("amar", "  Atenção: " + "; ".join(problemas)))
    else:
        print(cor("verde", "  Diagnóstico básico concluído sem problemas evidentes."))
    print(cor("dim", "  O diagnóstico é local; não valida saldo, cota ou validade da chave do provedor."))


def cmd_rules():
    """Mostra o arquivo de instruções que será aplicado ao projeto."""
    p = acha_overcode_md()
    if not p:
        fala("idle", "Não achei OVERCODE.md, CLAUDE.md nem AGENTS.md nesta pasta ou acima. Use /init para criar OVERCODE.md.")
        return
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            corpo = f.read(12000)
        print(cor("lar", "● ") + cor("neg", "Instruções do projeto: ") + p)
        print(cor("dim", corpo if corpo.strip() else "(arquivo vazio)"))
    except OSError as e:
        fala("erro", "Não consegui ler as instruções: " + str(e))


def cmd_cost():
    print(cor("lar", "● ") + cor("neg", "Uso nesta sessão") + cor("dim", " (estimativa)"))
    print(f"  ↑ {E.uso_in} tokens enviados · ↓ {E.uso_out} tokens recebidos")
    print(cor("dim", "  IA local: R$ 0,00, roda no seu aparelho. Na nuvem, o custo depende do plano da chave de cada provedor."))


def cmd_config():
    ops = [f"Compactar sozinho quando a janela encher: {'ligado' if CFG['auto_compact'] else 'desligado'}",
           "Refazer o tutorial", "Voltar"]
    esc = menu("Ajustes", ops, permitir_outro=False, cancela=2)
    if esc.startswith("Compactar"):
        CFG["auto_compact"] = not CFG["auto_compact"]
        salva_cfg()
        fala("idle", "Compactação automática " + ("ligada." if CFG["auto_compact"] else "desligada."))
    elif esc.startswith("Refazer"):
        setup_inicial()


def cmd_folder():
    subs = sorted(d for d in os.listdir(E.cwd) if os.path.isdir(os.path.join(E.cwd, d)) and not d.startswith("."))[:12]
    esc = menu("Ir para qual pasta? (" + E.cwd.replace(HOME, "~", 1) + ")", [".. (voltar)"] + subs)
    alvo = os.path.dirname(E.cwd) if esc.startswith("..") else os.path.expanduser(esc)
    alvo = alvo if os.path.isabs(alvo) else os.path.join(E.cwd, alvo)
    if os.path.isdir(alvo):
        E.cwd = os.path.abspath(alvo)
        fala("feliz", "Agora em " + E.cwd.replace(HOME, "~", 1))
        if acha_overcode_md():
            print(cor("lar", "  ✦ ") + cor("dim", "achei " + os.path.basename(acha_overcode_md()) + " e vou seguir as regras dele"))
    else:
        fala("erro", "Pasta não encontrada.")


def novo_id():
    return time.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(3)


def executa_cmd(nome, arg):
    """Roda um comando de barra. Devolve False para fechar o programa."""
    if nome == "/exit":
        return False
    if nome == "/help":
        mostra_ajuda()
    elif nome == "/model":
        cmd_model()
    elif nome == "/clear":
        salva_sessao()
        E.historia, E.checkpoints, E.todo, E.feitos = [], [], [], 0
        E.sessao_id = novo_id()
        fala("idle", "Conversa limpa. A anterior continua salva em /resume.")
    elif nome == "/compact":
        compacta()
    elif nome == "/context":
        cmd_context()
    elif nome == "/memory":
        cmd_memory(arg)
    elif nome == "/init":
        cmd_init()
    elif nome == "/plan":
        set_modo("normal" if CFG["modo"] == "plano" else "plano")
    elif nome == "/autonomo":
        set_modo("normal" if CFG["modo"] == "autonomo" else "autonomo")
    elif nome == "/mode":
        set_modo(MODOS[(MODOS.index(CFG["modo"]) + 1) % len(MODOS)])
    elif nome == "/permissions":
        cmd_permissions()
    elif nome == "/resume":
        cmd_resume()
    elif nome == "/rewind":
        cmd_rewind()
    elif nome == "/skills":
        cmd_skills(arg)
    elif nome == "/apikey":
        cmd_apikey(arg)
    elif nome == "/cost":
        cmd_cost()
    elif nome == "/status":
        cmd_status()
    elif nome == "/doctor":
        cmd_doctor()
    elif nome == "/rules":
        cmd_rules()
    elif nome == "/config":
        cmd_config()
    elif nome == "/update":
        verifica_atualizacao(manual=True)
    elif nome == "/setup":
        setup_inicial()
    elif nome == "/folder":
        cmd_folder()
    elif nome == "/attach":
        d = anexar()
        if d:
            instr = input(cor("lar", "  o que fazer com ele? > ")).strip()
            m, img = mensagem_anexo(d, instr)
            turno(m, img)
    elif nome == "/projects":
        projetos()
    elif nome == "/coracao":
        mostra_coracao()
    elif nome == "/diario":
        mostra_diario()
    elif nome == "/nome":
        muda_nome()
    elif nome == "/terminal":
        SH.atacha()
    elif nome == "/ssh":
        cmd_ssh(arg)
    elif nome == "/parar":
        SH.interrompe()
        fala("idle", "Mandei Ctrl+C para o terminal de trabalho.")
    elif nome == "/manual":
        cmd_manual(arg)
    return True


def trata(entrada):
    """Uma linha digitada. Devolve False para fechar."""
    if entrada in ("sair", "exit"):
        return False
    if entrada.startswith("!"):
        print(executa(entrada[1:], sentir=False))
        return True
    if entrada.startswith("#") and not entrada.startswith("#!"):
        txt = entrada.lstrip("#").strip()
        if txt and add_memoria(txt):
            print(cor("lar", "  ✦ ") + cor("verde", "Memorizado: ") + txt)
        return True
    T.dorme = bool(DESPEDE.search(entrada))
    tok, _, arg = entrada.partition(" ")
    if entrada == "?":
        tok = "/help"
    if tok.startswith("/") and "/" not in tok[1:]:
        r = resolve_cmd(tok) if tok != "/" else sorted({n for n, _, _ in CMDS})
        if isinstance(r, list):
            if tok == "/":
                mostra_ajuda()
            elif not r:
                fala("erro", f"Não conheço {tok}. Digite /help para ver os comandos.")
            else:
                print(cor("dim", "  Você quis dizer: " + ", ".join(r) + " ?"))
            return True
        return executa_cmd(r, arg.strip())
    try:
        if le_usuario(entrada):
            return True
        texto, img = expande_mencoes(entrada)
        ds = dicas_skills(entrada)
        if ds:
            for nome, _ in ds:
                print(cor("lar", "  ✦ ") + cor("dim", "habilidade: " + nome))
            texto += "\n\n[" + "\n".join(t for _, t in ds) + "]"
        captura_ssh(entrada)
        mn = acha_manual(entrada)
        if mn:
            for nome, _ in mn:
                print(cor("lar", "  ✦ ") + cor("dim", "manual: " + nome))
            texto += "\n\n[Manual: " + " | ".join(t for _, t in mn)[:1100] + "]"
        turno(texto, img)
    except KeyboardInterrupt:
        spin.stop()
        print(cor("dim", "\n(interrompido)"))
    return True


AJUDA_CLI = """Overcode — agente de terminal com IA local ou na nuvem
Uso:
  overcode               abre o Overcode
  overcode -c            continua a última conversa
  overcode -r            escolhe uma conversa para retomar
  overcode --autonomo    abre já no modo autônomo
  overcode apikey criar <nome> | listar | revogar <id>
  overcode --version"""


def _main():
    import signal, atexit
    args = sys.argv[1:]
    if args and args[0] == "apikey":
        cli_apikey(args[1:])
        return
    if args and args[0] in ("-v", "--version", "version"):
        print("Overcode v" + VERSAO)
        return
    if args and args[0] in ("-h", "--help", "help"):
        print(AJUDA_CLI)
        return
    if any(a in ("--autonomo", "--auto") for a in args):
        CFG["modo"] = "autonomo"

    def _sai(*_):
        T.para()
        SH.fecha()
        parar_servidor()
        os._exit(0)
    for _s in (signal.SIGHUP, signal.SIGTERM):  # fechou o terminal: leva o motor junto
        try:
            signal.signal(_s, _sai)
        except Exception:
            pass
    atexit.register(parar_servidor)
    atexit.register(SH.fecha)
    migra_memoria_antiga()
    _prepara_readline(NOMES_CMD)
    E.sessao_id = novo_id()
    os.system("clear")
    verifica_atualizacao()
    if not CFG["setup_feito"]:
        setup_inicial()
    ult = open(ULTIMO).read().strip() if os.path.isfile(ULTIMO) else None
    if ult in ("n:gemini", "g") and not internet_ok():  # sem internet: volta para a IA local
        print(cor("amar", "Sem internet: tentando a última IA local."))
        ult = CFG.get("ultimo_local") or None
    ok = escolhe_modelo(ult) if ult else False
    while not ok:
        ok = escolhe_modelo()
    os.system("clear")
    conhece_usuario()
    reencontro()
    os.system("clear")
    if T.inicia():
        print(cor("dim", " Projetos: " + BASE.replace(HOME, "~", 1)))
        print(cor("dim", " Dicas: /init cria o OVERCODE.md · # guarda na memória · @arquivo cita arquivo · / mostra os comandos"))
        if SEM_STORAGE:
            print(cor("amar", " ⚠ Rode termux-setup-storage para ver as pastas no celular."))
        print()
    else:
        banner()
    abre = abertura()
    fala(abre[0], abre[1])
    if "-c" in args or "--continue" in args:
        cmd_resume(ultima=True)
    elif "-r" in args or "--resume" in args:
        cmd_resume()
    try:
        while True:
            try:
                entrada = le_entrada()
            except EOFError:
                break
            if not entrada:
                continue
            if not trata(entrada):
                break
    except KeyboardInterrupt:
        pass
    salva_sessao()
    parar_servidor()
    T.para()
    despedida()


def main():
    try:
        _main()
    finally:
        T.para()


if __name__ == "__main__":
    main()