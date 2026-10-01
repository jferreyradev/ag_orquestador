# ⚡ Antigravity Zig MCP Bridge (Orquestador Multi-Modelo Resiliente)

Servidor MCP ultraligero, de alto rendimiento y cero dependencias externas, escrito en **Zig (0.16)**. Conecta **Antigravity** con tu servidor local de **Ollama** y los mejores proveedores de IA en la nube (Groq, Cerebras, Google Gemini, Mistral Codestral, OpenRouter, GitHub Models, etc.), incorporando **conmutación automática ante saturación de cuota (Auto-Fallback)**, **pool multi-token por modelo** y **telemetría de consumo de tokens**.

---

## 🚀 Ventajas Clave

1. **Ultraligero y Eficiente:**
   - Binario compilado nativo de solo **~574 KB** (macOS ARM64) y **~933 KB** (Windows x64).
   - Consume apenas **~2 a 5 MB de RAM**.
   - Cero dependencias complejas (sin runtime de Python, Node.js ni centenares de crates de Rust).
2. **Soporte Local de Ollama de Primer Nivel:**
   - Consulta cualquier modelo local (`qwen2.5-coder:7b`, `deepseek-r1:8b`, `llama3.2`, etc.) sin costo ni internet.
   - Actúa como el seguro final de la cadena de conmutación: si la nube se satura o se corta internet, tus tareas nunca se interrumpen.
3. **Conmutación Automática (Auto-Fallback Resiliente):**
   - Si un proveedor en la nube supera su cuota gratuita o devuelve **HTTP 429 (Rate Limit)**, el puente salta automáticamente al siguiente en microsegundos (`groq` ➔ `cerebras` ➔ `gemini` ➔ `codestral` ➔ `qwen-local`).
4. **Pool Multi-Token por Modelo (`api_keys`):**
   - Si tienes varios tokens/cuentas gratuitas para un mismo proveedor (ej: 3 keys de Groq), rota de inmediato a la siguiente clave ante `HTTP 429` antes de cambiar de modelo, multiplicando tu cuota x2 o x3.
5. **Telemetría y Control de Consumo de Tokens:**
   - Cada respuesta indica los tokens consumidos (Entrada / Salida / Total).
   - La herramienta `get_stats` acumula el conteo global de tokens y conmutaciones realizadas en la sesión.
6. **Configuración Dinámica (`config.json`):**
   - Se recarga en cada consulta sin necesidad de reiniciar Antigravity ni recompilar.
   - Soporta API Keys tanto por variables de entorno (`api_key_env`) como directas (`api_key` o `api_keys`).

---

## 🛠️ Catálogo de Herramientas MCP

| Herramienta | Parámetros | Descripción |
| :--- | :--- | :--- |
| `ask_resilient` | `prompt` *(req)*, `initial_model` *(opt)* | **Peticiones desatendidas y robustas.** Conmuta automáticamente de modelo y de token si hay saturación o HTTP 429 hasta completar la tarea. |
| `ask_model` | `model_id` *(req)*, `prompt` *(req)* | Consulta un modelo específico configurado en `config.json` por su ID (ej: `groq`, `cerebras`, `gemini`, `codestral`, `deepseek-local`). |
| `ask_ollama` | `prompt` *(req)*, `model` *(opt)* | Consulta rápida al modelo local predeterminado de Ollama (o cualquier modelo local pasado en `model`). |
| `get_stats` | *(ninguno)* | Devuelve el total acumulado de tokens consumidos y conmutaciones de fallback de la sesión. |
| `list_models` | *(ninguno)* | Muestra todos los modelos registrados y el orden de la cadena de fallback. |
| `add_model` | `id`, `name`, `provider`, `model`, `endpoint`, `api_key_env`, `api_key` | Registra un nuevo modelo dinámicamente en caliente. |

---

## 📋 Configuración (`config.json`)

```json
{
  "ollama_url": "http://127.0.0.1:11434",
  "default_model": "qwen2.5-coder:7b",
  "fallback_chain": [
    "groq",
    "cerebras",
    "gemini",
    "codestral",
    "qwen-local"
  ],
  "models": [
    {
      "id": "qwen-local",
      "name": "Qwen 2.5 Coder 7B (Especialista Código Local)",
      "provider": "ollama",
      "model": "qwen2.5-coder:7b"
    },
    {
      "id": "deepseek-local",
      "name": "DeepSeek R1 8B (Razonador & Arquitectura Local)",
      "provider": "ollama",
      "model": "deepseek-r1:8b"
    },
    {
      "id": "llama-local",
      "name": "Llama 3.2 3B (Asistente Rápido Co-work Local)",
      "provider": "ollama",
      "model": "llama3.2"
    },
    {
      "id": "groq",
      "name": "Groq Llama 3.3 70B (Cloud Ultra-Rápido)",
      "provider": "openai",
      "endpoint": "https://api.groq.com/openai/v1/chat/completions",
      "model": "llama-3.3-70b-versatile",
      "api_key_env": "GROQ_API_KEY"
    },
    {
      "id": "cerebras",
      "name": "Cerebras Llama 3.3 70B (Generación Código a 1800 t/s)",
      "provider": "openai",
      "endpoint": "https://api.cerebras.ai/v1/chat/completions",
      "model": "llama-3.3-70b",
      "api_key_env": "CEREBRAS_API_KEY"
    },
    {
      "id": "gemini",
      "name": "Google Gemini 2.5 Flash (Contexto Gigante 1M tokens)",
      "provider": "openai",
      "endpoint": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      "model": "gemini-2.5-flash",
      "api_key_env": "GEMINI_API_KEY"
    },
    {
      "id": "codestral",
      "name": "Mistral Codestral 22B (Especialista en 80+ Lenguajes)",
      "provider": "openai",
      "endpoint": "https://api.mistral.ai/v1/chat/completions",
      "model": "codestral-latest",
      "api_key_env": "MISTRAL_API_KEY"
    },
    {
      "id": "openrouter-free",
      "name": "OpenRouter Qwen 2.5 Coder 32B (Cloud Freemium)",
      "provider": "openai",
      "endpoint": "https://api.openrouter.ai/api/v1/chat/completions",
      "model": "qwen/qwen-2.5-coder-32b-instruct:free",
      "api_key_env": "OPENROUTER_API_KEY"
    },
    {
      "id": "github-gpt4o",
      "name": "GitHub Models GPT-4o (Free con GitHub Token)",
      "provider": "openai",
      "endpoint": "https://models.inference.ai.azure.com/chat/completions",
      "model": "gpt-4o",
      "api_key_env": "GITHUB_TOKEN"
    }
  ]
}
```

---

## 🔌 Registro en Antigravity

Edita `~/.gemini/config/mcp_config.json`:

```json
{
  "mcpServers": {
    "orquestador": {
      "command": "/Users/jferreyradev/projects/ag/ag_orquestador/ag_bridge",
      "args": [],
      "env": {
        "GROQ_API_KEY": "gsk_...",
        "CEREBRAS_API_KEY": "csk-...",
        "GEMINI_API_KEY": "AIzaSy...",
        "MISTRAL_API_KEY": "...",
        "OPENROUTER_API_KEY": "sk-or-...",
        "GITHUB_TOKEN": "ghp_..."
      }
    }
  }
}
```

---

## 🌐 Enlaces para Obtener las API Keys Gratuitas (Free Tiers)

Para registrar tus tokens gratuitos en minutos (sin tarjeta de crédito):

| Proveedor | Modelo Recomendado | Cuota Gratuita | Enlace Directo |
| :--- | :--- | :--- | :--- |
| **Google AI Studio** | `gemini-2.5-flash` | 15 RPM / 1M TPM / 1500 RPD | [aistudio.google.com](https://aistudio.google.com) |
| **Groq Cloud** | `llama-3.3-70b-versatile` | 30 RPM / 8K TPM / 14,400 RPD | [console.groq.com](https://console.groq.com) |
| **Cerebras Cloud** | `llama-3.3-70b` | 30 RPM / 60K TPM / 14,400 RPD | [cloud.cerebras.ai](https://cloud.cerebras.ai) |
| **OpenRouter** | `qwen/qwen-2.5-coder-32b-instruct:free` | 20 RPM / 200 RPD | [openrouter.ai](https://openrouter.ai) |
| **Mistral AI** | `codestral-latest` | Free tier desarrollador | [console.mistral.ai](https://console.mistral.ai) |
| **GitHub Models** | `gpt-4o` | 15 RPM / 150 RPD | [github.com/marketplace/models](https://github.com/marketplace/models) |
| **Ollama Local** | `qwen2.5-coder:7b` | **Ilimitado / 100% Offline** | [ollama.com](https://ollama.com) |

---

## 🔨 Compilación Multiplataforma

Los binarios precompilados se encuentran en `dist/`. Para recompilar desde macOS:

```bash
# macOS ARM64
zig build-exe -O ReleaseFast main.zig -femit-bin=dist/ag_bridge_darwin_arm64

# Linux x86_64
zig build-exe -O ReleaseFast -target x86_64-linux-gnu -lc main.zig -femit-bin=dist/ag_bridge_linux_x64

# Windows x86_64
zig build-exe -O ReleaseFast -target x86_64-windows -lc main.zig -femit-bin=dist/ag_bridge_windows_x64.exe
```
