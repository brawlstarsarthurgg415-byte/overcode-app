/** Cliente JavaScript para a API Overcode Hub v1. */
export class OvercodeError extends Error {
  constructor(message, status = 0) { super(message); this.name = "OvercodeError"; this.status = status; }
}

export class Overcode {
  constructor({ baseUrl = "http://127.0.0.1:8765", token = "", fetchImpl = globalThis.fetch } = {}) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.token = token;
    this.fetchImpl = fetchImpl;
  }

  async request(path, data) {
    const headers = { Accept: "application/json" };
    if (data !== undefined) headers["Content-Type"] = "application/json";
    if (this.token) headers.Authorization = "Bearer " + this.token;
    let response;
    try {
      response = await this.fetchImpl(this.baseUrl + path, {
        method: data === undefined ? "GET" : "POST",
        headers,
        body: data === undefined ? undefined : JSON.stringify(data)
      });
    } catch (error) {
      throw new OvercodeError("Não foi possível alcançar o Overcode Hub: " + error.message);
    }
    const result = await response.json();
    if (!response.ok) throw new OvercodeError(result.error || "Erro HTTP " + response.status, response.status);
    return result;
  }

  health() { return this.request("/api/v1/health"); }
  state() { return this.request("/api/v1/state"); }
  models() { return this.request("/api/v1/models"); }
  capabilities() { return this.request("/api/v1/capabilities"); }
  chat(message, session_id) {
    return this.request("/api/v1/chat", { message, ...(session_id ? { session_id } : {}) });
  }
  sessions() { return this.request("/api/v1/sessions"); }
  terminal(command) { return this.request("/api/v1/terminal", { command }); }
  setMode(mode, custom_plan) {
    return this.request("/api/v1/mode", { mode, ...(custom_plan ? { custom_plan } : {}) });
  }
}