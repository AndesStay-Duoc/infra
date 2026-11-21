# Contrato — Tópicos y eventos de Kafka

Kafka lleva el **streaming de analítica y auditoría**: alimenta reportería y el timeline sin
bloquear ni acoplar al servicio de reservas. Todo evento usa el
[envelope común](envelope.md).

## Infraestructura

3 nodos de **Zookeeper** y 3 **brokers**, más Kafka UI (`infra/kafka/compose.yml`). Se fija
`confluentinc/cp-kafka:7.6.1` y `cp-zookeeper:7.6.1` porque el caso exige Zookeeper y Kafka 4.x ya
lo eliminó. En la nube lo despliega `infra/deploy/scripts/crear-kafka.sh` sobre la instancia
`ec2-kafka`.

## Tópicos

| Tópico | Particiones | Réplicas | `min.insync.replicas` | `cleanup.policy` | `retention.ms` | Propósito |
|---|---|---|---|---|---|---|
| `reservations.events` | 3 | 3 | 2 | `delete` | 604800000 (7 días) | Fuente de verdad de los eventos de reserva. Alimenta reportería y auditoría |
| `audit.timeline` | 3 | 3 | 2 | `compact,delete` | 2592000000 (30 días) | Historial de quién, qué, cuándo y entre qué estados |
| `reservations.events.DLT` | 3 | 3 | 2 | `delete` | 1209600000 (14 días) | Lo que falló al consumir `reservations.events`, con metadatos del error |
| `audit.timeline.DLT` | 3 | 3 | 2 | `delete` | 1209600000 (14 días) | Lo mismo para `audit.timeline` |

Los dos tópicos de negocio son `reservations.events` y `audit.timeline`. Los `.DLT` son
infraestructura de error, no canales del dominio.

### Por qué cada valor

**Comunes a los cuatro.**

- **3 particiones.** Es el paralelismo máximo de un grupo: los consumidores corren con
  concurrencia 3, un hilo por partición. Más particiones que hilos no aceleraría nada en este
  volumen y multiplicaría los archivos abiertos por broker.
- **3 réplicas.** Una por broker: cada partición sobrevive a la caída de dos brokers sin perder
  lo ya confirmado.
- **`min.insync.replicas=2`.** Junto con `acks=all` en los productores, una escritura solo se
  confirma cuando está en dos brokers. Con un broker caído el clúster sigue aceptando escrituras;
  con dos caídos las rechaza, en vez de confirmar algo que existe en una sola copia. Las DLT llevan
  el mismo valor: su contenido es evidencia, y perderla por haberla escrito en un solo disco sería
  perder justo lo que se quería conservar.

**`reservations.events`: `delete` y 7 días.** Es un registro de hechos recientes. Sus dos
consumidores, la ingesta de `ms-andesstay-report` y las topologías de Streams, lo leen en
segundos; la historia larga vive en MySQL (`REPORT_STATS`, `AUDIT_EVENTS`). Siete días cubren
con holgura un consumidor caído durante un fin de semana largo y la relectura desde el principio
de una topología nueva. Pasado ese plazo, el evento ya no aporta nada que la base no tenga, y se
borra. No se compacta porque cada evento es un hecho distinto: compactar por `reservationId`
dejaría solo la última transición y los KPI perderían la creación y la confirmación.

**`audit.timeline`: `compact,delete` y 30 días.** Es el historial de quién hizo qué. La
compactación, con la clave `reservationId`, garantiza que el último hecho de cada reserva se
conserva aunque llegue a la retención; `delete` hace que lo intermedio caduque a los 30 días. Los
30 días son la ventana de consulta de auditoría (la misma que usan los KPI históricos) y permiten
reconstruir el timeline de un mes entero desde Kafka si la tabla se pierde.

**Las DLT: `delete` y 14 días.** Guardan lo que falló, con las cabeceras de Spring Kafka (tópico,
partición, offset de origen, excepción y momento). Catorce días son el doble de la ventana de
`reservations.events`: un fallo que nadie revisó en una semana sigue ahí la siguiente. No se
compactan: dos fallos del mismo evento son dos evidencias distintas y no deben pisarse.

### Dónde se definen

**La fuente de verdad es [`infra/kafka/scripts/crear-topicos.sh`](../../../kafka/scripts/crear-topicos.sh).**
Crea los tópicos con `--if-not-exists` y después aplica la configuración con
`kafka-configs --alter`, así que también corrige un tópico que ya existía con otros valores. El
contenedor `kafka-init` del compose ejecuta ese mismo archivo al levantar el clúster, y se puede
lanzar a mano sobre un clúster en marcha.

Los beans `NewTopic` de `KafkaTopicsConfig` en `ms-andesstay-reservations` repiten los valores de
los dos tópicos de negocio, para que un clúster que no se levantó con este compose quede con la
forma correcta. Pero **solo crean**: `TopicBuilder` no modifica un tópico que ya existe. Si los dos
lugares discrepan, manda el script, y el bean se corrige para que vuelva a coincidir.

### Clave de partición

La clave es siempre el **`reservationId`**. Así todos los eventos de una misma reserva caen en la
misma partición y se consumen **en orden**, que es lo que permite reconstruir el timeline y
calcular el tiempo de ciclo correctamente.

En `audit.timeline`, además, la compactación conserva el último evento por clave incluso pasada
la retención.

## Productores y consumidores

| Tópico | Produce | Consume |
|---|---|---|
| `reservations.events` | `ms-andesstay-reservations` | `ms-andesstay-report` (`report-consumer-group` y la topología `report-kpi-streams`), `ms-andesstay-audit` (la topología `audit-timeline-streams`) |
| `audit.timeline` | `ms-andesstay-audit`, desde su topología de Kafka Streams | `ms-andesstay-audit` (`audit-timeline-group`) |

`ms-andesstay-catalog` no participa: no tiene cliente de Kafka. El contrato lo listó un tiempo
como productor de `audit.timeline`, y no lo era.

Cada consumidor usa su propio `group.id`. El `application.id` de una topología de Kafka Streams
funciona como un grupo más y aparece igual en Kafka UI, con sus offsets y su lag.

## El envelope

Todos los eventos comparten la misma forma, tipada como `record` en cada servicio:

```json
{
  "type": "reservation.confirmed",
  "eventId": "9f1c...",
  "timestamp": "2026-11-17T14:31:12Z",
  "traceId": "a3d2...",
  "correlationId": "7b84...",
  "source": "ms-andesstay-reservations",
  "actor": { "userId": "sub-del-token", "role": "Operador", "tenant": "staff" },
  "payload": { }
}
```

`eventId` identifica el evento y es la clave de idempotencia de todos los consumidores.
`traceId` identifica la petición HTTP que lo originó y cambia en cada llamada. `correlationId`
nace con la reserva y acompaña a todos sus eventos: basta filtrar por él para tener su vida
entera.

Los productores **no envían la cabecera con el nombre de la clase Java**. Cada repositorio tiene
su copia del record y declara el tipo que espera al deserializar, de modo que los paquetes no
tienen que coincidir entre repositorios. Los `trusted.packages` de los consumidores están
limitados a `cl.andesstay.*`.

## Eventos de `reservations.events`

Se publica uno **por cada transición** de la máquina de estados. El valor de `type` lo fija
`TipoDeEvento` en `ms-andesstay-reservations` a partir del estado; no se escribe a mano en ningún
sitio.

| Estado | `type` |
|---|---|
| `CREADA` | `reservation.created` |
| `CONFIRMADA` | `reservation.confirmed` |
| `CHECKIN_PENDIENTE` | `reservation.checkin_pending` |
| `EN_ESTADIA` | `reservation.in_stay` |
| `CHECKOUT` | `reservation.checked_out` |
| `CANCELADA` | `reservation.cancelled` |

El `payload` es siempre el mismo record, con los campos que no aplican en `null`:

```json
{
  "reservationId": 123,
  "unitId": 45,
  "guestId": "sub-del-token",
  "guestEmail": "huesped@example.cl",
  "fechaEntrada": "2026-10-12",
  "fechaSalida": "2026-10-15",
  "huespedes": 2,
  "estado": "CONFIRMADA",
  "estadoAnterior": "CREADA",
  "motivo": null,
  "tarifaTotal": 135000,
  "moneda": "CLP",
  "duracionEstadiaHoras": null
}
```

- `estadoAnterior` es `null` en la creación. En las demás transiciones es de donde venía la
  reserva, y es lo que permite que el timeline muestre transiciones y no estados sueltos.
- `motivo` solo viaja en `reservation.cancelled`. Llega opcionalmente en el cuerpo de
  `PUT /api/v1/reservations/{id}/status`.
- `duracionEstadiaHoras` solo viaja en `reservation.checked_out`. Son las horas **comprometidas**
  entre entrada y salida, derivadas de las fechas de la reserva. No es el tiempo de ciclo: ese lo
  calcula `ms-andesstay-report` restando los instantes reales de `reservation.created` y del
  evento de cierre, y sirve para comparar lo prometido con lo ocurrido.

## Eventos de `audit.timeline`

Los produce la topología de Kafka Streams de `ms-andesstay-audit`
(`TimelineTopology`), que lee `reservations.events`, filtra lo que no identifica ninguna entidad y
transforma el resto. Conserva el sobre completo y cambia solo el `payload`:

```json
{
  "entidad": "Reservation",
  "entidadId": "123",
  "accion": "CAMBIO_ESTADO",
  "desde": "CREADA",
  "hacia": "CONFIRMADA",
  "unitId": 45,
  "guestId": "sub-del-token"
}
```

`accion` vale `CREACION` cuando no hay estado de origen y `CAMBIO_ESTADO` en el resto.

El contrato describió durante un tiempo campos `ip` y `userAgent`. No se rellenan: la topología
transforma un evento ya publicado y no tiene delante la petición HTTP que lo originó. Anotar un
valor inventado sería peor que no tenerlo.

## Manejo de errores

Configurado en `KafkaErrorConfig` de `ms-andesstay-audit` y `ms-andesstay-report`:

1. El consumidor reintenta con espera creciente de 1 s, 2 s y 4 s, hasta 3 intentos.
2. Agotados los intentos, `DeadLetterPublishingRecoverer` manda el mensaje a `<tópico>.DLT` con
   las cabeceras estándar de Spring Kafka: tópico, partición y offset de origen, la excepción y el
   momento del fallo.
3. **El offset del tópico original se confirma.** Un mensaje envenenado nunca detiene el consumo.

Hay fallos que **no se reintentan**, porque esperar no los arregla: un JSON inválido
(`DeserializationException`) o un evento sin los campos obligatorios (`IllegalArgumentException`).
Esos van a la cola de descarte en el primer intento.

En las topologías de Kafka Streams, un error de deserialización se registra y se continúa
(`LogAndContinueExceptionHandler`): con el manejador por defecto, un solo mensaje inválido mata el
hilo y la partición deja de avanzar.

## Garantías

- **Productor**: `acks=all`, `enable.idempotence=true`, `max.in.flight=5` —el máximo que la
  idempotencia admite conservando el orden dentro de la partición—, `retries` alto.
- **Rendimiento**: `batch.size` de 32 KB, `linger.ms` de 20 y compresión `snappy`.
  `max.block.ms` acotado a 2 s para que un clúster inalcanzable no cuelgue una petición HTTP.
- **Consumidor**: `enable.auto.commit=false`, confirmación manual después de procesar,
  concurrencia 3 (una por partición).
- **Idempotencia por `eventId`** en todos los consumidores.
- Kafka entrega *al menos una vez*; la idempotencia del consumidor es lo que convierte eso en
  *exactamente una vez* desde el punto de vista del negocio.
