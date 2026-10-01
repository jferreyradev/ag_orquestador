# ⚡ Antigravity Zig MCP Bridge (Orquestador Multi-Modelo)

Servidor MCP ultraligero y de alto rendimiento escrito en **Zig (0.16)**. Conecta **Antigravity** con tu servidor local de **Ollama** y cualquier proveedor de IA en la nube (Groq, Cerebras, Google Gemini, OpenRouter, etc.) con modelos **100% configurables sin recompilar**.

---

## 🚀 Características Principales

1. **Ultraligero y Eficiente:**
   - Binario compilado nativo de solo **~539 KB**.
   - Consume apenas **~2 a 5 MB de RAM** en segundo plano.
   - Cero dependencias externas complejas (sin runtime de Python ni cientos de crates de Rust).
2. **Modelos 100% Dinámicos (`config.json`):**
   - Agrega, cambia o elimina modelos editando `config.json` en cualquier momento.
   - El puente recarga la configuración en cada llamada; **no requiere reiniciar Antigravity ni recompilar**.
3. **Soporte Local + Cloud Unificado:**
   - **Local:** Conexión directa a Ollama (`/api/generate`).
   - **Cloud:** Compatible con cualquier API con formato OpenAI (`/v1/chat/completions`) usando tokens por variables de entorno.
4. **Herramienta de Auto-Configuración (`add_model`):**
   - Puedes pedirle a Antigravity en lenguaje natural que registre un nuevo modelo y lo agregará automáticamente a `config.json`.

---

## 🛠️ Herramientas Expuestas al Agente

| Herramienta | Parámetros | Descripción |
| :--- | :--- | :--- |
| `ask_ollama` | `prompt` *(req)*, `model` *(opt)* | Consulta un modelo local corriendo en Ollama (ej: `llama3.2`, `qwen2.5-coder:7b`, `deepseek-r1:8b`). |
| `ask_model` | `model_id` *(req)*, `prompt` *(req)* | Consulta cualquier modelo configurado en `config.json` por su ID (local o cloud). |
| `list_models` | *(ninguno)* | Devuelve la lista completa de modelos registrados y sus proveedores. |
| `add_model` | `id`, `name`, `provider`, `model`, `endpoint`, `api_key_env` | Agrega un nuevo modelo a `config.json` dinámicamente. |

---

## 📋 Configuración de Modelos (`config.json`)

```json
{
  "ollama_url": "http://127.0.0.1:11434",
  "default_model": "llama3.2",
  "models": [
    {
      "id": "llama3.2",
      "name": "Llama 3.2 3B (Local)",
      "provider": "ollama",
      "model": "llama3.2"
    },
    {
      "id": "groq",
      "name": "Groq Llama 3.3 70B (Cloud)",
      "provider": "openai",
      "endpoint": "https://api.groq.com/openai/v1/chat/completions",
      "model": "llama-3.3-70b-versatile",
      "api_key_env": "GROQ_API_KEY"
    },
    {
      "id": "cerebras",
      "name": "Cerebras Llama 3.3 70B (Cloud)",
      "provider": "openai",
      "endpoint": "https://api.cerebras.ai/v1/chat/completions",
      "model": "llama-3.3-70b",
      "api_key_env": "CEREBRAS_API_KEY"
    },
    {
      "id": "gemini",
      "name": "Google Gemini 2.5 Flash (Cloud)",
      "provider": "openai",
      "endpoint": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      "model": "gemini-2.5-flash",
      "api_key_env": "GEMINI_API_KEY"
    },
    {
      "id": "openrouter",
      "name": "OpenRouter Claude 3.5 Sonnet (Cloud)",
      "provider": "openai",
      "endpoint": "https://openrouter.ai/api/v1/chat/completions",
      "model": "anthropic/claude-3.5-sonnet",
      "api_key_env": "OPENROUTER_API_KEY"
    }
  ]
}
```

---

## 🔌 Conexión con Antigravity

Edita tu archivo de configuración global de MCP en:
`~/.gemini/config/mcp_config.json`

Agrega tu servidor:

```json
{
  "mcpServers": {
    "orquestador_zig": {
      "command": "/Users/jferreyradev/projects/ag/ag_orquestador/ag_bridge",
      "args": [],
      "env": {
        "GROQ_API_KEY": "gsk_...",
        "CEREBRAS_API_KEY": "csk-...",
        "GEMINI_API_KEY": "AIzaSy...",
        "OPENROUTER_API_KEY": "sk-or-..."
      }
    }
  }
}
```

---

## 🔨 Compilación Manual (si modificas `main.zig`)

```bash
# Opción 1: Compilación directa ultrarrápida
zig build-exe -O ReleaseFast main.zig -femit-bin=ag_bridge

# Opción 2: Usando zig build estándar
zig build -Doptimize=ReleaseFast
```

---

## 🧪 Pruebas Rápidas en Terminal

```bash
# Probar inicio e handshake JSON-RPC
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./ag_bridge

# Listar herramientas
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./ag_bridge

# Consultar modelos configurados
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_models","arguments":{}}}' | ./ag_bridge
```
