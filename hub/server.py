#!/usr/bin/env python3
"""Overcode Hub v2.6 — painel local para a Kelly/Overcode.

Biblioteca padrão apenas. O servidor escuta em localhost por padrão.
Não encaminhe a porta para a internet. Para acesso LAN, use --host 0.0.0.0
(aplica token bearer gerado localmente) e restrinja a rede com firewall.
"""
from __future__ import annotations
import argparse, base64, hashlib, hmac, json, os, re, secrets, shlex, shutil
import subprocess, sys, threading, time, urllib.error, urllib.request, zipfile, io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote

VERSION = "2.7.0"
HOME = Path.home()
OC = HOME / ".overcode"
HUB = OC / "hub"
WEB = HUB / "web"
SESSIONS = HUB / "sessions"
PLUGINS = OC / "plugins"
SKILLS = OC / "skills"
SETTINGS_FILE = HUB / "settings.json"
AUTH_FILE = HUB / "auth.token"
OPENAPI_FILE = HUB / "openapi.json"
HOST = "127.0.0.1"
PORT = 8765
for p in (HUB, WEB, SESSIONS, PLUGINS, SKILLS):
    p.mkdir(parents=True, exist_ok=True)

PROVIDERS = {
    "gemini": ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash"),
    "openai": ("OpenAI", "https://api.openai.com/v1", ""),
    "groq": ("Groq", "https://api.groq.com/openai/v1", ""),
    "openrouter": ("OpenRouter", "https://openrouter.ai/api/v1", ""),
    "deepseek": ("DeepSeek", "https://api.deepseek.com/v1", ""),
    "outra": ("API compatível com OpenAI", "", ""),
}
LOCAL_MODELS = {
    "1": ("Llama 3.2 1B", "Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
    "2": ("Gemma 2 2B", "gemma-2-2b-it-Q4_K_M.gguf"),
    "3": ("Qwen2.5 Coder 1.5B", "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"),
    "4": ("Qwen2.5 3B", "Qwen2.5-3B-Instruct-Q4_K_M.gguf"),
    "5": ("Qwen2.5 Coder 3B", "Qwen2.5-Coder-3B-Instruct-Q4_K_M.gguf"),
    "6": ("Llama 3.2 3B", "Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
    "7": ("Phi 3.5 mini", "Phi-3.5-mini-instruct-Q4_K_M.gguf"),
    "8": ("Qwen2.5 7B", "Qwen2.5-7B-Instruct-Q4_K_M.gguf"),
    "9": ("Qwen2.5 Coder 7B", "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"),
    "10": ("Gemma 2 9B", "gemma-2-9b-it-Q4_K_M.gguf"),
}
DANGEROUS = re.compile(
    r"\brm\s+[^\n]*-[^\n]*r|\brm\s+[^\n]*-[^\n]*f|\bmkfs(?:\.[\w-]+)?\b|"
    r"\bdd\s+[^\n]*\bof=|\b(?:wipefs|parted|fdisk|sfdisk)\b|"
    r"\b(?:shutdown|reboot|poweroff|halt)\b|\bgit\s+reset\s+--hard\b|"
    r"\bgit\s+clean\s+-[a-z]*f|\bfind\b[^\n]*\s-delete\b|"
    r"\btruncate\s+-s\s*0\b|\bchmod\s+-R\b|\bchown\s+-R\b|"
    r"\bdocker\s+(?:system\s+prune|volume\s+prune|rm|rmi)\b|"
    r"\bkubectl\s+delete\b|\bshred\b|\bapt(?:-get)?\s+(?:remove|purge)\b|"
    r"\bpkg\s+(?:uninstall|remove)\b|\bnpm\s+uninstall\b|\bsudo\b|"
    r"\b(?:curl|wget)\b[^\n]*\|\s*(?:sudo\s+)?(?:bash|sh)\b|"
    r"\bsystemctl\s+(?:restart|stop|disable|mask)\b|\b(?:ufw|iptables|nft)\s+", re.I)
INSTALL = re.compile(r"\b(?:apt(?:-get)?\s+install|pkg\s+install|pip(?:3)?\s+install|npm\s+install|"
                     r"yarn\s+add|pnpm\s+add|cargo\s+install|gem\s+install)\b", re.I)
BASH_BLOCK = re.compile(r"```(?:bash|sh|shell)\s*\n(.*?)```", re.I | re.S)


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, obj, private=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    if private:
        os.chmod(tmp, 0o600)
    tmp.replace(path)


def settings():
    d = read_json(SETTINGS_FILE, {})
    base = {"mode": "normal", "plan_approved": False, "plan_pending": False,
            "custom_plan": "", "voice_enabled": True, "voice_uri": "", "voice_web_uri": "",
            "voice_android_uri": "", "voice_rate": 1.0, "voice_pitch": 1.0,
            "voice_volume": 1.0, "advanced_collapsed": True,
            "project_dir": str(HOME), "ssh_profile": None, "active_ssh": False}
    base.update(d if isinstance(d, dict) else {})
    if base.get("mode") not in ("normal", "ask", "plan", "auto", "custom"):
        base["mode"] = "normal"
    return base


LOCK = threading.RLock()
LOCAL_START_LOCK = threading.Lock()
LOCAL_STARTING = False
LOCAL_START_ERROR = ""
LOCAL_PROCESS = None
STATE = {"settings": settings(), "sessions": {}, "pending": None,
         "activity": [], "cwd": str(Path.cwd()), "last_error": ""}


def active_backend():
    providers = read_json(OC / "provedores.json", {})
    ultimo = ""
    try:
        ultimo = (OC / "ultimo-modelo").read_text(encoding="utf-8").strip()
    except Exception:
        pass
    if not ultimo:
        return None, "Não há IA selecionada. No terminal, abra `overcode` e escolha uma IA em /model."
    if ultimo.startswith("n:"):
        pid = ultimo[2:]
        cfg = providers.get(pid, {}) if isinstance(providers, dict) else {}
        if pid not in PROVIDERS or not cfg.get("chave"):
            return None, "A chave do provedor ativo não foi encontrada. Configure com /apikey no terminal."
        name, base, default_model = PROVIDERS[pid]
        base = (cfg.get("url") or base).rstrip("/")
        model = cfg.get("modelo") or default_model
        if not base or not model:
            return None, "O provedor precisa de URL e nome de modelo configurados."
        return {"name": name, "url": base, "model": model, "key": cfg["chave"], "local": False}, ""
    if ultimo == "g":
        cfg = providers.get("gemini", {})
        key = cfg.get("chave", "")
        if not key:
            try: key = (OC / "gemini.key").read_text().strip()
            except Exception: key = ""
        if not key:
            return None, "A chave do Gemini não foi encontrada. Configure /apikey no terminal."
        return {"name": "Gemini", "url": PROVIDERS["gemini"][1],
                "model": cfg.get("modelo") or "gemini-2.5-flash", "key": key, "local": False}, ""
    if ultimo in LOCAL_MODELS:
        port = int(os.environ.get("OVERCODE_PORT", "8081"))
        url = f"http://127.0.0.1:{port}/v1"
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/health")
            with urllib.request.urlopen(req, timeout=1): pass
        except Exception:
            global LOCAL_STARTING, LOCAL_START_ERROR, LOCAL_PROCESS
            with LOCAL_START_LOCK:
                if not LOCAL_STARTING:
                    model_name, filename = LOCAL_MODELS[ultimo]
                    model_path = OC / "modelos" / filename
                    exe = shutil.which("llama-server")
                    if exe and model_path.is_file():
                        LOCAL_STARTING = True
                        def boot_local():
                            global LOCAL_STARTING, LOCAL_START_ERROR, LOCAL_PROCESS
                            try:
                                log = open(HUB / "llama-server.log", "ab")
                                threads = max(2, min(4, (os.cpu_count() or 4)//2))
                                LOCAL_PROCESS = subprocess.Popen([exe, "-m", str(model_path), "-c", "4096", "-t", str(threads),
                                    "--host", "127.0.0.1", "--port", str(port)], stdout=log, stderr=log,
                                    stdin=subprocess.DEVNULL, start_new_session=True)
                                ready = False
                                for _ in range(180):
                                    if LOCAL_PROCESS.poll() is not None: break
                                    try:
                                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1): ready=True; break
                                    except Exception: time.sleep(1)
                                if not ready: LOCAL_START_ERROR = "O llama-server não conseguiu carregar o modelo. Consulte ~/.overcode/hub/llama-server.log."
                                else: LOCAL_START_ERROR = ""
                            except Exception as e: LOCAL_START_ERROR = str(e)
                            finally: LOCAL_STARTING = False
                        threading.Thread(target=boot_local, daemon=True).start()
                    elif not model_path.is_file():
                        LOCAL_START_ERROR = f"O arquivo do modelo {filename} não foi encontrado em ~/.overcode/modelos."
                    else:
                        LOCAL_START_ERROR = "llama-server não está instalado. Instale llama-cpp no Termux ou llama.cpp no Linux."
            if LOCAL_STARTING: return None, f"Carregando {LOCAL_MODELS[ultimo][0]} no motor local. Atualize o painel em alguns segundos."
            return None, LOCAL_START_ERROR or f"O motor local não está disponível na porta {port}."
        return {"name": LOCAL_MODELS[ultimo][0], "url": url, "model": "local", "key": "", "local": True}, ""
    return None, "Não reconheci a IA selecionada no Overcode. Use /model no terminal."


def model_request(messages, max_tokens=2400):
    backend, err = active_backend()
    if not backend:
        raise RuntimeError(err)
    body = {"model": backend["model"], "messages": messages, "stream": False,
            "max_tokens": max_tokens, "temperature": 0.35}
    if backend["local"]:
        body.update(repeat_penalty=1.15, top_k=40, top_p=0.9)
    headers = {"Content-Type": "application/json"}
    if backend["key"]:
        headers["Authorization"] = "Bearer " + backend["key"]
    req = urllib.request.Request(backend["url"] + "/chat/completions", data=json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return (data.get("choices", [{}])[0].get("message", {}).get("content") or "").strip(), backend["name"]
    except urllib.error.HTTPError as e:
        detail = e.read(1200).decode("utf-8", "replace")
        raise RuntimeError(f"Erro do provedor ({e.code}): {detail[:700]}")
    except Exception as e:
        raise RuntimeError(f"Falha ao falar com {backend['name']}: {e}")


def current_system_prompt():
    s = STATE["settings"]
    mode = s["mode"]
    prompt = ("Você é Kelly, agente de programação da Overcode. Responda em português natural. "
              "Trabalhe em ciclos: entender, inspecionar, planejar, executar uma etapa pequena, conferir a saída e verificar. "
              "Nunca invente comandos executados, arquivos, resultados ou sucesso. "
              "Quando precisar executar algo, emita exatamente um próximo comando em um bloco ```bash e aguarde o resultado. "
              "Não coloque comandos futuros no mesmo bloco. Antes de editar, inspecione arquivos e preserve o estilo do projeto. "
              "Faça mudanças reversíveis, use backups e explique o que fez. Nunca exponha senhas, tokens, chaves SSH ou arquivos secretos. "
              "Não apague ou formate dados, não reinicie serviços críticos, não altere firewall/boot/SSH sem aprovação explícita. "
              "Use o terminal local para tarefas locais. Se houver um perfil SSH ativo, pergunte ou use explicitamente o alvo remoto informado; "
              "não presuma que toda tarefa deve ir para o servidor. Se precisar de mais contexto, pergunte de forma breve.\n")
    if mode == "plan" and not s.get("plan_approved"):
        prompt += ("MODO PLANO: apresente um plano de 3 a 7 etapas, com riscos e verificações. NÃO escreva bloco bash, NÃO execute nada. "
                   "Espere aprovação do usuário.\n")
    elif mode == "plan" and s.get("plan_approved"):
        prompt += ("MODO PLANO PERMANENTE: o usuário já aprovou o plano desta sessão. Continue executando as etapas sem perguntar novamente "
                   "qual plano deseja. Permaneça no modo plano; não o desligue automaticamente. Só peça confirmação de comandos perigosos "
                   "ou instalações relevantes. Para uma nova tarefa independente, continue o plano aprovado ou aguarde o usuário usar 'Novo plano'.\n")
    elif mode == "ask":
        prompt += "MODO PERGUNTAR: não execute comandos sem confirmação explícita na interface.\n"
    elif mode == "auto":
        prompt += "MODO AUTÔNOMO: pode executar comandos de baixo risco e corrigir problemas; comandos perigosos continuam exigindo confirmação.\n"
    elif mode == "custom":
        prompt += "PLANO PERSONALIZADO DO USUÁRIO:\n" + s.get("custom_plan", "")[:5000] + "\n"
    target = s.get("ssh_profile") if s.get("active_ssh") else None
    if target:
        prompt += (f"Perfil SSH ativo: usuário={target.get('user')} host={target.get('host')} porta={target.get('port',22)}. "
                   "Para executar no host remoto, use o comando ssh explicitamente; não use senha em linha de comando.\n")
    return prompt


def session_obj(session_id=None):
    if session_id and session_id in STATE["sessions"]:
        return STATE["sessions"][session_id]
    sid = secrets.token_hex(8)
    obj = {"id": sid, "title": "Nova conversa", "messages": [], "created": time.time(), "updated": time.time(),
           "cwd": STATE["cwd"]}
    STATE["sessions"][sid] = obj
    return obj


def persist_session(obj):
    obj["updated"] = time.time()
    write_json(SESSIONS / (obj["id"] + ".json"), obj)


def load_session(session_id):
    if session_id in STATE["sessions"]:
        return STATE["sessions"][session_id]
    path = SESSIONS / (session_id + ".json")
    d = read_json(path, None)
    if isinstance(d, dict) and d.get("id") == session_id and isinstance(d.get("messages"), list):
        STATE["sessions"][session_id] = d
        return d
    return session_obj()


def add_activity(kind, title, detail="", status="done"):
    STATE["activity"].insert(0, {"id": secrets.token_hex(4), "kind": kind, "title": title,
                                "detail": str(detail)[:3000], "status": status, "time": time.time()})
    STATE["activity"] = STATE["activity"][:60]


def run_shell(command, cwd=None, timeout=120):
    cwd = cwd or STATE["cwd"] or str(HOME)
    if not os.path.isdir(cwd): cwd = str(HOME)
    marker = "__OVERCODE_CWD_" + secrets.token_hex(5) + "__"
    wrapped = command.rstrip() + f"\n__oc_rc=$?; printf '\\n{marker}%s\\t%s\\n' \"$__oc_rc\" \"$PWD\""
    try:
        p = subprocess.run(["bash", "-lc", wrapped], cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout, text=True,
                           errors="replace", env=dict(os.environ, TERM="xterm-256color"))
        output = p.stdout or ""
        rc = p.returncode
        m = re.search(re.escape(marker) + r"(\d+)\t([^\r\n]+)", output)
        if m:
            try:
                rc = int(m.group(1)); newcwd = os.path.abspath(m.group(2))
                if os.path.isdir(newcwd): STATE["cwd"] = newcwd
                output = output[:m.start()] + output[m.end():]
            except Exception: pass
        return {"exit_code": rc, "output": output[-18000:], "cwd": STATE["cwd"], "timed_out": False}
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes): out = out.decode("utf-8", "replace")
        return {"exit_code": 124, "output": str(out)[-14000:] + "\n[Tempo limite atingido; processo interrompido.]",
                "cwd": STATE["cwd"], "timed_out": True}
    except Exception as e:
        return {"exit_code": 1, "output": f"Falha ao executar: {e}", "cwd": STATE["cwd"], "timed_out": False}


def ssh_command(profile, command):
    if not profile:
        raise RuntimeError("Configure um perfil SSH na seção Ferramentas avançadas.")
    target = f"{profile['user']}@{profile['host']}"
    args = ["ssh", "-p", str(profile.get("port", 22)), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30"]
    key = profile.get("key", "")
    if key:
        kp = Path(key).expanduser().resolve()
        if not str(kp).startswith(str(HOME.resolve()) + os.sep) or not kp.is_file():
            raise RuntimeError("A chave SSH precisa ser um arquivo existente dentro da sua pasta pessoal.")
        args += ["-i", str(kp)]
    args += [target, "bash", "-lc", command]
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=180, text=True, errors="replace")
        return {"exit_code": p.returncode, "output": (p.stdout or "")[-16000:], "cwd": "SSH:" + target, "timed_out": False}
    except subprocess.TimeoutExpired as e:
        return {"exit_code": 124, "output": "Tempo limite ao executar no SSH.", "cwd": "SSH:" + target, "timed_out": True}


def continue_agent(obj, messages, rounds=4):
    for _ in range(rounds):
        response, model_name = model_request(messages, max_tokens=3000)
        if not response:
            response = "Não recebi uma resposta utilizável do modelo."
        messages.append({"role": "assistant", "content": response})
        match = BASH_BLOCK.search(response)
        if not match:
            obj["messages"] = messages
            persist_session(obj)
            return {"answer": response, "session_id": obj["id"], "model": model_name,
                    "activity": STATE["activity"][:12], "pending_command": None}
        command = match.group(1).strip()
        if not command:
            obj["messages"] = messages
            persist_session(obj)
            return {"answer": response, "session_id": obj["id"], "model": model_name, "pending_command": None}
        s = STATE["settings"]
        risk = bool(DANGEROUS.search(command) or INSTALL.search(command))
        must_ask = (s["mode"] == "ask" or risk)
        if must_ask:
            STATE["pending"] = {"kind": "agent", "session_id": obj["id"], "command": command, "messages": messages,
                                "reason": "Comando de risco/instalação" if risk else "Modo perguntar"}
            obj["messages"] = messages
            persist_session(obj)
            add_activity("command", "Aguardando aprovação", command, "waiting")
            return {"answer": response, "session_id": obj["id"], "model": model_name,
                    "pending_command": {"command": command, "reason": STATE["pending"]["reason"]},
                    "activity": STATE["activity"][:12]}
        add_activity("command", "Executando comando", command, "running")
        result = run_shell(command, obj.get("cwd"))
        obj["cwd"] = result.get("cwd", obj.get("cwd"))
        add_activity("terminal", f"Comando terminou (código {result['exit_code']})", result["output"][:1400],
                     "done" if result["exit_code"] == 0 else "warning")
        tool_msg = ("SAÍDA REAL DO TERMINAL (não invente nem altere):\n"
                    f"exit_code={result['exit_code']}\nDiretório atual: {result['cwd']}\n"
                    f"{result['output'] or '(sem saída)'}\n"
                    "Continue a tarefa com base nessa saída. Verifique se precisa de outro comando; emita só um próximo bloco bash ou dê a resposta final.")
        messages.append({"role": "user", "content": tool_msg})
    messages.append({"role": "user", "content": "Pare de executar novos comandos e informe o que foi feito, o que falta e os resultados verificados."})
    response, model_name = model_request(messages, max_tokens=1800)
    messages.append({"role": "assistant", "content": response or "O limite de etapas foi atingido; revise a saída do terminal na atividade."})
    obj["messages"] = messages
    persist_session(obj)
    return {"answer": messages[-1]["content"], "session_id": obj["id"], "model": model_name,
            "pending_command": None, "activity": STATE["activity"][:12]}


def chat(payload):
    with LOCK:
        obj = load_session(str(payload.get("session_id", "")))
        if STATE.get("pending") is not None:
            raise ValueError("Há uma ação aguardando aprovação. Aprove ou recuse antes de enviar outra mensagem.")
        user_text = str(payload.get("message", "")).strip()[:12000]
        if not user_text:
            raise ValueError("Escreva uma mensagem primeiro.")
        if not obj["messages"]:
            obj["title"] = re.sub(r"\s+", " ", user_text)[:52]
        obj["cwd"] = STATE["cwd"] or obj.get("cwd", str(HOME))
        messages = [{"role": "system", "content": current_system_prompt()}]
        messages.extend(obj["messages"][-30:])
        messages.append({"role": "user", "content": user_text})
        add_activity("chat", "Nova mensagem", user_text[:180], "done")
        mode = STATE["settings"]["mode"]
        if mode == "plan" and not STATE["settings"].get("plan_approved"):
            response, model_name = model_request(messages, max_tokens=1800)
            obj["messages"] = messages + [{"role": "assistant", "content": response}]
            persist_session(obj)
            s = STATE["settings"]; s["plan_pending"] = True; s["pending_plan_task"] = user_text
            write_json(SETTINGS_FILE, s)
            add_activity("plan", "Plano aguardando aprovação", response[:1200], "waiting")
            return {"answer": response, "session_id": obj["id"], "model": model_name,
                    "plan_pending": True, "pending_command": None, "activity": STATE["activity"][:12]}
        return continue_agent(obj, messages)


def safe_plugin_url(url):
    u = urlparse(url)
    return u.scheme == "https" and u.hostname in ("github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com")


def plugin_list():
    result = []
    for d in sorted(PLUGINS.iterdir()) if PLUGINS.exists() else []:
        if not d.is_dir(): continue
        meta = read_json(d / "plugin.json", {})
        result.append({"id": d.name, "name": meta.get("name", d.name),
                       "description": meta.get("description", "Extensão baixada; revise antes de usar."),
                       "enabled": bool(meta.get("enabled", False)), "source": meta.get("source", "local"),
                       "permissions": meta.get("permissions", [])})
    return result


def download_plugin(url):
    if not safe_plugin_url(url):
        raise ValueError("Por segurança, a instalação direta aceita somente arquivos HTTPS do GitHub. Outros endereços precisam de revisão manual.")
    req = urllib.request.Request(url, headers={"User-Agent": "Overcode-Hub/2.6"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read(10 * 1024 * 1024 + 1)
    if len(raw) > 10 * 1024 * 1024:
        raise ValueError("O pacote ultrapassa 10 MB.")
    try: z = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile: raise ValueError("O link não aponta para um ZIP válido.")
    folder = "plugin-" + secrets.token_hex(4)
    dst = PLUGINS / folder; dst.mkdir(parents=True, exist_ok=False)
    try:
        total = 0
        for info in z.infolist():
            name = info.filename.replace("\\", "/")
            parts = Path(name).parts
            if not name or name.startswith("/") or ".." in parts or info.is_dir(): continue
            if info.file_size > 2 * 1024 * 1024: continue
            total += info.file_size
            if total > 20 * 1024 * 1024: break
            relative = Path(*parts[1:]) if len(parts) > 1 else Path(parts[0])
            if not relative.parts: continue
            target = (dst / relative).resolve()
            if not str(target).startswith(str(dst.resolve()) + os.sep): continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(info))
        manifest = read_json(dst / "plugin.json", {})
        manifest.update({"source": url, "enabled": False,
                         "notice": "Baixado sem executar. Revise o código e as permissões antes de ativar.",
                         "permissions": manifest.get("permissions", [])})
        write_json(dst / "plugin.json", manifest)
        return {"id": folder, "name": manifest.get("name", folder), "enabled": False}
    except Exception:
        shutil.rmtree(dst, ignore_errors=True); raise


def normalize_api_path(path):
    """Mantém /api antigo e oferece /api/v1 como contrato estável."""
    if path == "/api/v1":
        return "/api"
    if path.startswith("/api/v1/"):
        return "/api/" + path[len("/api/v1/"):]
    return path


def api_models():
    configured = read_json(OC / "provedores.json", {})
    configured = configured if isinstance(configured, dict) else {}
    try:
        selected = (OC / "ultimo-modelo").read_text(encoding="utf-8").strip()
    except Exception:
        selected = ""
    providers = []
    for pid, (name, base_url, default_model) in PROVIDERS.items():
        cfg = configured.get(pid, {})
        providers.append({
            "id": pid,
            "name": name,
            "configured": bool(cfg.get("chave")),
            "model": cfg.get("modelo") or default_model or None,
            "base_url": (cfg.get("url") or base_url or None),
        })
    local_models = []
    model_dir = OC / "modelos"
    for mid, (name, filename) in LOCAL_MODELS.items():
        local_models.append({
            "id": mid,
            "name": name,
            "file": filename,
            "installed": (model_dir / filename).is_file(),
            "active": selected == mid,
        })
    backend, error = active_backend()
    return {
        "active": ({"name": backend["name"], "model": backend["model"], "local": backend["local"]}
                   if backend else None),
        "selected_id": selected or None,
        "providers": providers,
        "local_models": local_models,
        "engine_error": error,
    }


def api_capabilities():
    return {
        "api_version": "v1",
        "hub_version": VERSION,
        "features": {
            "chat": True,
            "sessions": True,
            "model_status": True,
            "terminal": True,
            "ssh": True,
            "activity_feed": True,
            "approval_queue": True,
            "plans": True,
            "skills_catalog": True,
            "plugin_download": True,
            "plugin_execution": False,
            "voice_ui": True,
        },
        "security": {
            "localhost_only_by_default": True,
            "lan_requires_bearer_token": True,
            "secrets_are_not_returned_by_api": True,
            "risky_commands_require_approval": True,
            "ssh_password_storage": False,
            "downloaded_plugins_execute_automatically": False,
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "OvercodeHub/2.6"
    def log_message(self, fmt, *args):
        if os.environ.get("OVERCODE_HUB_LOG") == "1": super().log_message(fmt, *args)

    def _auth_ok(self):
        if not self.server.remote_mode: return True
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        try: stored = AUTH_FILE.read_text().strip()
        except Exception: stored = ""
        return bool(stored) and hmac.compare_digest(token, stored)

    def _json(self, data, status=200):
        b = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff"); self.end_headers(); self.wfile.write(b)

    def _body(self):
        n = min(int(self.headers.get("Content-Length", "0")), 2_000_000)
        if n <= 0: return {}
        try: return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception: return {}

    def do_GET(self):
        u = urlparse(self.path); path = normalize_api_path(u.path)
        if path.startswith("/api/") and not self._auth_ok(): return self._json({"error": "Não autorizado"}, 401)
        if path == "/api/openapi.json":
            schema = read_json(OPENAPI_FILE, None)
            if not isinstance(schema, dict):
                return self._json({"error": "Contrato OpenAPI não instalado."}, 404)
            return self._json(schema)
        if path == "/api/version":
            return self._json({"version": VERSION, "api_version": "v1"})
        if path == "/api/models":
            return self._json(api_models())
        if path == "/api/capabilities":
            return self._json(api_capabilities())
        if path == "/api/health":
            backend, err = active_backend()
            return self._json({"ok": True, "version": VERSION, "engine": backend["name"] if backend else None,
                               "engine_error": err, "cwd": STATE["cwd"]})
        if path == "/api/state":
            s = dict(STATE["settings"]); s.pop("ssh_profile", None)
            backend, err = active_backend()
            return self._json({"version": VERSION, "settings": s, "engine": backend["name"] if backend else None,
                               "engine_error": err, "cwd": STATE["cwd"], "activity": STATE["activity"][:20],
                               "pending": STATE["pending"] is not None})
        if path == "/api/settings":
            s = dict(STATE["settings"]); s.pop("ssh_profile", None)
            return self._json(s)
        if path == "/api/sessions":
            arr = []
            for f in SESSIONS.glob("*.json"):
                d = read_json(f, {})
                if d.get("id"): arr.append({"id": d["id"], "title": d.get("title", "Conversa"), "updated": d.get("updated", 0)})
            arr.sort(key=lambda x: x["updated"], reverse=True)
            return self._json(arr[:40])
        if path.startswith("/api/session/"):
            sid = path.rsplit("/", 1)[-1]
            obj = load_session(sid)
            return self._json(obj)
        if path == "/api/plugins": return self._json(plugin_list())
        if path == "/api/skills":
            arr=[]
            for p in SKILLS.glob("*/SKILL.md"):
                txt=p.read_text(encoding="utf-8", errors="replace")[:6000]
                arr.append({"name":p.parent.name,"preview":txt[:500]})
            return self._json(arr)
        if path == "/api/connectors":
            s=STATE["settings"]; prof=s.get("ssh_profile")
            return self._json([{"id":"ssh","name":"SSH","available":bool(shutil.which("ssh")),
                               "configured":bool(prof),"active":bool(s.get("active_ssh")),
                               "target":(prof.get("user","?")+"@"+prof.get("host","?")) if prof else ""}])
        if path == "/": path = "/index.html"
        if path.startswith("/assets/"): path = path
        clean = Path(path.lstrip("/"))
        target = (WEB / clean).resolve()
        if not str(target).startswith(str(WEB.resolve()) + os.sep) or not target.is_file():
            return self._json({"error": "Não encontrado"}, 404)
        raw = target.read_bytes(); mime = "text/html; charset=utf-8" if target.suffix == ".html" else "application/octet-stream"
        if target.suffix == ".js": mime = "text/javascript; charset=utf-8"
        if target.suffix == ".css": mime = "text/css; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", mime); self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-cache"); self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers(); self.wfile.write(raw)

    def do_POST(self):
        if not self._auth_ok(): return self._json({"error": "Não autorizado"}, 401)
        payload = self._body(); path = normalize_api_path(urlparse(self.path).path)
        try:
            with LOCK:
                if path == "/api/chat": return self._json(chat(payload))
                if path == "/api/settings":
                    s=STATE["settings"]
                    if "voice_enabled" in payload: s["voice_enabled"] = bool(payload["voice_enabled"])
                    if "voice_uri" in payload: s["voice_uri"] = str(payload["voice_uri"])[:256]
                    if "voice_web_uri" in payload: s["voice_web_uri"] = str(payload["voice_web_uri"])[:256]
                    if "voice_android_uri" in payload: s["voice_android_uri"] = str(payload["voice_android_uri"])[:256]
                    for key, low, high in (("voice_rate",0.7,1.4),("voice_pitch",0.7,1.4),("voice_volume",0.0,1.0)):
                        if key in payload:
                            try: value=float(payload[key])
                            except (TypeError,ValueError): raise ValueError(f"Valor inválido para {key}.")
                            if not (value == value and abs(value) != float("inf")): raise ValueError(f"Valor inválido para {key}.")
                            s[key]=max(low,min(high,value))
                    if "advanced_collapsed" in payload: s["advanced_collapsed"] = bool(payload["advanced_collapsed"])
                    if "custom_plan" in payload: s["custom_plan"] = str(payload["custom_plan"])[:5000]
                    if "project_dir" in payload:
                        directory=Path(str(payload["project_dir"])).expanduser().resolve()
                        if not directory.is_dir(): raise ValueError("A pasta de projeto precisa existir.")
                        s["project_dir"] = str(directory)
                    write_json(SETTINGS_FILE,s); return self._json({"ok":True})
                if path == "/api/mode":
                    mode=str(payload.get("mode","normal"))
                    if mode not in ("normal","ask","plan","auto","custom"): raise ValueError("Modo inválido")
                    s=STATE["settings"]
                    if mode != s["mode"]: s["plan_approved"]=False; s["plan_pending"]=False
                    s["mode"]=mode
                    if "custom_plan" in payload: s["custom_plan"]=str(payload["custom_plan"])[:5000]
                    write_json(SETTINGS_FILE,s); return self._json({"ok":True,"mode":mode,"plan_approved":s["plan_approved"]})
                if path == "/api/plan/new":
                    s=STATE["settings"]; s["mode"]="plan"; s["plan_approved"]=False; s["plan_pending"]=False
                    s.pop("pending_plan_task",None); write_json(SETTINGS_FILE,s)
                    return self._json({"ok":True,"mode":"plan"})
                if path == "/api/plan/approve":
                    s=STATE["settings"]
                    if not s.get("plan_pending"): raise ValueError("Não há plano aguardando aprovação.")
                    task=s.get("pending_plan_task", "")
                    s["plan_approved"]=True; s["plan_pending"]=False; write_json(SETTINGS_FILE,s)
                    obj=load_session(str(payload.get("session_id","")))
                    messages=[{"role":"system","content":current_system_prompt()}]
                    messages.extend(obj.get("messages",[])[-30:])
                    messages.append({"role":"user","content":f"O plano para esta tarefa foi aprovado. Comece a executá-lo agora, uma etapa por vez, e verifique cada resultado: {task}"})
                    return self._json(continue_agent(obj,messages))
                if path == "/api/command/approve":
                    pending=STATE.get("pending")
                    if not pending: raise ValueError("Não há comando aguardando aprovação.")
                    STATE["pending"]=None
                    kind=pending.get("kind", "agent")
                    cmd=pending["command"]
                    if kind == "ssh":
                        result=ssh_command(pending["profile"],cmd)
                        add_activity("ssh","Comando SSH aprovado",cmd+"\n"+result["output"][:1000],"done" if result["exit_code"]==0 else "warning")
                        return self._json(result)
                    if kind == "terminal":
                        result=run_shell(cmd)
                        add_activity("terminal","Comando manual aprovado",cmd+"\n"+result["output"][:1000],"done" if result["exit_code"]==0 else "warning")
                        return self._json(result)
                    obj=load_session(pending["session_id"])
                    result=run_shell(cmd,obj.get("cwd")); obj["cwd"]=result.get("cwd",obj.get("cwd"))
                    add_activity("terminal","Comando aprovado e executado",cmd+"\n"+result["output"][:1000],"done" if result["exit_code"]==0 else "warning")
                    messages=pending["messages"]
                    messages.append({"role":"user","content":f"SAÍDA REAL DO TERMINAL: exit_code={result['exit_code']}\n{result['output']}\nContinue e verifique."})
                    return self._json(continue_agent(obj,messages))
                if path == "/api/command/reject":
                    pending=STATE.get("pending"); STATE["pending"]=None
                    if not pending: raise ValueError("Não há comando aguardando aprovação.")
                    if pending.get("kind") in ("terminal", "ssh"):
                        return self._json({"ok":True,"rejected":True,"message":"Comando recusado; nada foi executado."})
                    obj=load_session(pending["session_id"])
                    messages=pending["messages"]+[ {"role":"user","content":"Não execute esse comando. Proponha uma alternativa segura."} ]
                    return self._json(continue_agent(obj,messages))
                if path == "/api/terminal":
                    cmd=str(payload.get("command",""))[:6000].strip()
                    if not cmd: raise ValueError("Digite um comando.")
                    if DANGEROUS.search(cmd) or INSTALL.search(cmd):
                        STATE["pending"]={"kind":"terminal", "session_id":"", "command":cmd,"messages":[],"reason":"Comando manual de risco/instalação"}
                        return self._json({"pending_command":{"command":cmd,"reason":STATE['pending']['reason']}})
                    result=run_shell(cmd); add_activity("terminal", "Terminal manual",cmd+"\n"+result["output"][:1000],"done" if result["exit_code"]==0 else "warning")
                    return self._json(result)
                if path == "/api/ssh/connect":
                    host=str(payload.get("host","" )).strip(); user=str(payload.get("user","" )).strip()
                    port=int(payload.get("port",22)); key=str(payload.get("key","" )).strip()
                    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}",host): raise ValueError("Host inválido")
                    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}",user): raise ValueError("Usuário SSH inválido")
                    if not 1<=port<=65535: raise ValueError("Porta inválida")
                    if key:
                        kp=Path(key).expanduser().resolve()
                        if not str(kp).startswith(str(HOME.resolve())+os.sep) or not kp.is_file(): raise ValueError("A chave deve existir dentro da pasta pessoal.")
                    s=STATE["settings"]; profile={"host":host,"user":user,"port":port,"key":key}
                    s["ssh_profile"]=profile; s["active_ssh"]=False; write_json(SETTINGS_FILE,s)
                    probe=ssh_command(profile,"printf OVERCODE_SSH_OK && hostname")
                    if probe["exit_code"] != 0 or "OVERCODE_SSH_OK" not in probe["output"]:
                        return self._json({"error":"Não consegui autenticar por SSH. Confira host, usuário, porta e chave; esta versão usa chave/ssh-agent e não armazena senha. Saída: "+probe["output"][:800]},400)
                    s["active_ssh"]=True; write_json(SETTINGS_FILE,s)
                    return self._json({"ok":True,"target":f"{user}@{host}","hostname":probe["output"].replace("OVERCODE_SSH_OK","").strip(),"note":"Conexão SSH testada com sucesso. Senha não foi armazenada."})
                if path == "/api/ssh/disconnect":
                    STATE["settings"]["active_ssh"]=False; write_json(SETTINGS_FILE,STATE["settings"]); return self._json({"ok":True})
                if path == "/api/ssh/run":
                    prof=STATE["settings"].get("ssh_profile")
                    if not STATE["settings"].get("active_ssh") or not prof: raise ValueError("SSH não está conectado.")
                    cmd=str(payload.get("command",""))[:6000].strip()
                    if not cmd: raise ValueError("Digite um comando remoto.")
                    if DANGEROUS.search(cmd) or INSTALL.search(cmd):
                        STATE["pending"]={"kind":"ssh", "session_id":"", "command":cmd,"profile":prof,"messages":[],"reason":"Comando SSH de risco/instalação"}
                        return self._json({"pending_command":{"command":cmd,"reason":STATE['pending']['reason']}})
                    result=ssh_command(prof,cmd); add_activity("ssh","Comando SSH",cmd+"\n"+result['output'][:1000],"done" if result['exit_code']==0 else "warning")
                    return self._json(result)
                if path == "/api/plugins/download":
                    plugin=download_plugin(str(payload.get("url","")))
                    add_activity("plugin","Plugin baixado",plugin["name"],"done"); return self._json(plugin)
                if path == "/api/plugins/toggle":
                    pid=str(payload.get("id","")); folder=(PLUGINS/pid).resolve()
                    if not str(folder).startswith(str(PLUGINS.resolve())+os.sep): raise ValueError("Plugin inválido")
                    mf=folder/"plugin.json"; data=read_json(mf,{})
                    if not mf.exists(): raise ValueError("Manifesto do plugin não encontrado")
                    data["enabled"]=bool(payload.get("enabled",False)); write_json(mf,data)
                    return self._json({"ok":True,"enabled":data["enabled"],"notice":"O estado foi alterado; o código do plugin não é executado automaticamente."})
                raise ValueError("Rota desconhecida")
        except Exception as e:
            self._json({"error":str(e)},400)


def main():
    global PORT
    ap=argparse.ArgumentParser(description="Painel local do Overcode")
    ap.add_argument("--host",default=HOST); ap.add_argument("--port",type=int,default=PORT)
    ap.add_argument("--open",action="store_true",help="abre o painel no navegador")
    args=ap.parse_args(); PORT=args.port
    remote=args.host not in ("127.0.0.1","localhost","::1")
    if remote:
        if not AUTH_FILE.exists():
            token=secrets.token_urlsafe(36); AUTH_FILE.write_text(token); os.chmod(AUTH_FILE,0o600)
        try: token=AUTH_FILE.read_text().strip()
        except Exception: token=""
        print("Token Bearer para o painel e o APK (mantenha privado):\n"+token)
    srv=ThreadingHTTPServer((args.host,args.port),Handler); srv.remote_mode=remote
    print(f"Overcode Hub v{VERSION} em http://{args.host}:{args.port}")
    if remote: print("Acesso remoto protegido por Bearer token. Não exponha esta porta publicamente.")
    else: print("Somente este aparelho pode acessar por padrão. Ctrl+C encerra.")
    if args.open:
        import webbrowser; webbrowser.open(f"http://127.0.0.1:{args.port}/")
    try: srv.serve_forever(poll_interval=.5)
    except KeyboardInterrupt: print("\nOvercode Hub encerrado.")
    finally: srv.server_close()

if __name__=="__main__": main()