# Propuesta de arquitectura online

Basada en `docs/coop_local.md`. Estado: **propuesta** (pendiente de aprobación).

## Principio
**Host autoritativo + jugadores remotos como dispositivos virtuales.**

- El **host** juega una partida co-op local normal. Los jugadores remotos se registran en
  `CoopService.connected_players` con IDs de dispositivo virtuales (8..11, el rango que el
  juego ya usa para debug) y tipo `GAMEPAD_XBOX` (así apuntan con el stick derecho y no
  dependen del mouse).
- Los **clientes** envían su input; el host lo inyecta como si fuera un mando local.
- El host envía a los clientes lo necesario para **ver** la partida (no simulan nada).

Así se reutiliza el 100 % de la lógica co-op existente (escalado, tienda por jugador,
mejoras por jugador, revivir, etc.) sin reimplementarla.

## Canales (ENet)
| Canal | Modo | Contenido |
|---|---|---|
| 0 | confiable | Control: handshake, versión del mod, lobby, cambios de escena, eventos de menú, estado de `RunData` |
| 1 | no confiable | Input del cliente → host (~60 Hz, último estado gana) |
| 2 | no confiable | Snapshots del mundo host → clientes (~20–30 Hz) |

Puerto por defecto a definir (p. ej. 24565). NAT: conexión directa por IP o VPN
(Tailscale/ZeroTier/Radmin). WebRTC disponible a futuro.

## Lado host
1. **Inyección de input** (por jugador remoto, dispositivo `d`):
   - Ejes: `Input.action_press("analog_move_left_d", fuerza)` etc. y `rjoy_*_d`.
   - Menús: `Input.parse_input_event(InputEventAction{action="ui_accept_d", pressed})`.
   - Crear las acciones `*_8..*_11` en el `InputMap` (sin eventos físicos) y re-crearlas
     cada vez que `InputService._copy_device_actions()` reconstruye el mapa.
2. **Alta de jugadores remotos**: en la selección de personaje, al conectarse un cliente
   llamar `CoopService._add_player(dispositivo_virtual, GAMEPAD_XBOX)`.
3. **Snapshots**: recorrer jugadores, enemigos, proyectiles, materiales, consumibles,
   estructuras y enviar por entidad `{id, tipo_visual, pos, rot, flip, anim/frame, modulate}`
   + HUD (vida, XP, oro, timer de oleada) por jugador.

## Lado cliente
- **Menús** (selección, mejoras, tienda): mostrar las mismas escenas del juego en un modo
  "réplica": el estado viene del host (`RunData` serializado con
  `PlayerRunData.serialize()`), las acciones del jugador local se reenvían al host y el
  resultado vuelve como nuevo estado. El host es la única fuente de verdad.
- **Oleada**: escena "visor" propia que dibuja las entidades del snapshot con las mismas
  texturas del juego, con interpolación entre snapshots. Cámara siguiendo al jugador local.
- Input local: leer el mando/teclado del cliente y enviarlo (vector de movimiento, vector de
  apuntado, acciones de UI).

## Fases propuestas
1. **Red básica**: autoload `OnlineMod`, menú host/unirse (IP:puerto), handshake con versión,
   ping/latencia. Log a `user://`.
2. **Input remoto en el host**: un cliente controla un jugador del host (el cliente todavía no
   ve nada; se valida mirando la pantalla del host). Es el corazón del enfoque.
3. **Visor de oleada en el cliente**: snapshots + render con interpolación.
4. **Menús sincronizados**: selección de personaje/armas/dificultad, mejoras y tienda.
5. **Pulido**: predicción local del movimiento propio, reconexión, desconexiones, compresión
   delta de snapshots, sonidos/efectos visuales en el cliente.
6. **Distribución**: parcheador para usuarios finales (aplica overlay sobre su `boot.hvp`).

## Riesgos / preguntas abiertas
- Latencia: el movimiento propio llega con 1 RTT de retraso hasta tener predicción (fase 5).
- Volumen de snapshots en oleadas avanzadas (cientos de entidades) → delta + cuantización.
- Efectos visuales/sonidos disparados por lógica (no por estado) → eventos explícitos.
- Pruebas: ¿se pueden correr dos instancias del juego en una PC? Si no, hace falta una
  segunda máquina (o un cliente de prueba en Godot 3.6.1 estándar para la parte de red).
