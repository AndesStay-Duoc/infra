# Plan de validación de RabbitMQ — AndesStay

> Contraste de la implementación de mensajería de AndesStay con las tres guías del curso ubicadas
> en esta misma carpeta, y plan de corrección derivado.
>
> Guías contrastadas:
>
> - `2.1.3 Exchanges, bindings y routing keys aplicados al caso.pdf`
> - `2.2.1 Patrones publish subscribe, acknowledgements y durabilidad.pdf`
> - `2.2.3 DLX DLQ, políticas de retención y alertas.pdf`
>
> Fecha: 2026-10-10 · Alcance: fase 6 del [CHECKLIST.md](CHECKLIST.md)

---

## 1. Resumen ejecutivo

La topología de RabbitMQ coincide con el enunciado del caso: tres exchanges, seis colas y nueve
bindings, todos durables. Lo que no coincide es el **comportamiento en caso de fallo**, que es
precisamente lo que enseñan las guías 2.2.1 y 2.2.3.

Tres conclusiones, en orden de gravedad:

1. **El reintento con backoff no se ejecuta nunca.** Está configurado, pero el patrón de los
   consumidores lo deja inerte. El primer fallo envía el mensaje directo a la DLQ. El criterio de
   cierre de la fase 6 — «un mensaje forzado a fallar termina en su DLQ tras N reintentos» — hoy
   no se puede demostrar.
2. **No existen las métricas de tasa de DLQ** que el contrato promete: `ms-andesstay-notify` no
   tiene la dependencia de Actuator en su `pom.xml`.
3. **Faltan las políticas de retención** de la guía 2.2.3: ninguna cola declara `x-message-ttl` ni
   `x-max-length`, y las DLQ no tienen TTL de retención.

A eso se suma que el flujo está **apagado en la nube**: el despliegue en EC2 corre con
`ANDESSTAY_EVENTS_ENABLED=false` y `ms-andesstay-notify` ni se clona.

---

## 2. Qué existe hoy

### 2.1 Topología

Declarada únicamente en `infra/mq/rabbitmq-definitions.json`. No hay ningún `@Bean` de `Queue`,
`Exchange` ni `Binding` en todo el sistema.

| Exchange | Tipo | Durable | Quién publica |
|---|---|---|---|
| `cmd.direct` | direct | sí | `ms-andesstay-reservations` |
| `cmd.topic` | topic | sí | **nadie** |
| `cmd.dead.dlx` | direct | sí | el broker, por dead lettering |

| Cola | Durable | DLX | Routing key de descarte | Quién consume |
|---|---|---|---|---|
| `q.cmd.email` | sí | `cmd.dead.dlx` | `email.dead` | `EmailConsumer` |
| `q.cmd.housekeeping` | sí | `cmd.dead.dlx` | `housekeeping.dead` | `HousekeepingConsumer` |
| `q.cmd.voucher` | sí | `cmd.dead.dlx` | `voucher.dead` | `VoucherConsumer` |
| `q.cmd.email.dlq` | sí | — | — | **nadie** |
| `q.cmd.housekeeping.dlq` | sí | — | — | **nadie** |
| `q.cmd.voucher.dlq` | sí | — | — | **nadie** |

Nueve bindings: tres en `cmd.direct` (`email.send`, `housekeeping.ticket`, `voucher.gen`), tres en
`cmd.topic` (`email.*`, `housekeeping.#`, `voucher.*`) y tres en `cmd.dead.dlx`.

### 2.2 Infraestructura

`infra/mq/compose.yml` levanta un clúster de dos nodos `rabbitmq:3.13-management`, con la UI de
gestión en el 15672 y healthcheck `rabbitmq-diagnostics ping` en ambos.

### 2.3 Quién habla con el broker

Solo dos de los siete servicios. `ms-andesstay-bff`, `catalog`, `audit` y `report` no tienen
siquiera `spring-boot-starter-amqp` en su `pom.xml`.

---

## 3. Validación contra la guía 2.1.3 — Exchanges, bindings y routing keys

| Concepto de la guía | Estado en AndesStay | Veredicto |
|---|---|---|
| Exchange declarado con `@Bean` (`DirectExchange`) | Solo en `rabbitmq-definitions.json:4-6` | Falta |
| Colas durables declaradas con `@Bean` | Solo en `rabbitmq-definitions.json:9-24` | Falta |
| Bindings declarados con `BindingBuilder` | Solo en el archivo de definiciones | Falta |
| Varios bindings con routing key por cola | 9 bindings en `rabbitmq-definitions.json:26-34` | Cumple |
| Una cola enlazada con varias routing keys | `q.cmd.email` responde a `email.send` y a `email.*` | Cumple |
| Productor con `RabbitTemplate.convertAndSend(exchange, rk, msg)` | `NotificationPublisher.java:57,74,90` | Cumple |
| Consumidor `@RabbitListener` por cola | `EmailConsumer:33`, `HousekeepingConsumer:26`, `VoucherConsumer:26` | Cumple |
| El exchange de tipo topic recibe publicaciones | `cmd.topic` y sus tres bindings existen, pero ningún código publica ahí | Topología muerta |

**Observación.** La guía construye la topología en una clase `RabbitMQConfig` con `@Bean`, y ese es
el patrón que AndesStay no sigue. La consecuencia no es solo de estilo: si el archivo de
definiciones no se cargó, nada se autorrepara. El publicador no detecta el exchange ausente, porque
no hay publisher confirms, y los consumidores fallan con `NOT_FOUND` sobre colas inexistentes.

---

## 4. Validación contra la guía 2.2.1 — Pub/sub, acknowledgements y durabilidad

| Concepto de la guía | Estado en AndesStay | Veredicto |
|---|---|---|
| Ack del consumidor explícito, nunca auto-ack del protocolo | `acknowledge-mode: manual` y `ackMode = "MANUAL"`, con `basicAck` en los tres consumidores | Cumple |
| Nack o reject explícito | `basicNack(deliveryTag, false, false)` en los tres | Cumple |
| Publisher confirms (canal en modo confirm) | Ausente. Sin `publisher-confirm-type`, sin `ConfirmCallback`, sin `ReturnsCallback`, sin `mandatory` | Falta |
| Durabilidad del exchange | `durable: true` en los tres | Cumple |
| Durabilidad de la cola | `durable: true` en las seis | Cumple |
| Persistencia del mensaje (`delivery_mode = 2`) | Es el valor por omisión de Spring AMQP, pero no está declarado en ninguna parte | Implícito |
| Fanout para difusión | No hay exchange fanout. El caso resuelve el enrutamiento con `direct` y `topic` | No aplica |
| Colas temporales y exclusivas | No se usan. Las seis colas son nombradas y durables, que es lo correcto para comandos | No aplica |

**Sobre la durabilidad.** La guía insiste en que la tríada tiene que estar completa: exchange
durable, cola durable y mensaje persistente. Las dos primeras están explícitas; la tercera depende
de un valor por omisión de la librería. Conviene declararla, para que el contrato no dependa de un
comportamiento implícito.

**Sobre los publisher confirms.** Es la pieza que falta para cerrar la cadena de garantías. Hoy la
publicación es «dispara y olvida» desde el punto de vista del broker: un mensaje con una routing key
sin binding se descarta en silencio y el servicio que lo publicó nunca se entera.

---

## 5. Validación contra la guía 2.2.3 — DLX/DLQ, retención y alertas

| Concepto de la guía | Estado en AndesStay | Veredicto |
|---|---|---|
| `x-dead-letter-exchange` en la cola principal | `rabbitmq-definitions.json:11,16,21` | Cumple |
| `x-dead-letter-routing-key` | Presente, con valores `email.dead`, `housekeeping.dead`, `voucher.dead` | El contrato documenta otro valor |
| `x-message-ttl` en la cola principal | Ausente | Falta |
| `x-max-length` | Ausente | Falta |
| TTL de retención en la DLQ (24 h en la guía) | Ausente | Falta |
| Exchange de dead letter durable | `cmd.dead.dlx`, durable | Cumple |
| DLQ sin dead letter propio, como final del camino | `"arguments": {}` en las tres | Cumple |
| `retry.enabled` con backoff exponencial | Configurado en `ms-andesstay-notify/src/main/resources/application.yml:17-21`, pero **inerte** | **Falla** |
| `max-interval` del backoff | Ausente. La guía usa 10 000 ms | Falta |
| `prefetch: 1` (fair dispatch) | Ausente. Queda en el valor por omisión de 250 mensajes sin confirmar | Falta |
| Consumidor de la DLQ para monitoreo | Ausente. Los mensajes muertos no se observan | Falta |
| Healthcheck del broker en el compose | `infra/mq/compose.yml:33-37,59-63` | Cumple |
| Endpoint de estado del flujo | No existe. La guía expone `GET /api/orders/status` | Falta |
| Métricas y alertas de tasa de DLQ | Documentadas en `infra/docs/contracts/events/rabbit.md:146-158`, pero el `pom.xml` de notify no trae Actuator | **Falla** |

---

## 6. El hallazgo central: el reintento no se ejecuta

### Qué pasa

Los tres consumidores envuelven todo su cuerpo en un `try` con un `catch (Exception e)` que llama a
`basicNack(deliveryTag, false, false)`. En `EmailConsumer.java:60-64`:

    } catch (Exception e) {
        log.error("[Email] Error procesando mensaje traceId={}: {}", traceId, e.getMessage());
        // NACK sin requeue -> va a DLQ
        channel.basicNack(deliveryTag, false, false);
    }

El `RetryOperationsInterceptor` de Spring solo reintenta cuando el método del listener **lanza**.
Como la excepción se captura dentro del método, nunca escapa: para el contenedor, el método terminó
bien. El bloque de `retry` del `application.yml` no tiene efecto alguno.

### Consecuencia medible

El primer fallo manda el mensaje a la DLQ. No hay tres intentos y no hay backoff. El comentario de
`EmailConsumer.java:31` («En caso de error reintenta hasta 3 veces») describe algo que el código no
hace, y el criterio de cierre de la fase 6 en `CHECKLIST.md:333` no se cumple.

### Por qué no basta con quitar el try/catch

Hay un segundo factor que suele pasarse por alto. Con `AcknowledgeMode.MANUAL` el contenedor **no
envía ack ni nack por su cuenta**: es responsabilidad exclusiva del listener. Si el listener lanza
bajo modo manual, el mensaje queda sin confirmar hasta que el canal se cierra, y entonces se
**reencola**, no se envía a la DLQ. Quitar el try/catch y conservar el modo manual cambiaría el
defecto actual por otro peor: un bucle de reentrega en lugar de un viaje directo a la DLQ.

La corrección necesita los dos cambios a la vez, y ambos consisten en **borrar**, no en agregar:

1. Quitar `ackMode = "MANUAL"` de las tres anotaciones `@RabbitListener`.
2. Quitar `acknowledge-mode: manual` del `application.yml`.
3. Quitar el `try`/`catch` y el parámetro `Channel channel`, y dejar propagar la excepción.
4. Conservar el bloque `retry`, agregándole `max-interval` y `prefetch: 1`.

Con eso, el modo pasa al `AUTO` por omisión: el contenedor confirma al retornar sin error y rechaza
al propagarse la excepción. Agotados los intentos, el `RejectAndDontRequeueRecoverer` lanza
`AmqpRejectAndDontRequeueException`, el contenedor hace `basic.reject(requeue=false)` y el broker
hace dead lettering por el `x-dead-letter-exchange` de la cola.

### Sobre el nombre «auto»

El `AUTO` de Spring **no** es el auto-ack del protocolo AMQP. El auto-ack del protocolo, el que
pierde mensajes si el consumidor muere, corresponde a `AcknowledgeMode.NONE`. El `AUTO` de Spring
sigue emitiendo un `basic.ack` real después de que el método retorna. La línea del contrato que
dice «ACK manual, nunca automático» (`rabbit.md:133`) apunta a no usar `NONE`, y eso se mantiene.

### Nota sobre la guía

La guía 2.2.3 arrastra la misma confusión: su tabla de «Conceptos implementados» atribuye los tres
reintentos al `application.yml`, aunque su propio `OrderConsumer` también captura la excepción y
hace `basicNack` dentro del `catch`. El código de AndesStay reprodujo ese patrón con fidelidad. La
corrección se documenta aquí para que quede constancia del motivo.

---

## 7. Divergencias frente al contrato propio del proyecto

Independientes de las guías, pero del mismo bloque de trabajo.

| # | Divergencia | Dónde |
|---|---|---|
| 1 | El `type` emitido es `EMAIL_NOTIFICATION`, `HOUSEKEEPING_TICKET` y `VOUCHER_REQUEST`, en vez de `email.send`, `housekeeping.ticket` y `voucher.gen` | `NotificationPublisher.java:51,68,85` frente a `rabbit.md:50,77,98` |
| 2 | El envelope omite los campos obligatorios `source` y `actor` | `NotificationPublisher.java:93-102` frente a `envelope.md:27-38` |
| 3 | El `correlationId` se genera aleatorio en cada mensaje, cuando debe ser estable durante todo el ciclo de vida de la reserva | `NotificationPublisher.java:99` frente a `envelope.md:46-47` |
| 4 | Los payloads no corresponden a los contratados: `to`, `subject` y `body` en vez de `plantilla`, `destinatario` y `datos` | `NotificationPublisher.java:51-55` frente a `rabbit.md:55-67` |
| 5 | No se publica `email.send` al cancelar una reserva | `ReservationService.java:110-116` frente a `rabbit.md:127` |
| 6 | Sin idempotencia por `eventId` en ningún consumidor de RabbitMQ | `envelope.md:49-59` |
| 7 | `rabbitmq2` no monta `rabbitmq-definitions.json`, aunque su `rabbitmq.conf` lo referencia en `management.load_definitions`. El nodo 2 arranca con un error de archivo inexistente | `infra/mq/compose.yml:51-53` frente a `rabbitmq.conf:4` |
| 8 | El nodo 2 declara descubrimiento por `classic_config` en `rabbitmq.conf:5-7` y además ejecuta un `join_cluster` imperativo con un `sleep 15` fijo. Dos mecanismos redundantes y una carrera en una instancia burstable | `infra/mq/compose.yml:63-70` |
| 9 | Colas clásicas en un clúster de dos nodos sin política de espejado: si cae el nodo dueño, sus colas quedan inaccesibles | `rabbitmq-definitions.json`, sin bloque `policies` |
| 10 | Los `.env.example` y los README piden `RABBITMQ_PASSWORD`, pero los `application.yml` leen `RABBITMQ_PASS`. Quien ejecute notify de forma autónoma se conecta sin contraseña | `notify/.env.example:7` frente a `notify/application.yml:12` |
| 11 | `NOTIFY_MAX_ATTEMPTS` y `NOTIFY_BACKOFF_MS` están documentadas pero no se referencian en ningún YAML ni en ningún `.java` | `rabbit.md:137-138` |
| 12 | El serializador es asimétrico: reservations publica con `Jackson2JsonMessageConverter` y notify deserializa a mano con `objectMapper.readValue(message.getBody(), Map.class)`, ignorando `content_type` | `RabbitMQConfig.java:13-15` frente a `EmailConsumer.java:39` |
| 13 | `HousekeepingConsumer:44` y `VoucherConsumer:43` son `TODO`: registran en el log pero no generan ticket ni PDF | — |
| 14 | `ms-andesstay-reservations` configura `listener.simple.acknowledge-mode: manual` sin tener ningún `@RabbitListener`, y declara `exchange-topic` y las tres `queue.*` sin que ningún código las lea | `reservations/application.yml:27-29,69-75` |

---

## 8. Plan de corrección

### 8.1 Topología declarada en código

Se crea `ms-andesstay-notify/src/main/java/cl/andesstay/notify/config/RabbitMQConfig.java` con el
patrón de las guías 2.1.3 y 2.2.3: los tres exchanges, las tres colas de trabajo con
`QueueBuilder.durable(...)` y sus argumentos, las tres DLQ con TTL de retención y los nueve
bindings.

Los **tres exchanges** se declaran además en `ms-andesstay-reservations`. Si la topología viviera
solo en notify, un arranque de reservations con notify caído publicaría contra un exchange
inexistente: `convertAndSend` falla a nivel de canal de forma asíncrona, el llamador HTTP recibe su
`201` y el mensaje se pierde sin excepción en ninguna parte. Declarar un exchange dos veces con el
mismo tipo y la misma durabilidad es idempotente; declarar una cola con argumentos distintos no lo
es. Por eso las colas y los bindings quedan en un solo sitio.

`rabbitmq-definitions.json` se reduce a `vhosts`, `users`, `permissions` y la política de espejado.
El `management.load_definitions` de `rabbitmq.conf:4` se retira.

> **Precondición obligatoria.** Las colas ya existen en el broker local con otros argumentos. Si un
> `@Bean Queue` declara aunque sea un argumento distinto, el broker responde
> `PRECONDITION_FAILED - inequivalent arg`, cierra el canal y **todos** los listener containers
> fallan al arrancar: notify queda sano a nivel HTTP y consumiendo cero. Hay que borrar las colas
> antes, o partir de un volumen limpio. Ver la sección 9.1.

### 8.2 Políticas de retención

| Argumento | Cola de trabajo | DLQ |
|---|---|---|
| `x-message-ttl` | 300 000 ms (5 min): una notificación vieja no sirve | 86 400 000 ms (24 h) para análisis |
| `x-max-length` | 1 000 mensajes | — |
| `x-dead-letter-exchange` | `cmd.dead.dlx` | — |
| `x-dead-letter-routing-key` | `<flujo>.dead` | — |

Los valores quedan externalizados por propiedad, no como literales en el código.

### 8.3 Reintentos efectivos

```yaml
spring:
  rabbitmq:
    listener:
      simple:
        prefetch: ${NOTIFY_PREFETCH:1}
        default-requeue-rejected: false
        retry:
          enabled: true
          max-attempts: ${NOTIFY_MAX_ATTEMPTS:3}
          initial-interval: ${NOTIFY_BACKOFF_MS:1000}
          max-interval: 10000
          multiplier: 2.0
```

Sin línea de `acknowledge-mode`: el valor por omisión es `AUTO`, que es el que se busca. Y en los
consumidores:

- **Error transitorio** (servidor de correo caído, timeout): se lanza la excepción. El interceptor
  reintenta con backoff y, al agotar los intentos, el contenedor rechaza y el mensaje viaja a su
  DLQ.
- **Error permanente** (destinatario inválido, plantilla inexistente, payload ilegible): se envuelve
  en `AmqpRejectAndDontRequeueException`, que va a la DLQ sin gastar reintentos. Es la distinción
  que exige `rabbit.md:140-144`.

El `prefetch: 1` no es decorativo: con tres intentos y multiplicador 2, el hilo del consumidor
duerme hasta 6 s por mensaje. Sin fair dispatch, un solo consumidor retiene una ventana de 250
mensajes sin confirmar y el orden de la demostración deja de ser determinista.

### 8.4 Idempotencia, observación de la DLQ y métricas

| Pieza | Qué resuelve |
|---|---|
| `ProcessedEventCache` con `eventId` y expiración | La entrega «al menos una vez» del broker. Un duplicado se confirma sin reejecutar el efecto |
| `DeadLetterConsumer` con tres `@RabbitListener` | Registra el mensaje y la cabecera `x-death` con el motivo real del descarte. Equivale al `processDLQ` de la guía 2.2.3 |
| `spring-boot-starter-actuator` en el `pom.xml` de notify | Habilita las métricas que el contrato ya promete, y permite darle healthcheck en el compose |
| Contadores `notify.messages.processed`, `.retried`, `.dlq` y el gauge `notify.dlq.rate` | Ítem 6.9 del checklist. La tasa de DLQ es el indicador de salud del sistema de notificaciones |
| `GET /api/v1/notify/status` | Profundidad de las seis colas vía `RabbitAdmin.getQueueInfo`. No se publica en el gateway |

### 8.5 Publisher confirms

```yaml
spring:
  rabbitmq:
    publisher-confirm-type: correlated
    publisher-returns: true
    template:
      mandatory: true
```

Con un `ReturnsCallback` que registre el mensaje no enrutable. Sin esto, un binding mal escrito
pierde mensajes en silencio.

### 8.6 Alta disponibilidad en un clúster de dos nodos

Se agrega una política que espeje las colas que coincidan con `^q\.cmd\.`, con `ha-mode: all` y
`ha-sync-mode: automatic`.

Dos aclaraciones importantes:

- El espejado de colas clásicas está **deprecado** desde RabbitMQ 3.13, la versión del compose, y
  **eliminado** en la serie 4.x. La alternativa moderna son las colas quorum.
- Las colas quorum **no aportan nada con dos nodos**: requieren mayoría, y la mayoría de dos es
  dos, de modo que perder un nodo deja la cola igual de indisponible. Con el clúster de dos nodos
  que pide el caso, el espejado clásico es la única opción que da tolerancia real a la caída de un
  nodo. Se elige por eso, no por descuido.

### 8.7 La bandera de eventos hay que partirla en dos

`andesstay.events.enabled` (`reservations/application.yml:63-64`) controla **a la vez** el
publicador de RabbitMQ (`NotificationPublisher:31`) y el de Kafka (`ReservationEventPublisher:32`).
Ponerla en `true` para tener RabbitMQ vuelve a armar el productor de Kafka, cuyo
`max.block.ms: 2000` (`application.yml:43`) añade hasta 2 s a cada escritura de reserva y llena el
log de errores de broker inalcanzable, con Kafka explícitamente fuera de alcance.

Se parte en `andesstay.events.rabbit.enabled` y `andesstay.events.kafka.enabled`, esta última por
omisión en `false`.

### 8.8 Despliegue

El flujo pasa a funcionar en la nube sobre una instancia `ec2-mq` de tipo `t3.micro` dedicada, con
`rabbitmq1`, `rabbitmq2` y `ms-andesstay-notify`. Cuatro detalles que no son negociables en 1 GB de
RAM:

1. **El swapfile de 2 GB que `provision.sh:76-93` ya crea se conserva.** Es la diferencia entre un
   broker que funciona y el OOM killer.
2. **La imagen de notify no se construye en la `t3.micro`.** Un `mvn package` de Spring Boot supera
   el gigabyte de pico: o muere, o pasa veinte minutos en swap. Se construye en `ec2-apps`, que ya
   tiene el toolchain, y se mueve con `docker save | ssh ... docker load`.
3. **La UI de gestión se publica en loopback** (`127.0.0.1:15672:15672`) y el 15672 **no** se abre
   en el grupo de seguridad. Un puerto publicado por Docker omite `ufw`, porque la regla entra por
   la cadena `DOCKER-USER`, así que la única protección real sería el grupo de seguridad. Con el
   bind a loopback, el túnel SSH queda como vía única y no hay regla que olvidar cerrar.
4. **`MANAGEMENT_HEALTH_RABBIT_ENABLED` se queda en `false` en `ec2-apps`.** Con el broker en otra
   instancia, cualquier parpadeo volvería `/actuator/health` un `503`, el healthcheck de
   `compose.yml:101` fallaría y el `restart: unless-stopped` convertiría un reinicio del broker en
   un bucle de reinicios de reservations. El indicador de Rabbit se habilita solo en notify, donde
   no alcanzar el broker sí significa que el servicio no sirve para nada.

El grupo de seguridad de `ec2-mq` abre el 22 a la IP del operador — sin él no se puede aprovisionar
ni abrir el túnel — y el 5672 solo a `ec2-apps`.

**Orden de despliegue.** Broker arriba en `ec2-mq`, luego la imagen de notify, y **solo entonces**
`ANDESSTAY_EVENTS_RABBIT_ENABLED=true` en `ec2-apps`. Levantar la bandera antes de que el 5672
responda hace que `convertAndSend` lance sincrónicamente y **cada POST de reserva devuelva 500**: el
javadoc de `NotificationPublisher.java:22-27` lo dice con todas las letras.

---

## 9. Procedimiento de prueba

### 9.1 Preparación

Las colas ya existen con otros argumentos, así que hay que borrarlas antes del primer arranque con
la topología nueva. Lo más limpio es partir de un volumen vacío:

```bash
docker compose -f infra/mq/compose.yml down -v
```

Si se prefiere conservar el volumen, se borran las seis colas una a una:

```bash
for q in q.cmd.email q.cmd.housekeeping q.cmd.voucher q.cmd.email.dlq q.cmd.housekeeping.dlq q.cmd.voucher.dlq; do docker exec andesstay-rabbitmq1 rabbitmqctl -p andesstay delete_queue "$q"; done
```

Luego se levanta el entorno local:

```bash
docker compose --env-file .env -f infra/mq/compose.yml up -d
```

La UI de gestión queda en `http://localhost:15672`. En `ec2-mq` se alcanza por túnel:

```bash
ssh -i ~/.ssh/andesstay-key.pem -L 15672:localhost:15672 ubuntu@<ip-publica-de-ec2-mq>
```

### 9.2 Casos de prueba

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | Confirmar una reserva | Aparecen y se consumen mensajes en `q.cmd.email` y `q.cmd.voucher` |
| 2 | Publicar un cuerpo que no sea JSON | Llega a `q.cmd.email.dlq` tras los tres intentos, y la cabecera `x-death` indica `rejected` |
| 3 | Apagar el servidor de correo y publicar | Tres intentos con backoff de 1 s, 2 s y 4 s visibles en el log, y solo entonces la DLQ. En la UI, `deliver_get` de `q.cmd.email` llega a 3 y `messages` de `q.cmd.email.dlq` llega a 1 |
| 4 | Publicar un mensaje con plantilla inexistente | Va a la DLQ **sin** gastar reintentos, por `AmqpRejectAndDontRequeueException` |
| 5 | Publicar dos veces el mismo `eventId` | El efecto se ejecuta una sola vez; el duplicado se confirma en silencio |
| 6 | Detener notify, publicar y reiniciar | Los mensajes se acumulan en la cola y se procesan al volver |
| 7 | Reiniciar el broker con mensajes encolados | Los mensajes sobreviven: durabilidad de la cola más persistencia del mensaje |
| 8 | Publicar con una routing key sin binding | El `ReturnsCallback` lo registra en el log de reservations |
| 9 | `GET /actuator/metrics/notify.messages.dlq` | Devuelve el contador, etiquetado por cola |
| 10 | `GET /api/v1/notify/status` | Devuelve la profundidad de las seis colas |
| 11 | Apagar `rabbitmq1` y publicar contra `rabbitmq2` | Las colas siguen disponibles, por la política de espejado |
| 12 | Dejar un mensaje más de 5 min sin consumir | Expira por `x-message-ttl` y va a la DLQ, con `x-death` indicando `expired` |
| 13 | Cancelar una reserva | Se publica `email.send` con plantilla `RESERVA_CANCELADA` |

El caso 3 es el criterio de cierre de la fase 6. El fallo deliberado del caso 2 es el más barato de
montar: el `objectMapper.readValue` de `EmailConsumer.java:40` lanza antes de cualquier lógica de
negocio, recorre el mismo camino de reintentos y DLQ, y no necesita código de producción ni bandera
de prueba.

Los dos conviene dejarlos además como test automatizado: `spring-rabbit-test` ya está en el
`pom.xml:25` de notify.

### 9.3 Evidencia a capturar

Las capturas van a `infra/docs/evidencias/rabbitmq/`.

| Archivo | Contenido |
|---|---|
| `01-exchanges.png` | Pestaña Exchanges con los tres exchanges y sus tipos |
| `02-colas.png` | Pestaña Queues con las seis colas, sus argumentos y su política |
| `03-bindings.png` | Bindings de `cmd.direct`, `cmd.topic` y `cmd.dead.dlx` |
| `04-flujo-ok.png` | Gráfico de mensajes entrando y saliendo al confirmar una reserva |
| `05-reintentos.png` | Log del consumidor con los tres intentos y el backoff |
| `06-dlq.png` | `q.cmd.email.dlq` con el mensaje y su cabecera `x-death` |
| `07-metricas.png` | Respuesta de `/actuator/metrics/notify.dlq.rate` |
| `08-ha.png` | Las colas sincronizadas en los dos nodos |

---

## 10. Trazabilidad con el checklist

| Ítem | Descripción | Estado tras este plan |
|---|---|---|
| 6.2 | Exchanges `cmd.direct`, `cmd.topic`, `cmd.dead.dlx` | Ya existían; pasan a declararse en código |
| 6.3 | Colas y DLQ | Ya existían; se les agregan TTL y `x-max-length` |
| 6.7 | `ms-andesstay-notify` consume las tres colas con ACK/NACK explícito | Ya implementado; se corrige el modo de acknowledge |
| 6.8 | Idempotencia por `eventId`, reintentos con backoff y envío a DLQ | Pendiente; es el núcleo de este plan |
| 6.9 | Métrica de tasa de DLQ | Pendiente; requiere Actuator en notify |
| 8.3 | Diagrama de topología de RabbitMQ | Se cubre con las capturas de la sección 9.3 |
