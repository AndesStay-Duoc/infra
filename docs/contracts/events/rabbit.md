# Contrato — Topología y mensajes de RabbitMQ

RabbitMQ lleva las **tareas asíncronas**: lo que hay que *hacer*, no lo que ya *ocurrió*. Por eso
sus mensajes son comandos en imperativo, a diferencia de los eventos de
[Kafka](kafka.md). Todos usan el [envelope común](envelope.md).

## Infraestructura

Clúster de **2 nodos** con Management UI habilitada.

## Exchanges

| Exchange | Tipo | Propósito |
|---|---|---|
| `cmd.direct` | direct | Enrutamiento exacto por routing key |
| `cmd.topic` | topic | Enrutamiento por patrón, para suscripciones más amplias. **Hoy sin publicador** (ver abajo) |
| `cmd.dead.dlx` | direct | Dead letter exchange al que van los mensajes agotados |

### `cmd.topic`: declarado, enlazado y sin publicador, a propósito

Ningún servicio publica hoy en `cmd.topic`. `ms-andesstay-reservations` envía los tres comandos
por `cmd.direct`, con la routing key exacta de cada uno. Se mantiene de todos modos, por tres
razones:

- **Es parte de la topología del caso**: tres exchanges y nueve bindings. Quitarlo dejaría dos
  exchanges y seis bindings.
- **Es la vía para suscripciones por patrón.** Un servicio nuevo que necesite, por ejemplo, todos
  los comandos de housekeeping, cualquiera sea su subtipo, publica o se enlaza aquí con
  `housekeeping.#` sin tocar `cmd.direct` ni sus bindings exactos.
- **Muestra una cola con varias routing keys**, que es uno de los patrones de la guía 2.1.3:
  `q.cmd.email` recibe por `email.send` en `cmd.direct` y por `email.*` en `cmd.topic`.

Lo declaran los mismos que declaran el resto: el exchange, `ms-andesstay-reservations` y
`ms-andesstay-notify`, de forma idempotente; los tres bindings, solo `notify`. Está en la lista de
protegidos de `ms-andesstay-mq`.

**Cuidado al darle uso.** Un mensaje publicado en `cmd.topic` con una routing key que también
existe en `cmd.direct` llega **una sola vez**, porque va a un solo exchange. Pero si un productor
publicara el mismo comando en los dos exchanges, la cola lo recibiría dos veces. La idempotencia
por `eventId` de notify evita el efecto doble, aunque no el mensaje duplicado. La regla es un
exchange por comando.

## Colas

Seis colas: tres de trabajo y tres de mensajes muertos.

| Cola principal | Propósito | DLQ | Binding en `cmd.direct` | Binding en `cmd.topic` |
|---|---|---|---|---|
| `q.cmd.email` | Correo o push al huésped: confirmación, recordatorio de check-in, checkout | `q.cmd.email.dlq` | `email.send` | `email.*` |
| `q.cmd.housekeeping` | Ticket de preparación o limpieza de la unidad | `q.cmd.housekeeping.dlq` | `housekeeping.ticket` | `housekeeping.#` |
| `q.cmd.voucher` | Generación del PDF de voucher o boleta | `q.cmd.voucher.dlq` | `voucher.gen` | `voucher.*` |

### Argumentos de las colas principales

| Argumento | Valor |
|---|---|
| `x-dead-letter-exchange` | `cmd.dead.dlx` |
| `x-dead-letter-routing-key` | `<nombre de la cola>.dlq` |
| `durable` | `true` |

Las DLQ son `durable` y **no** tienen dead letter propio: son el final del camino.

## Quién publica y quién consume

| | Publica | Consume |
|---|---|---|
| Las tres colas | `ms-andesstay-reservations` | `ms-andesstay-notify` |

## Mensajes

### `email.send` → `q.cmd.email`

```json
{
  "type": "email.send",
  "eventId": "...", "timestamp": "...", "traceId": "...", "correlationId": "...",
  "source": "ms-andesstay-reservations",
  "actor": { "userId": "...", "role": "RECEPCIONISTA", "tenant": "staff" },
  "payload": {
    "plantilla": "RESERVA_CONFIRMADA",
    "destinatario": "huesped@example.cl",
    "reservationId": "R-2026-000123",
    "datos": {
      "nombreHuesped": "Ana Soto",
      "unidad": "Cabaña Coigüe",
      "fechaEntrada": "2026-10-12",
      "fechaSalida": "2026-10-15",
      "tarifaTotal": 135000
    }
  }
}
```

Plantillas: `RESERVA_CONFIRMADA`, `RECORDATORIO_CHECKIN`, `CHECKOUT_REALIZADO`,
`RESERVA_CANCELADA`.

### `housekeeping.ticket` → `q.cmd.housekeeping`

```json
{
  "type": "housekeeping.ticket",
  "payload": {
    "reservationId": "R-2026-000123",
    "unitId": "U-045",
    "unidad": "Cabaña Coigüe",
    "tipoTarea": "PREPARACION",
    "prioridad": "ALTA",
    "fechaRequerida": "2026-10-12T14:00:00Z",
    "notas": "2 huéspedes"
  }
}
```

`tipoTarea` es `PREPARACION` cuando la reserva pasa a `CHECKIN_PENDIENTE`, y `LIMPIEZA` cuando
pasa a `CHECKOUT`. Este mensaje es el que resuelve el problema de que housekeeping se enteraba
tarde.

### `voucher.gen` → `q.cmd.voucher`

```json
{
  "type": "voucher.gen",
  "payload": {
    "reservationId": "R-2026-000123",
    "tipoDocumento": "VOUCHER",
    "destinatario": "huesped@example.cl",
    "datos": {
      "nombreHuesped": "Ana Soto",
      "unidad": "Cabaña Coigüe",
      "fechaEntrada": "2026-10-12",
      "fechaSalida": "2026-10-15",
      "noches": 3,
      "tarifaNoche": 45000,
      "tarifaTotal": 135000,
      "moneda": "CLP"
    }
  }
}
```

`tipoDocumento` es `VOUCHER` o `BOLETA`. Este mensaje resuelve el problema de que el huésped no
recibía comprobante formal.

## Cuándo se publica cada uno

| Transición de la reserva | Mensajes |
|---|---|
| `CREADA → CONFIRMADA` | `email.send` (`RESERVA_CONFIRMADA`) y `voucher.gen` |
| `CONFIRMADA → CHECKIN_PENDIENTE` | `housekeeping.ticket` (`PREPARACION`) y `email.send` (`RECORDATORIO_CHECKIN`) |
| `EN_ESTADIA → CHECKOUT` | `housekeeping.ticket` (`LIMPIEZA`) y `email.send` (`CHECKOUT_REALIZADO`) |
| `* → CANCELADA` | `email.send` (`RESERVA_CANCELADA`) |

Ver [`estados.md`](../estados.md).

## Consumo y manejo de errores

1. **`ACK` manual**, nunca automático. El mensaje se confirma solo después de procesarse bien.
2. **Idempotencia por `eventId`**: un duplicado se confirma sin reejecutar el efecto.
3. Ante error, **`NACK` con `requeue=false`** tras agotar los reintentos, para que el mensaje
   viaje a su DLQ por el `x-dead-letter-exchange`.
4. **Reintentos con backoff, en el broker y no en proceso.** El consumidor publica una copia del
   mensaje en `q.cmd.<flujo>.retry` con la propiedad `expiration` puesta al peldano que toque, y
   confirma el original; nadie consume esa cola, asi que lo unico que saca al mensaje de ahi es el
   vencimiento de su plazo, y entonces su `x-dead-letter-exchange` lo devuelve a la cola de
   trabajo. La escalera se declara literal en `NOTIFY_BACKOFF_LADDER`, por omision
   `1000,2000,4000`: **tres esperas significan cuatro intentos**.

   La cuenta de intentos viaja en la cabecera propia `x-andesstay-intentos`, y no en la `x-death`
   del broker: esa se identifica por el par `(queue, reason)`, de modo que un vencimiento por TTL y
   un desborde por `x-max-length` sobre la misma cola producen contadores distintos.

### Distinguir el error transitorio del permanente

- **Transitorio** (servidor de correo caído, timeout): se reintenta.
- **Permanente** (destinatario inválido, plantilla inexistente): va directo a la DLQ sin gastar
  reintentos.

## Métricas

`ms-andesstay-notify` expone por Actuator:

| Métrica | Qué mide |
|---|---|
| `notify.messages.processed` | Mensajes procesados con éxito, por cola |
| `notify.messages.retried` | Reintentos, por cola |
| `notify.messages.dlq` | Mensajes enviados a DLQ, por cola |
| `notify.dlq.rate` | Proporción de mensajes que terminan en DLQ |

La tasa de DLQ es el indicador de salud del sistema de notificaciones: si sube, algo cambió
aguas arriba.

## Verificación

| Prueba | Esperado |
|---|---|
| Confirmar una reserva | Aparecen mensajes en `q.cmd.email` y `q.cmd.voucher`, y se consumen |
| Publicar un mensaje con plantilla inexistente | Tras 3 intentos, llega a `q.cmd.email.dlq` |
| Publicar dos veces el mismo `eventId` | Se procesa una sola vez |
| Detener `notify` y publicar | Los mensajes se acumulan y se procesan al reiniciar |

Las capturas de la Management UI van a `infra/docs/evidencias/rabbitmq/`.
