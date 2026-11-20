# Recorder JT — Plan de implementación

Objetivo: grabar cualquier sesión que suene en el Mac (Teams, Zoom, Meet, videos, llamadas), **transcribirla en local con el whisper.cpp que ya existe** y **resumirla con Claude**, de forma fiable: si algo se cae a mitad de camino, no se pierde la grabación y el proceso se retoma solo.

---

## 1. Lo que ya tenemos (verificado en esta máquina)

| Recurso | Estado | Uso en el proyecto |
|---|---|---|
| whisper.cpp compilado con **Metal** | `~/Documents/DEV/tools/whisper.cpp/build/bin/whisper-cli` (commit `95ea8f9`, mar-2026) | Motor de transcripción. No se reinstala nada. |
| Modelo | `models/ggml-large-v3.bin` | Modelo por defecto |
| Binarios extra | `whisper-server`, `whisper-bench`, `whisper-vad-speech-segments` | Benchmark y VAD |
| VAD Silero | sólo `for-tests-silero-v6.2.0-ggml.bin` (el de pruebas) | Hay que bajar el modelo VAD real (`models/download-vad-model.sh silero-v6.2.0`, unos 2 MB) |
| ffmpeg | Homebrew (`ffmpeg-full`) | Conversión a 16 kHz mono |
| Python 3 + `anthropic` 0.46 | Global | Se usará un **venv propio** con el SDK actualizado (0.46 no soporta salida estructurada con `output_config`) |
| Swift 6.1 (Command Line Tools) | Sin Xcode completo | Basta: la app se compila con **Swift Package Manager** y se empaqueta como `.app` con un script |
| Hardware | M1 Max, 32 GB, macOS 15.4.1 | Core Audio Process Taps disponibles (requieren 14.2+) |

> También hay un `whisper-cli` 1.8.4 de Homebrew en el PATH. El worker usa **siempre la ruta absoluta del build local**, configurable, para no mezclar versiones.

---

## 2. Arquitectura

Son dos procesos independientes que se comunican por **carpetas y un manifest**. Si uno falla, el otro no se entera ni pierde datos.

```
┌──────────────────────────── RecorderJT.app (Swift, menu bar) ───────────────────────────┐
│  Mic (AVAudioEngine) ──► mic.caf                                                         │
│  Audio sistema (Core Audio Process Tap + aggregate device) ──► system.caf                │
│  manifest.json  (status: recording → recorded)                                           │
└──────────────────────────────────────────┬──────────────────────────────────────────────┘
                                           │  ~/RecorderJT/sessions/2026-11-17_1003_<id>/
                                           ▼
┌──────────────────────────── recorder-worker (Python, LaunchAgent) ──────────────────────┐
│  Cola SQLite (jobs + estados) ─ idempotente, con reintentos                              │
│  1 validate → 2 normalize (ffmpeg) → 3 transcribe (whisper-cli ×2 pistas)                │
│  → 4 merge + dedupe de eco → 5 summarize (Claude) → 6 export (Markdown / JSON)           │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

**Por qué dos pistas:** el micrófono eres **tú** y el audio del sistema son **los demás**. Eso da una diarización básica gratis ("Yo" frente a "Participantes") sin modelos extra.

**Por qué Swift para grabar y Python para procesar:** capturar el audio del sistema sin drivers virtuales sólo se hace bien con APIs nativas. Orquestar ffmpeg, whisper y Claude es más simple, testeable y fácil de depurar en Python.

### Estructura de una sesión en disco

```
~/RecorderJT/sessions/2026-11-17_1003_a1b2/
├── manifest.json        # metadatos + estado (fuente de verdad del grabador)
├── mic.caf              # 48 kHz, tal cual llega
├── system.caf
├── work/
│   ├── mic.16k.wav
│   ├── system.16k.wav
│   ├── mic.json         # salida cruda de whisper (segmentos + timestamps)
│   └── system.json
├── transcript.json      # transcripción unificada (segmentos con speaker, start, end, text)
├── transcript.md
├── summary.json         # salida estructurada de Claude
└── summary.md           # resumen legible (lo que se lee/comparte)
```

`manifest.json` (mínimo):

```json
{
  "id": "a1b2",
  "title": "Sync semanal",
  "started_at": "2026-11-17T10:03:12-06:00",
  "ended_at": "2026-11-17T10:48:40-06:00",
  "status": "recorded",
  "tracks": {
    "mic":    {"file": "mic.caf",    "device": "MacBook Pro Microphone", "first_host_time": 123456789, "sample_rate": 48000},
    "system": {"file": "system.caf", "source": "global-tap",             "first_host_time": 123456901, "sample_rate": 48000}
  },
  "source_apps": ["zoom.us"],
  "language": "es",
  "app_version": "0.1.0"
}
```

---

## 3. Componente A: grabador (Swift)

### 3.1 Captura

| Pista | API | Detalles |
|---|---|---|
| Sistema | `CATapDescription` + `AudioHardwareCreateProcessTap` → aggregate device → `AudioDeviceCreateIOProcIDWithBlock` | Tap global estéreo **excluyendo el propio proceso**. Opción futura: tap sólo de las apps de reunión (Zoom, Teams, navegador) para no grabar Spotify. |
| Micrófono | `AVAudioEngine.inputNode` con un tap | Se respeta el dispositivo de entrada por defecto del sistema |

- Se escribe en **CAF** (`AVAudioFile`) en formato nativo (float32, 48 kHz). CAF admite tamaño de datos "desconocido", así que **si la app crashea, el archivo sigue siendo legible** hasta el último buffer.
- Las dos escrituras van en una cola serial por pista, nunca en el hilo de audio en tiempo real. Se usa un ring buffer y se copia a disco desde un hilo aparte.
- Se guarda `mach_absolute_time` del primer buffer de cada pista para alinear las pistas después. La deriva de reloj entre dispositivos es de cientos de ms por hora, aceptable para intercalar segmentos.

### 3.2 Robustez del grabador

| Situación | Manejo |
|---|---|
| Cambio de dispositivo (AirPods se conectan o desconectan) | Observar `AVAudioEngineConfigurationChange` y los listeners de Core Audio (`kAudioHardwarePropertyDefaultInputDevice/OutputDevice`), reconstruir el engine o el tap **sin cerrar el archivo** y registrar un evento en el manifest |
| Mac se duerme | `NSWorkspace.willSleepNotification`: pausar y hacer flush. `didWake`: reanudar la captura |
| Disco casi lleno | Revisar el espacio libre cada 60 s y avisar por debajo de 2 GB (1 h ≈ 1,3 GB en CAF float estéreo; opcionalmente comprimir a ALAC en vivo) |
| Crash de la app | Al arrancar, buscar sesiones en `status: recording` y marcarlas `recorded` con `"recovered": true`. El worker las procesa igual |
| Silencio total en una pista (permiso denegado o dispositivo mudo) | Medidor RMS: si una pista está 2 min en −90 dB con la otra activa, avisar en el menú |
| Permisos | `NSMicrophoneUsageDescription` y `NSAudioCaptureUsageDescription` en el Info.plist. Pantalla de onboarding que los pide y verifica |

### 3.3 UX mínima (menu bar)

- Icono con estado: inactivo, grabando (con contador) o procesando.
- Opciones: **Iniciar o detener grabación**, título opcional, "Abrir carpeta de sesiones" y "Ver último resumen".
- Atajo global (p. ej. ⌃⌥R).
- Aviso de consentimiento al iniciar: "Recuerda informar a los participantes que se está grabando".

### 3.4 Build sin Xcode

- `Package.swift` con un target ejecutable y SwiftUI con `MenuBarExtra`.
- `scripts/bundle_app.sh`: `swift build -c release`, arma `RecorderJT.app/Contents/{MacOS,Info.plist,Resources}` y firma la app.
- **Importante:** los permisos de macOS (TCC) se atan a la firma. Con firma ad-hoc, cada recompilación vuelve a pedir permisos. Por eso hay que crear **un certificado de firma local** ("RecorderJT Dev") en el Llavero una sola vez y firmar siempre con él (`codesign --force --options runtime --sign "RecorderJT Dev"`).

---

## 4. Componente B: worker de procesamiento (Python)

### 4.1 Cola y estados

SQLite (`~/RecorderJT/recorder.db`), con una tabla `jobs`:

```
session_id | step | status(pending|running|done|failed) | attempts | last_error | updated_at
```

- **Idempotente:** cada paso escribe su artefacto en un archivo temporal y lo renombra de forma atómica. Si el artefacto ya existe y es válido, el paso se salta.
- **Reintentos** con backoff (3 intentos). Un paso fallido no bloquea a las demás sesiones.
- Un `running` con más de N minutos sin latido se considera huérfano y se reencola. Así se cubre el caso de que el worker muera a mitad de un paso.
- Descubrimiento de sesiones: escaneo periódico (cada 15 s) de `sessions/*/manifest.json` con `status: recorded`. Es más fiable que FSEvents solo.
- Corre como **LaunchAgent** (`~/Library/LaunchAgents/com.jt.recorder-worker.plist`, `KeepAlive=true`) con logs en `~/RecorderJT/logs/`.

### 4.2 Pasos

**1. validate**: `ffprobe` a cada pista para obtener duración, canales y si hay audio. Una pista vacía o con silencio total se marca y se omite; la sesión sigue con la otra.

**2. normalize**:
```bash
ffmpeg -y -i mic.caf -ac 1 -ar 16000 -af "highpass=f=80" -c:a pcm_s16le work/mic.16k.wav
```
(lo mismo para `system`).

**3. transcribe**: whisper-cli local, una pista a la vez para no saturar la GPU:
```bash
$WHISPER_BIN -m $WHISPER_MODEL -f work/mic.16k.wav \
  -l es -t 8 \
  --vad --vad-model $VAD_MODEL \
  -mc 0 \
  --prompt "$GLOSARIO" \
  -oj -of work/mic
```
- `--vad`: salta los silencios. Así se procesa más rápido y **se evitan las alucinaciones típicas de Whisper en silencio** ("Gracias por ver el video", "Subtítulos por…").
- `-mc 0` (max-context 0): evita los bucles de repetición en grabaciones largas.
- `--prompt`: glosario con nombres de personas, productos y siglas del equipo (archivo `config/glossary.txt`). Mejora mucho la ortografía de los nombres propios.
- Timeout proporcional a la duración. Si falla o se agota, **fallback**: partir la pista en bloques de 10 min por silencios (`whisper-vad-speech-segments` o `silencedetect` de ffmpeg) y transcribir por bloques.
- Posprocesado: filtro de frases alucinadas conocidas y de segmentos repetidos más de 3 veces seguidas.
- El idioma es configurable (`es`, `en` o `auto`), porque hay reuniones que mezclan idiomas.

**4. merge**: une las dos pistas en una línea de tiempo:
- Corrige el offset con `first_host_time` del manifest.
- Etiqueta los segmentos: `mic` como "Yo" y `system` como "Participantes".
- **Deduplicación de eco:** si usas altavoces, el mic capta a los demás. Un segmento del mic que se solapa en el tiempo con uno del sistema y tiene una similitud de texto ≥ 0,8 (rapidfuzz) se descarta como eco.
- Salidas: `transcript.json` y `transcript.md`, este último con formato `[00:12:31] Yo: …`.

**5. summarize**: Claude (ver la sección 5).

**6. export**: `summary.md` en la carpeta de la sesión, más una copia en una carpeta "bandeja" configurable (p. ej. Obsidian o iCloud). Notion o Google Docs quedan como fase posterior. Al terminar, notificación macOS: "Resumen listo: Sync semanal".

### 4.3 CLI de mantenimiento

```bash
recorder status                  # cola y estado de cada sesión
recorder process <session_id>    # forzar (re)proceso
recorder retry <session_id> --from transcribe
recorder resummarize <session_id> --template comercial
recorder import ~/Downloads/llamada.m4a   # procesar audios externos (grabaciones de Teams/Zoom)
```

`import` es útil desde el día 1: permite probar todo el pipeline antes de que el grabador Swift esté listo.

---

## 5. Resumen con Claude

- **Modelo:** `claude-opus-5-5`, con `output_config.effort` explícito en `"medium"`. Para resumir alcanza y es el default de este modelo; conviene medir con 3 o 4 reuniones reales antes de cambiarlo.
- **Contexto:** 1M tokens. Una sesión de 3 h son unas 30–40 mil palabras (aprox. 50–60 mil tokens), así que **cabe entera en una sola llamada, sin map-reduce**. Sólo si una transcripción superara unos 600 mil tokens (días de audio) se resumiría por bloques y luego se combinaría.
- **Salida estructurada:** `client.messages.parse()` con un esquema Pydantic. Evita parsear texto libre:

```python
class ActionItem(BaseModel):
    tarea: str
    responsable: str | None
    fecha_limite: str | None
    timestamp: str          # "00:23:10", para ir al momento exacto

class Resumen(BaseModel):
    titulo_sugerido: str
    resumen_ejecutivo: str          # 5-8 líneas
    temas: list[Tema]               # tema + puntos clave + timestamps
    decisiones: list[str]
    action_items: list[ActionItem]
    preguntas_abiertas: list[str]
    riesgos: list[str]
```

- **Streaming** con `get_final_message()`, para no chocar con timeouts en transcripciones largas.
- **Rechazos (`refusal`):** se activa el fallback del servidor (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`) y se revisa `stop_reason` antes de leer el contenido.
- **Errores:** `RateLimitError` y 5xx se reintentan con backoff (el SDK ya hace 2 reintentos); un 400 se marca como fallido sin reintentar y se registra.
- **Plantillas de resumen** en `config/templates/` (general, comercial, 1:1, técnica). El prompt de sistema es fijo (cacheable) y la transcripción va al final.
- **Credenciales:** `ANTHROPIC_API_KEY` en el Llavero de macOS (`security find-generic-password`), nunca en archivos del repo.
- **Privacidad:** el **audio nunca sale del Mac**; sólo se envía el texto de la transcripción. Hay una opción `summarize: false` por sesión para reuniones sensibles (sólo transcripción local).

Costo orientativo: una reunión de 1 h son unos 20 mil tokens de entrada y 2–3 mil de salida, alrededor de **USD 0,10–0,15** con Opus 5.5.

---

## 6. Estructura del repo

```
Recorder_JT/
├── docs/PLAN_IMPLEMENTACION.md
├── recorder-app/                 # Swift
│   ├── Package.swift
│   ├── Sources/RecorderJT/
│   │   ├── App.swift             # MenuBarExtra
│   │   ├── SystemAudioTap.swift  # Core Audio process tap + aggregate device
│   │   ├── MicCapture.swift
│   │   ├── TrackWriter.swift     # ring buffer → CAF
│   │   ├── SessionManager.swift  # manifest, recuperación tras crash
│   │   └── DeviceMonitor.swift   # cambios de dispositivo, sleep/wake
│   ├── Resources/Info.plist
│   └── scripts/bundle_app.sh
├── worker/                       # Python
│   ├── pyproject.toml
│   ├── recorder_worker/
│   │   ├── cli.py  queue.py  config.py
│   │   ├── steps/{validate,normalize,transcribe,merge,summarize,export}.py
│   │   └── prompts/
│   └── tests/ (fixtures de audio cortos)
├── config/
│   ├── config.toml               # rutas whisper, modelo, idioma, carpetas
│   ├── glossary.txt
│   └── templates/
└── launchd/com.jt.recorder-worker.plist
```

`config.toml` (ejemplo):

```toml
[whisper]
bin   = "~/Documents/DEV/tools/whisper.cpp/build/bin/whisper-cli"
model = "~/Documents/DEV/tools/whisper.cpp/models/ggml-large-v3.bin"
vad_model = "~/Documents/DEV/tools/whisper.cpp/models/ggml-silero-v6.2.0.bin"
language = "es"
threads = 8

[claude]
model = "claude-opus-5-5"
effort = "medium"

[paths]
sessions = "~/RecorderJT/sessions"
inbox    = "~/RecorderJT/resumenes"
```

---

## 7. Fases y criterios de aceptación

### Fase 0: validación del motor (½ día)
- Bajar el modelo VAD real y ejecutar `whisper-bench` con large-v3 para medir cuántas veces más rápido que el tiempo real transcribe esta máquina.
- Transcribir 2 grabaciones reales en español (una de 5 min y una de 60 min) con y sin VAD.
- **Decisión:** si large-v3 tarda más de unos 15 min por hora de audio, evaluar `large-v3-turbo` (se descarga con el script de whisper.cpp; es mucho más rápido y la calidad en español es casi igual).
- ✅ Hecho cuando: hay tiempos y calidad medidos y el modelo está elegido.

### Fase 1: pipeline con audios importados (2–3 días)
- Worker Python completo: cola, los 6 pasos, CLI, `recorder import`.
- Resumen estructurado con Claude y `summary.md`.
- ✅ Hecho cuando: `recorder import reunion.m4a` produce la transcripción y el resumen; matar el worker a mitad del proceso y relanzarlo lo retoma sin duplicar trabajo.

### Fase 2: grabador Swift (3–4 días)
- Captura del mic y del audio del sistema en dos pistas CAF, manifest y menu bar.
- Bundle, firma estable y onboarding de permisos.
- Manejo de cambio de dispositivo, sleep/wake y recuperación tras crash.
- ✅ Hecho cuando: una reunión real de Zoom, otra de Teams y otra de Meet (en el navegador) quedan grabadas con ambas pistas audibles; desconectar los AirPods a mitad no corta la grabación; un `kill -9` deja archivos válidos.

### Fase 3: integración y robustez (2 días)
- LaunchAgent del worker y notificaciones de "resumen listo".
- Merge con deduplicación de eco y alineación por `host_time`.
- **Prueba de resistencia:** grabación de 3 h continua y 5 sesiones encoladas seguidas.
- ✅ Hecho cuando: 1 semana de uso real sin pérdida de sesiones.

### Fase 4: extras (opcional)
- Detección automática de reuniones (mic en uso con `kAudioDevicePropertyDeviceIsRunningSomewhere` y Zoom o Teams activos) con la notificación "¿Grabar?".
- Tap sólo para las apps de reunión.
- Transcripción en vivo con `whisper-server` (el modelo se mantiene cargado).
- Exportar a Notion o Google Docs y preguntar sobre el historial de reuniones ("¿qué acordamos con X el mes pasado?").
- Diarización real de los participantes remotos (pyannote).

---

## 8. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Whisper alucina en silencios o repite frases | VAD, `-mc 0`, filtro de frases conocidas y detección de repeticiones |
| Eco: tu mic capta a los demás (altavoces) | Deduplicación por solape temporal y similitud de texto; recomendar audífonos |
| Permisos de macOS que se pierden al recompilar | Certificado de firma local estable |
| Se pierde audio por un crash | CAF con tamaño desconocido, flush periódico y recuperación al arrancar |
| Cambios de dispositivo a mitad de reunión | Listeners de Core Audio y reconstrucción del tap o engine sin cerrar los archivos |
| La GPU satura otras tareas al transcribir | Una transcripción a la vez, con prioridad baja (`nice`); opción de procesar sólo cuando el Mac está conectado a la corriente |
| SDK `anthropic` 0.46 desactualizado | venv del proyecto con el SDK actual; el global no se toca |
| Legal / consentimiento | Aviso al iniciar cada grabación; las grabaciones se quedan en local |
| Nombres propios mal transcritos | Glosario por `--prompt` y corrección en el resumen (el glosario también se pasa a Claude) |

---

## 9. Pruebas

- **Unitarias:** merge, alineación, deduplicación de eco, filtro de alucinaciones y la máquina de estados de la cola.
- **Integración:** fixtures de audio cortos (30 s, ES y EN, con silencios) que pasan por todo el pipeline con Claude mockeado, más una prueba real marcada como `slow`.
- **Caos:** matar el worker en cada paso y verificar que se reanuda; borrar un artefacto intermedio y verificar que se regenera.
- **Manuales (grabador):** checklist de Zoom, Teams, Meet, AirPods, sleep, `kill -9` y disco lleno simulado.
