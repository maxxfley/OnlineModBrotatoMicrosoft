# Análisis del co-op local (Brotato 1.1.15.4, port Microsoft Store)

Descripción del funcionamiento en palabras propias, con referencias a `res://`
(archivos extraídos en `decompiled/boot`). Sin código original copiado.

## 1. Jugadores y dispositivos — `singletons/coop_service.gd` (autoload `CoopService`)

- Máximo 4 jugadores (`get_max_players()`; 2 en Switch).
- Estado central: `connected_players`, un array donde cada elemento es
  `[device_id_remapeado, PlayerType]`. **El índice en el array es el `player_index`**
  que usa todo el juego (0..3).
- `PlayerType`: `KEYBOARD_AND_MOUSE`, `GAMEPAD_XBOX`, `GAMEPAD_PLAYSTATION`, `GAMEPAD_SWITCH`.
- IDs de dispositivo "remapeados":
  - 0..5: joypads reales (salvo el 0).
  - `6` = `GAMEPAD_REMAPPED_DEVICE_ID`: el joypad 0 (que Godot comparte con el teclado).
  - `7` = `KEYBOARD_REMAPPED_DEVICE_ID`: el teclado.
  - `8..11` = **dispositivos de debug** (`FIRST_DEBUG_DEVICE_ID`, `DEBUG_DEVICE_COUNT`):
    varios jugadores con teclado, activables con `DebugService.coop_multiple_keyboard_inputs`.
    **Demuestra que el juego ya soporta jugadores con dispositivos "virtuales".**
- Alta de jugador: mientras `listening_for_inputs` está activo (pantalla de selección de
  personaje y `coop_resume`), mantener `ui_accept_<device>` durante 0.7 s llama a
  `_add_player(device, tipo)` → push en `connected_players` + señal
  `connected_players_updated`.
- Baja: `_remove_player(device)` o desconexión del joypad (`joy_connection_changed`).
- Escalado co-op: `additional_enemies/health/damage_per_coop_player` y factor de
  materiales (`get_coop_materials_factor`).
- Íconos de botones por tipo de mando; `get_player_key_texture` llama a `OS_Seaven`.

## 2. Input por dispositivo — `singletons/input_service.gd` (autoload `InputService`)

- `_copy_device_actions()` duplica **cada acción del InputMap** por dispositivo con sufijo:
  `move_left` → `move_left_0` … `move_left_7` (rango `0..REMAP_END-1`, con REMAP_END = 8).
  Para teclado/joypad crea el evento con el `device` real correspondiente.
- Con `coop_multiple_keyboard_inputs` crea además acciones `_8.._11` mapeadas a teclas
  (WASD, TFGH, IJKL, flechas).
- Se reconstruye al cambiar la opción "movimiento con gamepad" (`InputMap.load_from_globals()`
  + copia), así que **acciones agregadas a mano se pierden** si se llama de nuevo → el mod
  debe re-crear las suyas después (hook en `_copy_device_actions`).
- Eco de d-pad/joystick para navegar menús: emite `InputEventAction` (`ui_up_<dev>`, etc.)
  con `Input.parse_input_event` (`_emulate_action`). Solo recorre devices `0..7`.

### Dónde se consume el input
| Qué | Dónde | Cómo |
|---|---|---|
| Movimiento | `entities/units/movement_behaviors/player_movement_behavior.gd` | `Input.get_vector("analog_move_*_<dev>")` y `"button_move_*_<dev>"`; gana el de mayor magnitud |
| Apuntado manual (gamepad) | `singletons/utils.gd` `get_player_rjoy_vector` / `is_manual_aim`; `weapons/weapon.gd` `_physics_process` | `Input.get_vector("rjoy_*_<dev>")`. En co-op el mouse no apunta |
| Menús por jugador | `ui/menus/global/focus_emulator.gd` (uno por jugador, `player_index` → `_device`) | En `_input(event)`: `event.is_action_pressed("ui_accept_<dev>")`, `ui_up/down/left/right_<dev>`, etc. |
| Alta de jugadores | `CoopService._input/_process` | `is_action_pressed("ui_accept_<dev>")` + `Input.is_action_pressed` |

**Consecuencia para el online:** todo el input pasa por acciones con sufijo de dispositivo.
- Ejes (movimiento/apuntado) → `Input.action_press(accion, fuerza)` / `action_release`
  alcanza, porque se leen por polling (`get_vector`).
- Menús → hace falta **generar eventos** (`Input.parse_input_event(InputEventAction)`),
  porque se leen en `_input`.

## 3. Flujo de escenas

```
title_screen → (main_menu: elegir co-op) → character_selection
  [CoopService.listening_for_inputs = true; cada jugador se une y elige personaje]
→ weapon_selection → difficulty_selection → main.tscn (oleada)
→ fin de oleada: UpgradesUI co-op (mejoras/consumibles por jugador, en paralelo)
→ coop_shop.tscn (tienda co-op: un panel por jugador, en paralelo)
→ main.tscn (siguiente oleada) … → end_run
```
- Cambios de escena con `get_tree().change_scene(...)` en: `ui/menus/pages/main_menu.gd`,
  `ui/menus/run/character_selection.gd`, `weapon_selection.gd`,
  `difficulty_selection/difficulty_selection.gd`, `ui/menus/shop/base_shop.gd`,
  `main.gd` (`_change_scene`), `ui/menus/run/base_end_run.gd`, `retry_wave.gd`.
- `MenuData` (autoload) guarda las rutas de escenas.
- `RunData.is_coop_run` (setter en `run_data.gd:232`) marca la partida como co-op.

## 4. Oleada — `main.gd` (1812 líneas)

- Nodos principales: `Entities` (YSort), `EntitySpawner`, `WaveManager`, `Camera`
  (una sola cámara compartida), `Materials`, `Consumables`, `PlayerProjectiles`,
  `EnemyProjectiles`, `Effects`, `Explosions`, `FloatingTexts`, HUD y UIs.
- Usa **pools de nodos** (`get_node_from_pool` / `add_node_to_pool`) para proyectiles, etc.
- `_players[]` indexado por `player_index`. `_on_EntitySpawner_players_spawned` los conecta.
- `_on_WaveTimer_timeout` → efectos de fin de oleada, cosecha, limpieza.
- `_on_EndWaveTimer_timeout` → en co-op muestra `CoopUpgradesUI`, espera
  `options_processed` y pasa a la tienda (`RunData.get_shop_scene_path()`).
- Selecciones de mejoras/ítems llaman `RunData.apply_item_effects / add_item / add_gold`
  con `player_index`.

## 5. Aleatoriedad / determinismo

- ~130 llamadas a `randf/randi/rand_range/shuffle` en 48 scripts, sobre el RNG global
  (`randomize()` en `progress_data.gd`). `Utils` tiene además un `RandomNumberGenerator`
  propio (`set_rng_seed`).
- Física de Godot + orden de procesamiento + timers por frame.
- **No es determinista** → descartado lockstep (simular en cada máquina con los mismos
  inputs). Se necesita **host autoritativo**.

## 6. Estado de la partida (serializable)

- `RunData.get_state()` / `resume_from_state(state)` (`run_data.gd:1727/1785`): estado
  completo entre oleadas (datos de jugadores, oleada, dificultad, ítems bloqueados en
  tienda, DLCs…). Lo usa "continuar partida".
- `PlayerRunData.serialize()` / `deserialize()` (`player_run_data.gd:78/131`): versión
  serializable (diccionarios) de cada jugador: personaje, armas, ítems, stats, oro, etc.
- **Útil para sincronizar el estado host→clientes en menús/tienda.**

## 7. Particularidades del port Seaven
- `OS_Seaven.get_controller_style(i)` se usa para íconos; `Utils.on_gdk_desktop` es
  `true` en esta versión (comportamiento similar a PC).
- `Utils.is_player_using_gamepad` en `on_console and not on_gdk_desktop` fuerza gamepad.
