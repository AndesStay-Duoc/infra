# Contrato — Máquina de estados de la reserva

Contrato canónico. Cualquier cambio aquí obliga a actualizar `ms-andesstay-reservations`,
el BFF y el frontend en el mismo PR.

## Estados

| Estado | Significado |
|---|---|
| `CREADA` | La reserva existe pero no compromete disponibilidad todavía |
| `CONFIRMADA` | Se descontó el cupo de la unidad. La reserva es firme |
| `CHECKIN_PENDIENTE` | El huésped está por llegar; la unidad debe estar preparada |
| `EN_ESTADIA` | El huésped ocupa la unidad |
| `CHECKOUT` | La estadía terminó. Estado final |
| `CANCELADA` | La reserva se anuló. Estado final |

### Nota de codificación

El enum en código y en la API usa **`EN_ESTADIA` sin tilde**, para evitar problemas de encoding
en JSON, en parámetros de URL y en Oracle. El deserializador **acepta también `EN_ESTADÍA`** por
compatibilidad con el enunciado del caso, pero siempre responde con la forma sin tilde.

## Transiciones válidas

```
CREADA ──► CONFIRMADA ──► CHECKIN_PENDIENTE ──► EN_ESTADIA ──► CHECKOUT
   │            │                 │                  │
   └────────────┴─────────────────┴──────────────────┘
                        └──► CANCELADA
```

| # | Desde | Hacia | Roles permitidos | Efecto lateral |
|---|---|---|---|---|
| 1 | *(ninguno)* | `CREADA` | Huésped, Recepcionista | — |
| 2 | `CREADA` | `CONFIRMADA` | Recepcionista, Admin | **`hold` de cupo en catalog** + mensajes `email.send` y `voucher.gen` |
| 3 | `CREADA` | `CANCELADA` | Huésped (solo las propias), Recepcionista, Admin | — |
| 4 | `CONFIRMADA` | `CHECKIN_PENDIENTE` | Recepcionista | Mensaje `housekeeping.ticket` |
| 5 | `CONFIRMADA` | `CANCELADA` | Recepcionista, Admin | **`release` de cupo en catalog** |
| 6 | `CHECKIN_PENDIENTE` | `EN_ESTADIA` | Recepcionista | — |
| 7 | `CHECKIN_PENDIENTE` | `CANCELADA` | Recepcionista, Admin | **`release` de cupo en catalog** |
| 8 | `EN_ESTADIA` | `CHECKOUT` | Recepcionista | **`release` de cupo** + mensaje `housekeeping.ticket` |

Toda transición produce un evento en `reservations.events` y otro en `audit.timeline`.

## Reglas invariables

1. **No hay check-in sin confirmar.** Pasar de `CREADA` a `CHECKIN_PENDIENTE` o a `EN_ESTADIA`
   está prohibido. Es la regla explícita del caso.
2. **`CHECKOUT` y `CANCELADA` son finales.** Desde ellos no sale ninguna transición.
3. **No se salta ningún paso.** La única ruta hacia `EN_ESTADIA` pasa por `CONFIRMADA` y luego
   `CHECKIN_PENDIENTE`.
4. **Confirmar sin cupo falla.** Si `catalog` rechaza el `hold`, la respuesta es `409` y la
   reserva **permanece en `CREADA`**. Esta regla es la que resuelve el overbooking del caso.
5. **Un huésped solo opera sobre sus propias reservas**, y lo único que puede hacer es
   cancelarlas mientras estén en `CREADA`.

## Respuestas de error

| Situación | Código | Cuerpo |
|---|---|---|
| Transición no permitida por la tabla | `409` | `{"error":"TRANSICION_INVALIDA","desde":"CREADA","hacia":"EN_ESTADIA"}` |
| Sin cupo al confirmar | `409` | `{"error":"SIN_DISPONIBILIDAD","unitId":"..."}` |
| Rol sin permiso para esa transición | `403` | `{"error":"ROL_INSUFICIENTE"}` |
| Reserva inexistente | `404` | `{"error":"RESERVA_NO_ENCONTRADA"}` |
| Estado no reconocido en el cuerpo | `400` | `{"error":"ESTADO_INVALIDO"}` |

## Casos de prueba obligatorios

Estos son los tests que `ms-andesstay-reservations` debe tener verdes:

| Caso | Esperado |
|---|---|
| `CREADA → CONFIRMADA` con cupo | `200` |
| `CREADA → CONFIRMADA` sin cupo | `409` y la reserva sigue en `CREADA` |
| `CREADA → CHECKIN_PENDIENTE` | `409` |
| `CREADA → EN_ESTADIA` | `409` |
| Ruta feliz completa hasta `CHECKOUT` | `200` en cada paso |
| `CHECKOUT → cualquier estado` | `409` |
| `CANCELADA → cualquier estado` | `409` |
| Huésped intentando confirmar | `403` |
| Huésped cancelando una reserva ajena | `403` |
