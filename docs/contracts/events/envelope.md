# Contrato — Envelope común de eventos y mensajes

Todo lo que viaja por RabbitMQ o por Kafka usa este sobre. Sin excepciones: permite trazar una
operación completa a través de los siete servicios y es la base de la idempotencia.

## Estructura

```json
{
  "type": "reservation.confirmed",
  "eventId": "9f1c3b62-4d7e-4a1f-8c22-0b6d5e2a7f13",
  "timestamp": "2026-09-09T14:30:00Z",
  "traceId": "3a7f1e90-2c44-4b8d-9e01-7f2b5c8a4d16",
  "correlationId": "b81d4f27-6e93-4c05-a7f8-1d3e9b2c6a40",
  "source": "ms-andesstay-reservations",
  "actor": {
    "userId": "sub-del-token",
    "role": "RECEPCIONISTA",
    "tenant": "staff"
  },
  "payload": { }
}
```

## Campos

| Campo | Tipo | Obligatorio | Descripción |
|---|---|---|---|
| `type` | string | sí | Tipo de evento en notación de puntos: `<agregado>.<hecho en pasado>` |
| `eventId` | UUID v4 | sí | **Clave de idempotencia.** Único por evento, nunca se reutiliza |
| `timestamp` | ISO 8601 UTC | sí | Momento en que ocurrió el hecho, no en que se publicó |
| `traceId` | UUID v4 | sí | Identifica la petición HTTP original. Se propaga por toda la cadena |
| `correlationId` | UUID v4 | sí | Agrupa los eventos de un mismo flujo de negocio, típicamente el ciclo de una reserva |
| `source` | string | sí | Servicio que publicó el evento |
| `actor.userId` | string | sí | `sub` del token de quien originó la acción |
| `actor.role` | string | sí | Rol con el que actuó |
| `actor.tenant` | `staff` \| `guest` | sí | De qué tenant venía el token |
| `payload` | objeto | sí | Datos propios del tipo de evento. Puede ser `{}` |

### `traceId` frente a `correlationId`

- **`traceId`** cambia en cada petición HTTP. Sirve para reconstruir *una* llamada.
- **`correlationId`** se mantiene durante todo el ciclo de vida de la reserva. Todos los eventos
  de una misma reserva lo comparten, así que basta filtrar por él para armar el timeline.

Cuando `ms-andesstay-reservations` crea una reserva, genera el `correlationId` y lo guarda junto
a la entidad. Cada evento posterior de esa reserva lo reutiliza.

## Idempotencia

Todo consumidor, de RabbitMQ y de Kafka, mantiene un registro de los `eventId` ya procesados y
**descarta duplicados en silencio**, confirmando el mensaje sin volver a ejecutar el efecto.

Es obligatorio porque ambos sistemas garantizan entrega *al menos una vez*: un `ack` perdido o
un rebalanceo de particiones reentrega mensajes ya procesados. Sin esta comprobación, un huésped
recibiría el mismo correo dos veces o el cupo se descontaría de más.

Para consumidores sin base de datos, como `ms-andesstay-notify`, el registro puede ser una caché
en memoria con expiración; para los que persisten, una tabla con `eventId` como clave primaria.

## Convención de nombres de `type`

`<agregado>.<hecho en pasado>`, en inglés y minúsculas:

| Tipo | Cuándo |
|---|---|
| `reservation.created` | Se creó una reserva |
| `reservation.confirmed` | Pasó a `CONFIRMADA` |
| `reservation.checkin_pending` | Pasó a `CHECKIN_PENDIENTE` |
| `reservation.in_stay` | Pasó a `EN_ESTADIA` |
| `reservation.checked_out` | Pasó a `CHECKOUT` |
| `reservation.cancelled` | Pasó a `CANCELADA` |
| `unit.created` | Se dio de alta una unidad |
| `unit.updated` | Cambió tarifa o disponibilidad |
| `availability.held` | Se reservó cupo |
| `availability.released` | Se liberó cupo |

Los **comandos** de RabbitMQ usan otra convención, en imperativo, porque piden que algo ocurra
en vez de contar que ya ocurrió: `email.send`, `housekeeping.ticket`, `voucher.gen`. Ver
[`rabbit.md`](rabbit.md).

## Evolución del contrato

- Agregar un campo opcional a `payload` es compatible: los consumidores ignoran lo que no
  conocen.
- Quitar o renombrar un campo, o cambiar su tipo, **no** es compatible: exige un `type` nuevo y
  mantener ambos hasta que todos los consumidores migren.
- Un consumidor **nunca** falla por encontrar campos que no esperaba.
