# Demostración en vivo de Kafka · guion operativo

Qué se ejecuta, dónde y en qué orden para la defensa de **Kafka**. Es el equivalente de
[`demostracion-en-vivo.md`](demostracion-en-vivo.md), que cubre RabbitMQ: aquel documento no
menciona Kafka porque se escribió cuando el despliegue tenía dos instancias.

Los comandos y las salidas de este documento se verificaron el **2026-11-23** contra el clúster
local de `infra/kafka/compose.yml` y contra `ec2-kafka`.

---

## Lo primero: son TRES instancias

`demostracion-en-vivo.md` dice que son dos. Ya no:

| Instancia | Dirección | Qué corre |
|---|---|---|
| `ec2-apps` | `44.212.152.92` | bff, catalog, reservations, report, audit, kafka-admin, web, mysql |
| `ec2-mq` | `34.227.147.53` | rabbitmq1, rabbitmq2, notify, mq, mailpit |
| `ec2-kafka` | `100.55.65.252` · privada `172.31.43.37` | zk1-3, kafka1-3, kafka-init, kafka-ui |

Conviene decir por qué están separadas, porque se defiende sola: catorce contenedores no caben en
una `t3.medium`, y mezclar streaming con aplicación hace que un pico de uno se lleve por delante al
otro. La justificación está en el encabezado de
[`crear-kafka.sh`](../../deploy/scripts/crear-kafka.sh).

**La IP privada es la que importa.** `ec2-apps` le habla a Kafka por `172.31.43.37`, no por la
pública. Es lo que decide si el despliegue funciona, y es la pregunta técnica más probable: ver
«El oyente anunciado», más abajo.

---

## Preparación · 15 minutos antes

### 1 · Las terminales

| Terminal | Dónde | Para qué |
|---|---|---|
| A | `ec2-kafka` | la forma de los tópicos y el lag de los grupos |
| B | `ec2-apps` | los logs de `report` y `audit` consumiendo |
| C | equipo propio | las llamadas al administrador y al API |

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@100.55.65.252   # A
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@44.212.152.92   # B
```

En la terminal B, dejar los logs corriendo antes de empezar:

```bash
cd /opt/andesstay
docker compose --env-file .env -f infra/deploy/compose.yml logs -f report audit
```

### 2 · Las pestañas del navegador

| Pestaña | URL |
|---|---|
| Kafka UI | http://100.55.65.252:8090 |
| Aplicación | la URL de `andesstay-web` que imprime `crear-infra.sh` |
| Management UI de RabbitMQ | por túnel, según `demostracion-en-vivo.md` |

Kafka UI está abierto **solo para la IP del expositor**. Si la red cambia —cambiar de wifi, un
móvil compartiendo datos—, deja de responder. Relanzar `crear-kafka.sh` agrega la IP nueva al
Security Group. **Conviene comprobarlo desde la red de la sala**, no desde casa.

### 3 · El token

Igual que en la demostración de RabbitMQ: iniciar sesión en la aplicación con una cuenta de rol
**Admin** y copiar el Bearer del DevTools. `report`, `audit` y `kafka-admin` lo exigen.

### 4 · Un ensayo completo

Hacer el recorrido entero una vez. Lo que más falla no es Kafka: es el token caducado y la IP del
Security Group.

---

## El recorrido, bloque a bloque

### 1 · Por qué Kafka además de RabbitMQ

**Pantalla:** el diagrama, o la tabla de [`kafka.md`](../contracts/events/kafka.md).

Es la pregunta de fondo, y tiene respuesta corta: **son dos herramientas para dos cosas
distintas**, y el sistema usa las dos a la vez sobre la misma reserva.

| | RabbitMQ | Kafka |
|---|---|---|
| Qué transporta | **comandos**: «manda este correo» | **hechos**: «la reserva pasó a CONFIRMADA» |
| Convención del `type` | imperativo: `email.send` | pasado: `reservation.confirmed` |
| Quién lo lee | un consumidor, y el mensaje desaparece | varios, cada uno a su ritmo y por su cuenta |
| Si llega otro consumidor | se reparte la carga | **relee el tópico desde el principio** |
| Retención | hasta que alguien lo confirma | 7 o 30 días, aunque nadie lo lea |

Lo que lo hace evidente: `reservations.events` tiene **tres grupos leyendo el mismo evento** —la
ingesta de reportería, la topología de KPI y la topología del timeline—, y ninguno sabe de los
otros. Con una cola eso no se puede: el primero que confirma se lo lleva. Agregar mañana un cuarto
consumidor no toca ni una línea de `reservations`.

### 2 · El clúster

**Pantalla:** terminal A.

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Tres nodos de Zookeeper y tres brokers, los tres `healthy`.

Dos cosas que conviene adelantarse a explicar:

- **Por qué Zookeeper**, si Kafka ya no lo necesita. Porque el caso lo exige, y Kafka 4.x lo
  eliminó: de ahí que las imágenes estén fijadas en `7.6.1`. Está escrito en la sección
  «Infraestructura» de [`kafka.md`](../contracts/events/kafka.md).
- **Por qué los montones están acotados** a 512 MB por broker y 256 MB por nodo de Zookeeper. Seis
  JVM con los valores por defecto piden 4,5 GB y no caben. El cálculo está en el encabezado de
  [`infra/kafka/compose.yml`](../../kafka/compose.yml).

### 3 · La forma de los tópicos

**Pantalla:** terminal A, y después Kafka UI → *Topics*.

```bash
cd /opt/andesstay && bash infra/kafka/scripts/describir-topicos.sh
```

Cuatro tópicos, todos con **3 particiones, 3 réplicas e ISR completo**:

| Tópico | `cleanup.policy` | `retention.ms` | Para qué |
|---|---|---|---|
| `reservations.events` | `delete` | 7 días | los hechos de la reserva |
| `audit.timeline` | `compact,delete` | 30 días | quién hizo qué, ya derivado |
| `reservations.events.DLT` | `delete` | 14 días | lo que falló al consumir |
| `audit.timeline.DLT` | `delete` | 14 días | lo mismo del otro |

El dato que vale es `Isr: 3,1,2` en cada partición: **las tres réplicas están en sincronía**, así
que la partición sobrevive a la caída de dos brokers.

> **La pregunta que suele venir aquí:** por qué `audit.timeline` se compacta y
> `reservations.events` no. Porque cada evento de reservas es un hecho distinto, y compactar por
> `reservationId` dejaría solo la última transición: los KPI perderían la creación y la
> confirmación. En el timeline, en cambio, lo que interesa es el último estado de cada reserva.
> Está desarrollado en «Por qué cada valor» de [`kafka.md`](../contracts/events/kafka.md).

> **Y la trampa:** `compact,delete` **no** conserva el último hecho para siempre. Pasados los 30
> días no queda ninguno, porque `delete` también actúa. El historial completo no vive en Kafka:
> vive en la tabla `AUDIT_EVENTS` de MySQL. Kafka transporta y amortigua; MySQL conserva. Decirlo
> antes de que lo pregunten es mejor que tener que corregirse.

### 4 · El camino completo, con una sola acción

**Pantalla:** aplicación, terminal B y Kafka UI.

Confirmar una reserva. Eso dispara **las dos mensajerías a la vez**, y es el momento más
demostrativo de toda la defensa:

```
                        ┌─ RabbitMQ ─► q.cmd.email    ─► notify ─► correo
confirmar la reserva ───┤            ► q.cmd.voucher  ─► notify ─► voucher
                        └─ Kafka ───► reservations.events
                                       ├─► report-consumer-group  ─► MySQL REPORT_STATS
                                       ├─► report-kpi-streams     ─► KPI en vivo
                                       └─► audit-timeline-streams ─► audit.timeline
                                                                      └─► audit-timeline-group
                                                                           ─► MySQL AUDIT_EVENTS
```

En Kafka UI → *Topics* → `reservations.events` → *Messages* se ve el sobre entero. Vale la pena
mostrar tres campos:

- **`eventId`** — es la clave de idempotencia. El mismo evento dos veces no produce dos efectos.
- **`correlationId`** — es el mismo en todos los eventos de la reserva. Filtrar por él **es** el
  timeline.
- **la clave del registro, el `reservationId`** — es lo que mete todos los eventos de una reserva
  en la misma partición, y por eso se consumen **en orden**. Sin eso, el tiempo de ciclo saldría
  mal: podría leerse el checkout antes de la creación.

Y después, en `audit.timeline`, el registro **derivado** por la topología de Streams, que no es el
mismo objeto: trae `accion`, `desde` y `hacia`, y conserva el `eventId`, el `traceId` y el
`correlationId` del original.

### 5 · El reparto de particiones y el lag

**Pantalla:** terminal A, y Kafka UI → *Consumers*.

```bash
bash infra/kafka/scripts/inspeccionar-grupos.sh
```

Cuatro grupos. En `report-consumer-group` se ve lo que importa: **tres consumidores, uno por
partición**. Eso es el paralelismo del que se habla en el informe, y aquí se ve en la columna
`CONSUMER-ID`.

El `LAG` en 0 significa que el consumo va al día. Para que el lag **se vea bajar**, hace falta
generar carga: ver «Generar lag visible», más abajo. Conviene enseñar primero este reparto con el
lag en 0 y lanzar la carga después, para que se vea el contraste.

### 6 · Las garantías del productor

**Pantalla:**
`ms-andesstay-reservations/src/main/java/cl/andesstay/reservations/config/KafkaProducerConfig.java`.

Tres líneas sostienen la garantía de que no se pierde ni se duplica un evento:

| Línea | Qué garantiza |
|---|---|
| `ACKS_CONFIG = "all"` | la escritura no se confirma hasta que está en las réplicas en sincronía |
| `ENABLE_IDEMPOTENCE_CONFIG = true` | un reintento del productor no deja el evento dos veces |
| `RETRIES_CONFIG = Integer.MAX_VALUE` | reintenta mientras el `delivery.timeout` de 120 s lo permita |

`acks=all` solo tiene sentido junto al `min.insync.replicas=2` del tópico: **las dos mitades de la
misma garantía**, una en el productor y otra en el broker. Una escritura se confirma cuando está en
dos brokers; con dos brokers caídos el clúster la rechaza en vez de confirmar algo que existe en
una sola copia.

`MAX_BLOCK_MS_CONFIG = 2_000` es la que evita el susto en vivo: sin broker alcanzable, `send()` no
se queda esperando un minuto.

### 7 · El fallo y la DLT

**Pantalla:** terminal B, y Kafka UI → *Topics* → `reservations.events.DLT`.

Un evento que el consumidor no puede procesar —sin `eventId`, sin `timestamp`— se reintenta **tres
veces con esperas de 1 s, 2 s y 4 s** y después se publica en `reservations.events.DLT`, **en la
misma partición** del original. En el log de `audit` aparece:

```
[Audit] Mensaje descartado tras 3 intentos: ...
```

Lo que queda en la DLT lleva las cabeceras de Spring Kafka: tópico, partición y offset de origen,
la excepción y el momento. Por eso las DLT tienen **14 días**, el doble que el tópico de origen: un
fallo que nadie revisó en una semana sigue ahí la siguiente. Y por eso **no se compactan**: dos
fallos del mismo evento son dos evidencias distintas y no deben pisarse.

La configuración está en
`ms-andesstay-audit/src/main/java/cl/andesstay/audit/config/KafkaErrorConfig.java`,
con el mismo archivo en `ms-andesstay-report`.

### 8 · El microservicio administrador

**Pantalla:** Postman, o `curl` en la terminal C.

`ms-andesstay-kafka` administra el clúster por API, igual que `ms-andesstay-mq` hace con RabbitMQ.

**Cómo se llega a él depende del entorno, y conviene tenerlo claro antes.** En `ec2-apps` el
administrador **no publica ningún puerto**: en `deploy/compose.yml` solo nginx lo hace, y esta no
es parte de la aplicación sino una herramienta del operador. Un túnel SSH al 8087 **no sirve**,
porque no hay nada escuchando en el host. Se llama desde dentro de la instancia:

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@44.212.152.92
TOKEN=<el Bearer copiado del DevTools>
docker exec andesstay-kafka-admin wget -qO-   --header "Authorization: Bearer $TOKEN" http://127.0.0.1:8087/api/v1/kafka/topics
```

En el clúster **local**, en cambio, `apps/compose.yml` sí lo publica en `127.0.0.1:8087`, así que
ahí se usa Postman o `curl` contra `http://localhost:8087` sin más. Si la demostración va a usar
Postman, es el entorno local el que lo permite.

| Llamada | Qué muestra |
|---|---|
| `GET /api/v1/kafka/topics` | los tópicos con sus particiones y réplicas |
| `GET /api/v1/kafka/topics/reservations.events` | el detalle: ISR, líderes, configuración efectiva |
| `GET /api/v1/kafka/consumer-groups` | los cuatro grupos |
| `GET /api/v1/kafka/consumer-groups/report-consumer-group` | el lag por partición y por miembro |
| la misma llamada sin token | **401** |

Que las consultas de administración exijan **rol Admin** es parte de lo que se demuestra: la
seguridad no acaba en el API Gateway.

---

## Generar lag visible

**Pantalla:** Postman o `curl`, y Kafka UI → *Consumers* al lado.

Los bloques anteriores muestran el reparto de particiones, pero con el lag en 0: correcto y
estático. Para que **se vea bajar** hace falta carga, y para eso está
`POST /api/v1/kafka/pruebas/carga`, que publica N mensajes de una vez.

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN"   'http://localhost:8087/api/v1/kafka/pruebas/carga?count=10000'
```

En `ec2-apps`, por `docker exec`, como en el bloque 8.

Diez mil mensajes bastan para que el lag aparezca en Kafka UI y en
`GET /consumer-groups/report-consumer-group`, y baje mientras se mira. La clave de cada mensaje va
variando a propósito: con una sola, todos caerían en la misma partición y el retraso se
concentraría en un consumidor, que es lo contrario de lo que se quiere mostrar.

> **Si la ruta responde 404**, el perfil `demo` no está activo. La clase no se registra sin él, y
> por eso es 404 y no 403: no hay nada ahí. Lo gobierna `KAFKA_ADMIN_PERFIL`, que viene con `demo`
> por omisión; definirla **vacía** lo apaga. La razón de que esté detrás de un perfil está en el
> encabezado de
> `ms-andesstay-kafka/src/main/java/cl/andesstay/kafka/controller/PruebaDeCargaController.java`:
> un administrador que puede inyectar diez mil mensajes en un tópico de producción no es un
> administrador.

**No lanzar la carga antes del bloque 5**, o el reparto de particiones se enseña con el lag ya
alto y se pierde el contraste entre un grupo al día y uno retrasado.

---

## Dónde vive cada configuración y cada justificación

Esta es la tabla para responder «¿y dónde está eso?» sin buscar.

### Infraestructura del clúster

| Qué | Dónde |
|---|---|
| Zookeeper, brokers, Kafka UI, puertos | [`infra/kafka/compose.yml`](../../kafka/compose.yml) |
| Por qué Zookeeper y no KRaft; por qué `7.6.1` | «Infraestructura» de [`kafka.md`](../contracts/events/kafka.md) |
| El oyente anunciado, y por qué decide si funciona | encabezado de [`infra/kafka/compose.yml`](../../kafka/compose.yml) |
| El reparto de memoria de las seis JVM | encabezado de [`infra/kafka/compose.yml`](../../kafka/compose.yml) |
| Tuning del broker: retención, segmentos, réplicas de los tópicos internos | bloque «Tuning del broker» de cada broker en el compose |
| Despliegue en la nube y Security Group | [`infra/deploy/scripts/crear-kafka.sh`](../../deploy/scripts/crear-kafka.sh) |

### Los tópicos

| Qué | Dónde |
|---|---|
| **Fuente de verdad** de particiones, réplicas, `min.insync.replicas`, políticas y retención | [`infra/kafka/scripts/crear-topicos.sh`](../../kafka/scripts/crear-topicos.sh) |
| Justificación de **cada valor**, uno por uno | «Por qué cada valor» de [`kafka.md`](../contracts/events/kafka.md) |
| Por qué la clave es el `reservationId` | «Clave de partición» de [`kafka.md`](../contracts/events/kafka.md) |
| Beans `NewTopic`, que **solo crean** y no modifican | `KafkaTopicsConfig` en `ms-andesstay-reservations` |

Si el script y los beans discrepan, **manda el script**: aplica la configuración con
`kafka-configs --alter`, así que también corrige un tópico que ya existía con otros valores. El
`TopicBuilder` de Spring no modifica un tópico que ya existe.

### Los eventos

| Qué | Dónde |
|---|---|
| El envelope común, campo por campo | [`envelope.md`](../contracts/events/envelope.md) |
| `traceId` frente a `correlationId` | [`envelope.md`](../contracts/events/envelope.md) |
| Por qué la idempotencia es obligatoria | «Idempotencia» de [`envelope.md`](../contracts/events/envelope.md) |
| Qué `type` corresponde a cada estado | «Eventos de `reservations.events`» de [`kafka.md`](../contracts/events/kafka.md) |
| El payload, campo por campo | la misma sección |
| Quién produce y quién consume cada tópico | «Productores y consumidores» de [`kafka.md`](../contracts/events/kafka.md) |

### El código

| Qué | Dónde |
|---|---|
| Garantías del productor: `acks=all`, idempotencia, reintentos | `config/KafkaProducerConfig` en `ms-andesstay-reservations` |
| Publicación del evento en cada transición | `messaging/ReservationEventPublisher` en `ms-andesstay-reservations` |
| El `type` derivado del estado, nunca escrito a mano | `messaging/events/TipoDeEvento` en `ms-andesstay-reservations` |
| Consumidor, concurrencia y confirmación manual | `config/KafkaConsumerConfig` en `report` y en `audit` |
| Reintentos y publicación en la DLT | `config/KafkaErrorConfig` en `report` y en `audit` |
| Topología de KPI en vivo | `streams/KpiTopology` en `ms-andesstay-report` |
| Topología del timeline | `streams/TimelineTopology` en `ms-andesstay-audit` |
| Persistencia del timeline en MySQL | `consumer/AuditTimelineConsumer` en `ms-andesstay-audit` |
| Interruptor para arrancar sin clúster | `andesstay.kafka.enabled` en el `application.yml` de `report` y `audit` |
| API de administración del clúster | `controller/TopicController` y `ConsumerGroupController` en `ms-andesstay-kafka` |

---

## Plan B

| Si falla | Qué hacer |
|---|---|
| Kafka UI no responde | la IP de la sala no está en el Security Group: relanzar `crear-kafka.sh`, o demostrar todo por terminal A, que no depende de la red |
| Un broker queda `unhealthy` | seguir igual: con `min.insync.replicas=2` el clúster acepta escrituras con un broker caído, y **eso es justamente lo que había que demostrar** |
| El token caducó | volver a iniciar sesión en la aplicación y copiar el Bearer otra vez |
| `ec2-apps` no alcanza Kafka | comprobar `KAFKA_HOST` en el `.env` de la instancia: tiene que ser la **IP privada** de `ec2-kafka` |
| Nada responde | el clúster local de `infra/kafka/compose.yml` da el mismo recorrido completo, salvo las tres instancias |
