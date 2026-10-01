# 📖 Manual de Uso y Distribución: Antigravity Zig MCP Bridge (Orquestador Resiliente)

---

## 📦 1. Distribución Standalone (Zero-Dependencies)

Para entregar o desplegar este puente en otra máquina (o para ti mismo), **no necesitas instalar Zig, ni Rust, ni Python, ni Node.js, ni Docker**.

Solo se requieren **2 archivos** en la misma carpeta:

```text
mi_orquestador/
├── ag_bridge               <-- Ejecutable nativo (~574 KB)
└── config.json             <-- Configuración de modelos y fallback
```

| Plataforma | Binario en `dist/` | Tamaño | Estado |
| :--- | :--- | :--- | :--- |
| **macOS (Apple Silicon M1/M2/M3/M4)** | `dist/ag_bridge_darwin_arm64` (o `ag_bridge`) | ~574 KB | ✅ Nativo sin dependencias |
| **Linux (x86_64)** | `dist/ag_bridge_linux_x64` | ~4.3 MB | ✅ Nativo glibc |
| **Windows (x86_64)** | `dist/ag_bridge_windows_x64.exe` | ~933 KB | ✅ Nativo Windows PE |

---

## ⚡ 2. Guía de Puesta en Marcha

### Paso 1: Ollama Local (Respaldo Seguro Ininterrumpido)
1. Instalar Ollama desde [https://ollama.com](https://ollama.com).
2. Descargar los modelos recomendados para co-work y desarrollo:
   ```bash
   ollama pull qwen2.5-coder:7b      # Código y refactorización
   ollama pull deepseek-r1:8b        # Razonamiento lógico y arquitectura
   ollama pull llama3.2              # Respuestas rápidas y síntesis
   ```
3. Mantener Ollama ejecutándose (`ollama serve` o la app de escritorio).

### Paso 2: Configuración de Claves API (Nube) — Dos Enfoques Claramente Separados

Para configurar tus tokens de la nube tienes **dos caminos independientes**. Elige el que te resulte más cómodo:

---

#### 🟢 ENFOQUE 1: Modo Directo en `config.json` (El Más Simple y Rápido)
**No tocas variables de entorno ni archivos externos.** Pegas la clave alfanumérica directamente dentro de tu [config.json](file:///Users/jferreyradev/projects/ag/ag_orquestador/config.json).

* **Si tienes 1 solo token para ese modelo:**
```json
{
  "id": "groq",
  "name": "Groq Llama 3.3 70B",
  "provider": "openai",
  "endpoint": "https://api.groq.com/openai/v1/chat/completions",
  "model": "llama-3.3-70b-versatile",
  "api_key": "gsk_pega_aqui_tu_clave_real"
}
```

* **Si tienes 2 o más tokens de diferentes cuentas personales:**
```json
{
  "id": "groq",
  "name": "Groq Llama 3.3 70B (Pool Multi-Cuenta)",
  "provider": "openai",
  "endpoint": "https://api.groq.com/openai/v1/chat/completions",
  "model": "llama-3.3-70b-versatile",
  "api_keys": [
    "gsk_token_cuenta_personal_1",
    "gsk_token_cuenta_personal_2",
    "gsk_token_cuenta_personal_3"
  ]
}
```
*(En este enfoque no hay ningún alias ni nombre que hacer coincidir: el puente toma el valor literal del archivo).*

---

#### 🔵 ENFOQUE 2: Modo Variables de Entorno en Antigravity (Para no guardar claves en el repo)
Si no quieres que tus claves secretas queden escritas en `config.json`, las declaras en el archivo de Antigravity y las vinculas mediante **nombres de variable (alias)**.

Aquí es donde **los nombres deben coincidir con exactitud**:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ ARCHIVO 1: ~/.gemini/config/mcp_config.json (Configuración de Antigravity)│
│                                                                        │
│ "env": {                                                               │
│     "MI_TOKEN_GROQ_1": "gsk_cuenta1_abc123...", ──┐                    │
│     "MI_TOKEN_GROQ_2": "gsk_cuenta2_xyz789..."  ──┼───────┐            │
│ }                                                 │       │            │
└───────────────────────────────────────────────────┼───────┼────────────┘
                                                    │       │
                                     ¡DEBEN COINCIDIR EXACTAMENTE!
                                                    │       │
┌───────────────────────────────────────────────────┼───────┼────────────┐
│ ARCHIVO 2: config.json (Configuración de tu Orquestador)  │            │
│                                                   │       │            │
│ {                                                 │       │            │
│   "id": "groq-cuenta-1",                          │       │            │
│   "api_key_env": "MI_TOKEN_GROQ_1" <──────────────┘       │            │
│ },                                                        │            │
│ {                                                         │            │
│   "id": "groq-cuenta-2",                                  │            │
│   "api_key_env": "MI_TOKEN_GROQ_2" <──────────────────────┘            │
│ }                                                                      │
└────────────────────────────────────────────────────────────────────────┘
```

> **Regla de Correspondencia:**  
> Lo que pongas a la izquierda en `"env"` (el nombre que tú inventes para esa variable) debe ser **exactamente el mismo texto** que coloques dentro del campo `"api_key_env"` en `config.json`.

* **Alternativa con Pool por Variable:** También puedes poner varios tokens separados por coma bajo una misma variable:
  * En `mcp_config.json`: `"GROQ_API_KEY": "gsk_cuenta1...,gsk_cuenta2..."`
  * En `config.json`: `"api_key_env": "GROQ_API_KEY"` (el puente separa automáticamente por comas).

---

### 🔑 2.1. ¿Puedo incluir CUALQUIER modelo del cual tenga token?
**Sí, absolutamente cualquiera.**  
El puente es compatible con cualquier proveedor que siga el estándar HTTP/JSON OpenAI-compatible (`/chat/completions` o `/generate`):
* **Comerciales / Cloud:** OpenAI (GPT-4o, o1, o3-mini), Anthropic Claude (vía OpenRouter), Groq, Cerebras, Google Gemini, Mistral AI, DeepSeek API oficial, Together AI, Perplexity, etc.
* **Locales / Self-hosted:** Ollama, vLLM, LM Studio, llama.cpp, LocalAI.

Solo necesitas registrarlo con:
```json
{
  "id": "mi-modelo-favorito",
  "name": "Nombre Descriptivo",
  "provider": "openai",
  "endpoint": "https://api.proveedor.com/v1/chat/completions",
  "model": "nombre-exacto-del-modelo",
  "api_key": "tu_token_aqui"
}
```

---

### 🔀 2.2. ¿Qué pasa si tengo 2 o 3 tokens de un mismo modelo? (Multi-Token Pool)
¡El puente tiene **soporte nativo para pools de tokens**! Si tienes 2 o 3 tokens (por ejemplo, varias cuentas gratuitas para multiplicar tus límites de velocidad o cuotas por minuto), el puente las rota automáticamente:

#### Forma 1: Array `api_keys` en `config.json` (Recomendada)
```json
{
  "id": "groq",
  "name": "Groq Llama 3.3 70B (Pool x3)",
  "provider": "openai",
  "endpoint": "https://api.groq.com/openai/v1/chat/completions",
  "model": "llama-3.3-70b-versatile",
  "api_keys": [
    "gsk_token_cuenta_1...",
    "gsk_token_cuenta_2...",
    "gsk_token_cuenta_3..."
  ]
}
```

#### Forma 2: Tokens separados por coma en variable de entorno
En tu variable `GROQ_API_KEY`:
```bash
GROQ_API_KEY="gsk_token_1,gsk_token_2,gsk_token_3"
```

#### ¿Cómo actúa el puente en tiempo de ejecución?
1. Envía la petición con el **Token #1**.
2. Si el proveedor responde con **HTTP 429 (Límite de peticiones/tokens alcanzado)** o **HTTP 401**, el puente **conmuta en milisegundos al Token #2**, y luego al **Token #3**.
3. Solo si se agotan todos los tokens del pool de ese modelo, salta al siguiente modelo de la cadena de fallback (`fallback_chain`).
4. **Resultado:** ¡Tu cuota efectiva se multiplica por 3 de forma transparente y sin interrumpir tu trabajo!

---

### 🏷️ 2.3. Anatomía de un Modelo: ¿El `id` es el token?

**No, el `id` NO es el token.**  
El `id` es únicamente el **apodo corto** que usas en el chat o en la lista de fallback para referirte a él, evitando escribir nombres técnicos largos o tokens secretos.

```json
{
  "id": "groq",                                             // 1. APODO CORTO (ej: 'groq', 'cerebras', 'mi-llama')
  "name": "Groq Llama 3.3 70B",                             // 2. NOMBRE VISUAL (Para los reportes de telemetría)
  "provider": "openai",                                     // 3. PROTOCOLO ("openai" o "ollama")
  "endpoint": "https://api.groq.com/openai/v1/chat/completions", // 4. URL DE LA API
  "model": "llama-3.3-70b-versatile",                       // 5. NOMBRE TÉCNICO EXACTO que pide el proveedor
  "api_key": "gsk_clave_secreta_real...",                   // 6. TOKEN SECRETO DIRECTO (o arreglo api_keys)
  "api_key_env": "GROQ_API_KEY"                             // 7. VARIABLE DE ENTORNO (Alternativa al api_key)
}
```

| Campo | ¿Qué es? | Ejemplo |
| :--- | :--- | :--- |
| `id` | **Apodo corto** para invocarlo en prompts o en `fallback_chain`. | `"groq"`, `"gemini"`, `"qwen-local"` |
| `name` | Etiqueta humana para los mensajes de respuesta. | `"Google Gemini 2.5 Flash"` |
| `provider` | Tipo de protocolo de comunicación. | `"openai"` o `"ollama"` |
| `endpoint` | Dirección web HTTP a la que se envían las peticiones. | `"https://api.groq.com/openai/v1/chat/completions"` |
| `model` | Identificador técnico del modelo según el proveedor. | `"llama-3.3-70b-versatile"`, `"gemini-2.5-flash"` |
| `api_key` / `api_keys` | **Tu token o tokens reales** de acceso. | `"gsk_..."` o `["gsk_1...", "gsk_2..."]` |
| `api_key_env` | Nombre de la variable del sistema donde guardas la clave. | `"GROQ_API_KEY"` |

---

## 🔄 3. Conmutación Automática y Resiliencia (Auto-Fallback)

### ¿Cómo funciona la conmutación entre modelos?
Cuando ejecutas tareas desatendidas o en lote usando la herramienta `ask_resilient`:

1. El orquestador intenta primero el modelo en la nube más rápido (ej: `groq`).
2. Si Groq responde con **HTTP 429 (Rate Limit / Límite de Cuota superado)** o falla temporalmente:
   - El puente conmuta automáticamente en microsegundos a `cerebras`.
   - Si Cerebras también se agota, pasa a `gemini`.
   - Si los proveedores en la nube se saturan, **conmuta a Ollama local (`qwen-local`)**.
3. **Garantía:** Al terminar la cadena en Ollama local, tus peticiones **nunca fallan** ni se abortan a mitad de la noche o en tareas largas, porque el modelo local no tiene límites de tokens por minuto ni cuotas.

La cadena por defecto configurada en `config.json` es:
```json
"fallback_chain": [
  "groq",
  "cerebras",
  "gemini",
  "codestral",
  "qwen-local"
]
```

### 3.1. ¿Cómo definir y cambiar el orden de prioridad global?
El orden en que escribes los IDs dentro de `"fallback_chain"` es **exactamente el orden de prioridad** de ejecución:
1. `1°`: Primer elemento (`groq`).
2. `2°`: Segundo elemento si el primero falla o llega al límite (`cerebras`).
3. `3°`: Tercer elemento (`gemini`), y así sucesivamente.

**Para cambiar la prioridad:** Simplemente reordena los elementos en [config.json](file:///Users/jferreyradev/projects/ag/ag_orquestador/config.json). No necesitas reiniciar Antigravity ni recompilar nada; el cambio toma efecto de inmediato.

### 3.2. Cambiar la prioridad "al vuelo" en el chat (`initial_model`)
Si para una tarea puntual quieres que comience con otro modelo (por ejemplo `gemini` o `cerebras`), pero manteniendo la red de seguridad del fallback si este falla:
> *"Usa ask_resilient **empezando con gemini** para resolver este problema..."*

El puente colocará a `gemini` en la posición #1 de la cola, y si este se satura o da HTTP 429, continuará con los demás modelos configurados en `fallback_chain`.

### 3.3. Forzar un modelo específico (sin conmutación / sin fallback)
Si quieres que una consulta se haga estrictamente con un modelo sin que salte a ningún otro:
* **Para cualquier modelo del catálogo:** Usa `ask_model`:
  > *"Pregúntale a **cerebras**..."* o *"Consulta a **codestral**..."*
* **Para Ollama local:** Usa `ask_ollama`:
  > *"Usa ask_ollama con **deepseek-r1:8b** para..."*

### 3.4. Prioridad entre tokens de un mismo modelo (Multi-Token)
Si configuraste un array `"api_keys": ["token_1", "token_2"]`, la prioridad es estrictamente de izquierda a derecha:
1. Primero se usa el `token_1`.
2. Si devuelve `HTTP 429` (Rate Limit) o `HTTP 401`, pasa de inmediato al `token_2`.
3. Solo si todos los tokens del modelo fallan, se avanza al siguiente modelo de la `fallback_chain`.

---

## 📊 4. Medición de Consumo y Límites (Telemetría de Tokens)

El puente ofrece doble capa de control de consumo:

1. **Pie de Telemetría en Cada Respuesta:**
   Cada llamada devuelve al final un desglose exacto:
   ```text
   ---
   📊 Telemetría: Cerebras Llama 3.3 70B | Tokens: 842 (Entrada: 124, Salida: 718)
   🔄 Fallback activado: groq (HTTP 429) ➔ cerebras
   ```
2. **Herramienta `get_stats` (Consumo Acumulado de la Sesión):**
   Puedes invocarla en cualquier momento preguntando en Antigravity:
   > *"¿Cuánto consumo de tokens llevamos en esta sesión?"*
   
   Y devolverá:
   - Total de peticiones procesadas.
   - Total de conmutaciones (fallbacks) ejecutadas.
   - Tokens de entrada acumulados.
   - Tokens de generación acumulados.
   - Total global de tokens.

---

## 💬 5. Catálogo de Herramientas y Ejemplos de Prompt

| Herramienta | Cuándo usarla | Ejemplo de Prompt |
| :--- | :--- | :--- |
| `ask_resilient` | **Peticiones largas, batch o desatendidas** que deben terminar sí o sí sin fallar por cuotas. | *"Usa ask_resilient para refactorizar este módulo completo y generar sus tests unitarios."* |
| `ask_model` | Cuando quieres forzar una consulta a un modelo específico por su ID (`groq`, `cerebras`, `gemini`, `deepseek-local`, etc.). | *"Pídele a cerebras que revise la complejidad algorítmica de esta función."* |
| `ask_ollama` | Para usar directamente un modelo local sin consultar la nube. | *"Pregúntale a qwen2.5-coder:7b en Ollama cómo tipar este struct en Zig."* |
| `get_stats` | Para auditar el gasto de tokens y conmutaciones realizadas. | *"Muestra las estadísticas de consumo y tokens de la sesión."* |
| `list_models` | Para inspeccionar el catálogo activo y el orden de la cadena de fallback. | *"¿Qué modelos y qué cadena de fallback tengo configurados?"* |
| `add_model` | Para registrar un nuevo modelo en caliente sin tocar archivos. | *"Agrega a config.json el modelo local 'phi4' con id 'phi-local'."* |

---

## 🛠️ 6. Compilación Multiplataforma

Si realizas modificaciones al código fuente en `main.zig`:

```bash
# Compilar binario nativo macOS ARM64
zig build-exe -O ReleaseFast main.zig -femit-bin=dist/ag_bridge_darwin_arm64

# Compilar para Linux x64
zig build-exe -O ReleaseFast -target x86_64-linux-gnu -lc main.zig -femit-bin=dist/ag_bridge_linux_x64

# Compilar para Windows x64
zig build-exe -O ReleaseFast -target x86_64-windows -lc main.zig -femit-bin=dist/ag_bridge_windows_x64.exe
```

---

## 💎 7. Los Mejores y Más Generosos Modelos Gratuitos (Free Tiers) para Programar

Para exprimir al máximo tu puente sin gastar un centavo, estos son los proveedores con las cuotas gratuitas más generosas y los mejores modelos de ingeniería de software del mercado:

### 1. Google AI Studio (Gemini 2.5 Flash) — 🏆 El Rey de la Cuota Gratuita
* **¿Por qué es el mejor?** 1 Millón de tokens de ventana de contexto (puedes pegarle repositorios enteros) y una de las cuotas gratuitas más gigantescas del mundo.
* **Límites Free:** 15 RPM (peticiones/minuto), 1,000,000 TPM (tokens/minuto), 1,500 RPD (peticiones/día).
* **Endpoint:** `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`
* **Modelo API:** `gemini-2.5-flash` o `gemini-1.5-pro`
* **Dónde obtener la clave:** [aistudio.google.com](https://aistudio.google.com) (Gratis con cuenta Google).

### 2. Groq Cloud (Llama 3.3 70B Versatile) — ⚡ El Más Veloz y Equilibrado
* **¿Por qué?** Velocidad de inferencia brutal (~350 tokens/segundo) con Llama 3.3 70B, uno de los mejores modelos de código abierto para arquitectura y depuración.
* **Límites Free:** 30 RPM, 6,000 a 8,000 TPM, 14,400 RPD.
* **Endpoint:** `https://api.groq.com/openai/v1/chat/completions`
* **Modelo API:** `llama-3.3-70b-versatile`
* **Dónde obtener la clave:** [console.groq.com](https://console.groq.com) (Ingreso inmediato con GitHub o Google).

### 3. Cerebras Cloud (Llama 3.3 70B) — 🏎️ La Máxima Velocidad del Mundo
* **¿Por qué?** Funciona sobre sus procesadores gigantes wafer-scale a **~1,800 tokens/segundo** (casi instantáneo).
* **Límites Free:** 30 RPM, 60,000 TPM, 14,400 RPD.
* **Endpoint:** `https://api.cerebras.ai/v1/chat/completions`
* **Modelo API:** `llama-3.3-70b`
* **Dónde obtener la clave:** [cloud.cerebras.ai](https://cloud.cerebras.ai).

### 4. OpenRouter (Catálogo Freemium `:free`) — 🌐 Acceso a Modelos Especializados
* **¿Por qué?** Ofrece acceso gratuito a modelos de élite como `Qwen 2.5 Coder 32B` (posiblemente el mejor modelo abierto de código puro del mundo).
* **Límites Free:** 20 RPM, 200 RPD.
* **Endpoint:** `https://openrouter.ai/api/v1/chat/completions`
* **Modelos Free Clave:**
  * `qwen/qwen-2.5-coder-32b-instruct:free` (Especialista Código)
  * `meta-llama/llama-3.3-70b-instruct:free`
  * `deepseek/deepseek-r1:free` (Razonamiento profundo)
* **Dónde obtener la clave:** [openrouter.ai](https://openrouter.ai).

### 5. Mistral AI / Codestral — 🎯 Especialista Puro en 80+ Lenguajes
* **¿Por qué?** Diseñado específicamente para autocompletado, refactorización y generación de código de alta precisión (Python, Zig, Rust, C++, TS, etc.).
* **Endpoint:** `https://api.mistral.ai/v1/chat/completions`
* **Modelo API:** `codestral-latest` o `mistral-small-latest`
* **Dónde obtener la clave:** [console.mistral.ai](https://console.mistral.ai) (Free tier para desarrolladores).

### 6. GitHub Models (Marketplace) — 🐙 Tu Cuenta de GitHub es tu Token
* **¿Por qué?** Con tu propio GitHub Personal Access Token (PAT) tienes acceso gratuito a GPT-4o y GPT-4o-mini sin poner tarjeta.
* **Límites Free:** 15 RPM, 150 RPD por modelo.
* **Endpoint:** `https://models.inference.ai.azure.com/chat/completions`
* **Modelos API:** `gpt-4o`, `gpt-4o-mini`
* **Dónde obtener la clave:** [github.com/marketplace/models](https://github.com/marketplace/models).

### 7. Ollama Local — 🛡️ El Respaldo Infinito (0 Costo, 0 Límites)
* **Modelos recomendados:**
  * `qwen2.5-coder:7b`: El mejor modelo local para refactorizar y escribir código en tu máquina.
  * `deepseek-r1:8b`: Pensamiento paso a paso para bugs difíciles y arquitectura.
  * `llama3.2`: Asistente ágil y liviano para explicaciones.

