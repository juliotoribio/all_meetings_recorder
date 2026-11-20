# ADR-001: Rendimiento de la interfaz (redibujados y lecturas de disco)

**Estado:** Aceptado y medido
**Fecha:** 2026-11-20
**Decide:** Julio Toribio

## Contexto

Con el rediseño (Inicio + Grabaciones) se nota un pequeño retraso en la app. Al revisar el código encontramos tres causas:

1. **`TranscriptView` observaba el `AudioPlayer`**, que publica `time` 10 veces por segundo durante la reproducción. Toda la vista (cabecera, tarjeta de audio y todas las líneas) se redibujaba 10 veces por segundo.
2. **Cada redibujado leía `transcript.txt` del disco y lo procesaba** (`transcriptBody` → `transcriptLines`). Una reunión de 1 hora tiene cientos de líneas, y se leían y parseaban 10 veces por segundo, más una vez por cada fila.
3. **`refresh()` cada 3 s** (mientras se graba o se transcribe) volvía a leer todos los `manifest.json` y `playback.json`. Además publicaba `sessions` aunque no hubiera cambios, y eso redibujaba la ventana entera.

Hay dos restricciones: SwiftUI en macOS 14.4+, y todo local, sin dependencias nuevas. Cualquier cambio debe ser pequeño y fácil de revertir.

## Decisión

Opción A, ya aplicada:

- **Caché de la transcripción en `AppModel`**, indexada por la fecha de modificación del archivo. Solo se vuelve a leer cuando el worker la reescribe.
- **Caché de `playback.json`** en `SessionStore`, también por fecha de modificación (forma de onda y duración).
- **`refresh()` solo publica si la lista cambió.** `SessionInfo` ya es `Equatable`.
- **La transcripción se separa en `TranscriptList`**, el único que observa el reproductor, **y `TranscriptRow` es `Equatable`**. Al reproducir, solo se redibujan las dos filas que cambian de resaltado, no todas. Las filas van en un `LazyVStack`.

### Segunda ronda, tras medir

Al medir (ver *Mediciones*) aparecieron otras tres causas:

- **`MainView` creaba el reproductor con `@StateObject`**, así que toda la ventana se suscribía a él y la barra lateral también se redibujaba 10 veces por segundo. Ahora es `@State`: guarda la referencia sin suscribirse.
- **La hora de cada línea («00:12:31») se convertía a segundos en cada tic**, para la línea actual y para los colores de la onda. Ahora se calcula una vez al leer (`TranscriptLine.start`) y la línea actual se busca con búsqueda binaria.
- **La onda eran 140 vistas.** Ahora es un único `Canvas`, con los colores por voz en un solo recorrido.

También se aplicó en parte la opción C: el reproductor publica **4 veces por segundo en vez de 10**. Con A ya hecha, no es un parche. En 1 h de audio el cursor avanza menos de 1 px por segundo y el reloj muestra segundos enteros, así que no se nota.

## Mediciones

Reunión real de 51 min (190 turnos), vista de Grabaciones, MacBook Pro M1 Max, media de 15 s con `ps`:

| Paso | CPU reproduciendo |
|---|---|
| Antes de la segunda ronda (cachés y filas `Equatable` ya aplicadas) | 24,5 % (pico 36 %) |
| + reproductor sin suscribir la ventana | 18,0 % |
| + segundos precalculados, búsqueda binaria, `Canvas`, `FlowLayout` sin alineaciones | 10–12 % |
| + reproductor a 4 Hz | **4–5 %** (pico 8 %) |
| En reposo, misma vista | 0 % |

No se midió la versión anterior a la primera ronda, que releía el archivo en cada redibujado. Sería peor que el 24,5 %.

## Opciones consideradas

### Opción A: cachés por fecha de modificación + vistas `Equatable` (elegida)

| Dimensión | Valoración |
|---|---|
| Complejidad | Baja: unas 120 líneas y sin cambios de arquitectura |
| Coste | Nulo |
| Escalabilidad | Buena hasta miles de líneas; la caché crece con las sesiones abiertas |
| Familiaridad | Patrón estándar de SwiftUI |

**A favor:** quita la causa principal (disco + parseo a 10 Hz) sin tocar el flujo de datos. Es reversible.
**En contra:** sigue habiendo un `stat` del archivo en cada redibujado, que es barato. La caché no se libera.

### Opción B: un `TranscriptStore` observable por sesión

El modelo carga la transcripción una vez y publica `lines`. Un vigilante de archivos (`DispatchSource`) la recarga cuando el worker escribe.

| Dimensión | Valoración |
|---|---|
| Complejidad | Media: hay que gestionar el ciclo de vida de los vigilantes |
| Coste | Nulo |
| Escalabilidad | La mejor: ninguna lectura de disco desde las vistas |
| Familiaridad | Media |

**A favor:** las vistas no tocan el disco nunca. Se actualiza en cuanto cambia el archivo, sin esperar al sondeo.
**En contra:** más código y más estado. Hay que manejar bien los vigilantes al borrar o mover sesiones.

### Opción C: reproductor a menor frecuencia (2–4 Hz)

| Dimensión | Valoración |
|---|---|
| Complejidad | Muy baja |
| Coste | Nulo |
| Escalabilidad | No arregla la causa |
| Familiaridad | Alta |

**A favor:** es un cambio de una línea.
**En contra:** como única solución, el problema de fondo sigue ahí. Se aplicó después de A (a 4 Hz), cuando ya solo quedaba el coste de redibujar la tarjeta de audio.

## Análisis de compromisos

La causa principal era **trabajo de disco dentro del `body` de las vistas, multiplicado por la frecuencia del reproductor**. A la elimina con el menor cambio posible y deja la puerta abierta a B. B es más limpio, pero añade estado y ciclo de vida para un beneficio que hoy no hace falta. C solo esconde el síntoma.

## Consecuencias

- **Más fácil:** reproducir y buscar en transcripciones largas sin tirones. La búsqueda del historial ya no relee los archivos en cada tecla.
- **Más difícil:** hay que acordarse de que `transcriptLines` depende de la fecha de modificación. Un cambio de texto que no reescriba el archivo no se vería, aunque hoy no existe ese caso.
- **Por revisar:**
  - `refresh()` todavía lee todos los manifiestos cada 3 s mientras hay trabajo. Con cientos de sesiones convendría la opción B o leer solo las que cambian.

## Tareas

1. [x] Caché de transcripción y de `playback.json` por fecha de modificación.
2. [x] `refresh()` solo si cambia.
3. [x] `TranscriptList` + `TranscriptRow` `Equatable` en `LazyVStack`.
4. [x] Medir reproduciendo una reunión real de 51 min (`RJT_TEST_PLAY`, solo con `RJT_HOME`): de 24,5 % a 4–5 % de CPU.
5. [x] Onda con `Canvas` y colores precalculados; `whisperCovered()` con caché por fecha de modificación.
6. [x] Reproductor sin suscribir la ventana; segundos precalculados; reproductor a 4 Hz.
7. [ ] Si la lista supera unos cientos de sesiones, pasar a la opción B (vigilar archivos en vez de sondear).
