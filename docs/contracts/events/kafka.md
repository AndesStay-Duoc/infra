# Contrato — Tópicos y eventos de Kafka

Kafka lleva el **streaming de analítica y auditoría**: alimenta reportería y el timeline sin
bloquear ni acoplar al servicio de reservas. Todo evento usa el
[envelope común](envelope.md).

## Infraestructura

3 nodos de **Zookeeper** y 3 **brokers**, más Kafka UI. Se fija `confluentinc/cp-kafka:7.x` y
`cp-zookeeper:7.x` porque el caso exige Zookeeper y Kafka 4.x ya lo eliminó.

## Tópicos

| Tópico | Particiones | Réplicas | `cleanup.policy` | Retención | Propósito |
|---|---|---|---|---|---|
| `reservations.events` | 3 | 3 | `delete` | 7 días | Fuente de verdad de los eventos de reserva. Alimenta reportería y auditoría |
| `audit.timeline` | 3 | 3 | `compact,delete` | 30 días | Historial de quién, qué, cuándo y desde dónde |
| `<consumidor>.DLT` | 3 | 3 | `delete` | 14 días | Mensajes que fallaron tras N reintentos, con metadatos del error |

Con 3 réplicas y 3 brokers, `min.insync.replicas` se fija en `2`: tolera la caída de un broker
sin perder disponibilidad de escritura.

### Clave de partición

La clave es siempre el **`reservationId`**. Así todos los eventos de una misma reserva caen en la
misma partición y se consumen **en orden**, que es lo que permite reconstruir el timeline y
calcular el tiempo de ciclo correctamente.

En `audit.timeline`, además, la compactación conserva el último evento por clave incluso pasada
la retención.

## Productores y consumidores

| Tópico | Produce | Consume |
|---|---|---|
| `reservations.events` | `ms-andesstay-reservations` | `ms-andesstay-report`, `ms-andesstay-audit` |
| `audit.timeline` | `ms-andesstay-reservations`, `ms-andesstay-catalog` | `ms-andesstay-audit` |

Cada consumidor usa su propio `group.id`, con el nombre del servicio.

## Eventos de `reservations.events`

Se publica uno **por cada transición** de la máquina de estados.

### `reservation.created`

```json
{
  "type": "reservation.created",
  "eventId": "...", "timestamp": "...", "traceId": "...", "correlationId": "...",
  "source": "ms-andesstay-reservations",
  "actor": { "userId": "...", "role": "HUESPED", "tenant": "guest" },
  "payload": {
    "reservationId": "R-2026-000123",
    "unitId": "U-045",
    "guestId": "sub-del-token",
    "guestEmail": "huesped@example.cl",
    "fechaEntrada": "2026-10-12",
    "fechaSalida": "2026-10-15",
    "huespedes": 2,
    "estado": "CREADA"
  }
}
```

### `reservation.confirmed`

Mismo `payload` con `estado: "CONFIRMADA"`, más:

```json
{
  "estadoAnterior": "CREADA",
  "tarifaTotal": 135000,
  "moneda": "CLP"
}
```

### `reservation.checkin_pending`, `reservation.in_stay`, `reservation.checked_out`, `reservation.cancelled`

Todos comparten la forma:

```json
{
  "reservationId": "R-2026-000123",
  "unitId": "U-045",
  "estado": "<nuevo estado>",
  "estadoAnterior": "<estado previo>",
  "motivo": "<opcional, solo en cancelled>"
}
```

`reservation.checked_out` agrega `duracionEstadiaHoras`, que es lo que `ms-andesstay-report` usa
para el KPI de tiempo de ciclo.

## Eventos de `audit.timeline`

Formato uniforme: lo que importa es quién, qué, cuándo y desde dónde.

```json
{
  "type": "reservation.confirmed",
  "eventId": "...", "timestamp": "...", "traceId": "...", "correlationId": "...",
  "source": "ms-andesstay-reservations",
  "actor": { "userId": "...", "role": "RECEPCIONISTA", "tenant": "staff" },
  "payload": {
    "entidad": "Reservation",
    "entidadId": "R-2026-000123",
    "accion": "CAMBIO_ESTADO",
    "desde": "CREADA",
    "hacia": "CONFIRMADA",
    "ip": "190.44.x.x",
    "userAgent": "Mozilla/5.0 ..."
  }
}
```

`ms-andesstay-catalog` publica aquí sus propias acciones con `entidad: "Unit"` o
`entidad: "Availability"` y `accion` en `CREACION`, `ACTUALIZACION`, `HOLD` o `RELEASE`.

## Manejo de errores

1. El consumidor reintenta con backoff exponencial, hasta `N` intentos (por defecto 3).
2. Agotados los intentos, el mensaje va a `<consumidor>.DLT` con estos metadatos añadidos:

```json
{
  "originalTopic": "reservations.events",
  "originalPartition": 1,
  "originalOffset": 48210,
  "failedAt": "2026-09-09T14:31:12Z",
  "attempts": 3,
  "errorClass": "org.springframework.dao.DataIntegrityViolationException",
  "errorMessage": "..."
}
```

3. El offset del tópico original **se confirma** para no bloquear la partición.

Un mensaje envenenado nunca detiene el consumo: es lo que se demuestra en la evidencia de la
Fase 7.

## Garantías

- **Productor**: `acks=all`, `enable.idempotence=true`, `retries` alto.
- **Consumidor**: `enable.auto.commit=false`, confirmación manual después de procesar.
- **Idempotencia por `eventId`** en todos los consumidores, según el [envelope](envelope.md).
- Kafka entrega *al menos una vez*; la idempotencia del consumidor es lo que convierte eso en
  *exactamente una vez* desde el punto de vista del negocio.
