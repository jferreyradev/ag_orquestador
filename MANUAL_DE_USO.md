# 📖 Manual Mínimo de Uso y Distribución: Antigravity Zig Bridge

---

## 📦 1. ¿Qué se distribuye al usuario final?

Para entregar este puente a otra persona (alumno, compañero o cliente), **no necesitas pedirle que instale Zig, ni Rust, ni Python, ni Node.js**.

Solo debes entregarle una carpeta con **2 archivos**:

```text
mi_orquestador/
├── ag_bridge (o ag_bridge_windows_x64.exe en Windows)
└── config.json
```

| Plataforma | Binario a entregar (desde la carpeta `dist/`) | Tamaño |
| :--- | :--- | :--- |
| **macOS (Apple Silicon M1/M2/M3/M4)** | `dist/ag_bridge_darwin_arm64` | ~539 KB |
| **Linux (x86_64)** | `dist/ag_bridge_linux_x64` | ~4.1 MB |
| **Windows (x86_64)** | `dist/ag_bridge_windows_x64.exe` | ~900 KB |

---

## ⚡ 2. Guía de Instalación Rápida para el Usuario

### Paso 1: Levantar Ollama Local
1. Instalar Ollama: [https://ollama.com](https://ollama.com) o `brew install ollama` (macOS).
2. Descargar al menos un modelo en terminal:
   ```bash
   ollama pull llama3.2
   ```
3. Dejar la aplicación abierta (o ejecutando `ollama serve`).

### Paso 2: Registrar el Puente en Antigravity
En el archivo de configuración global de Antigravity:
* **macOS / Linux:** `~/.gemini/config/mcp_config.json`
* **Windows:** `%USERPROFILE%\.gemini\config\mcp_config.json`

```json
{
  "mcpServers": {
    "orquestador": {
      "command": "/Ruta/Absoluta/Al/ag_bridge",
      "args": [],
      "env": {
        "GROQ_API_KEY": "gsk_...",
        "GEMINI_API_KEY": "AIzaSy...",
        "CEREBRAS_API_KEY": "csk-..."
      }
    }
  }
}
```
*(En Windows la ruta será algo como `"C:\\Users\\tu_usuario\\ag_bridge_windows_x64.exe"`)*.

---

## 💬 3. Prompts de Uso en el Chat de Antigravity

Una vez iniciada una conversación en Antigravity:

* **Para usar Ollama local:**
  > *"Usa Ollama local con llama3.2 para analizar la arquitectura de este proyecto."*
* **Para usar otro modelo local (ej. razonamiento o código):**
  > *"Usa Ollama local con deepseek-r1:8b para encontrar posibles condiciones de carrera en este código."*
* **Para usar modelos en la nube:**
  > *"Consulta a groq para una segunda opinión rápida sobre este algoritmo."*
* **Para ver los modelos configurados:**
  > *"¿Cuáles son los modelos disponibles en mi puente?"* *(Llama a `list_models`)*
* **Para agregar un nuevo modelo sin tocar archivos:**
  > *"Agrega el modelo mistral-nemo de Ollama a mi configuración con el id 'mistral'."* *(Llama a `add_model`)*

---

## 🛠️ 4. Cómo compilar para todas las plataformas desde tu Mac

Desde tu Mac, puedes compilar los ejecutables nativos de todos los sistemas operativos sin necesidad de instalar máquinas virtuales ni entornos cruzados:

```bash
# 1. macOS (Apple Silicon ARM64)
zig build-exe -O ReleaseFast main.zig -femit-bin=dist/ag_bridge_darwin_arm64

# 2. Linux (x86_64)
zig build-exe -O ReleaseFast -target x86_64-linux-gnu -lc main.zig -femit-bin=dist/ag_bridge_linux_x64

# 3. Windows (x86_64 .exe)
zig build-exe -O ReleaseFast -target x86_64-windows -lc main.zig -femit-bin=dist/ag_bridge_windows_x64.exe
```
