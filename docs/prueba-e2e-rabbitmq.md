# Prueba de punta a punta de RabbitMQ

Guía para comprobar, en un computador propio y con Docker, que la mensajería de AndesStay funciona
completa:

1. el **administrador** (`ms-andesstay-rabbitadmin`) crea y elimina colas, exchanges y bindings;
2. **`ms-andesstay-reservations` publica** un mensaje cuando cambia una reserva;
3. **`ms-andesstay-notify` lo consume** y envía el correo;
4. un mensaje que falla **termina en su DLQ** y queda **registrado en los logs**;
5. todo se puede **ver en la consola de RabbitMQ**.

Está escrita para alguien del equipo que no participó en la configuración. Cada comando va
precedido de lo que hace y seguido del resultado esperado.

---

## Qué está verificado y qué no

La guía se ejecutó completa el **2026-10-11** en Windows 11 con Docker Desktop 29.5.3. Cada paso
lleva una de estas marcas:

| Marca | Significado |
|---|---|
| ✅ **Verificado** | Se ejecutó y el resultado mostrado es el real |
| 🔑 **Verificado con token local** | Se ejecutó con un JWT de prueba firmado localmente (ver abajo). **Falta repetirlo con un token real de Entra ID** |
| ⚠️ **No verificado** | No se pudo ejecutar; el resultado esperado sale del código |

**Por qué un token local.** Las llamadas a `rabbitadmin`, `catalog` y `reservations` exigen un JWT
de Entra ID, y obtener uno requiere iniciar sesión en el frontend con un usuario real. Para la
verificación se usó un JWT con el **mismo `iss`, `aud`, `roles` y `scp`** que emite Entra ID, pero
firmado con una llave RSA generada para la prueba, y se apuntó la validación a esa llave mediante
una variable de entorno pasada solo en esa ejecución. Eso comprueba de verdad la validación de
firma, emisor, audiencia y rol en los tres servicios; lo que **no** comprueba es que Entra ID emita
el token como se espera. Ni la llave ni esa variable quedaron en el repositorio; las llaves se
borraron al terminar. **Para la prueba con token real basta seguir esta guía tal cual**: no usa nada
de ese montaje.

---

## Requisitos

| Requisito | Notas |
|---|---|
| Docker Desktop con Compose v2 | Con al menos 4 GB asignados. Los nueve contenedores usan en conjunto unos 3 GB |
| Git Bash | Los comandos son de bash. En PowerShell cambian las comillas y las variables |
| Los repositorios clonados como carpetas hermanas | `infra`, `ms-andesstay-notify`, `ms-andesstay-rabbitadmin`, `ms-andesstay-reservations`, `ms-andesstay-catalog`. Ver `deploy/scripts/clonar-repos.sh` |
| Una cuenta de Entra ID con el rol **Admin** | Para el token. Ver el paso 3 |
| Node.js | Solo para revisar el token en el paso 3; es opcional |

**Todos los comandos se ejecutan desde la carpeta raíz** que contiene los repositorios
(`AndesStay/`), no desde dentro de `infra`.

> **Ojo con las tildes en Windows.** En Git Bash, un `curl -d '…'` con `ó` o `ñ` se envía en la
> codificación de la consola y no en UTF-8, y el servicio responde `400 Invalid UTF-8 middle byte`.
> Pasó durante la verificación. Los ejemplos de esta guía usan solo ASCII; si se necesitan tildes,
> poner el JSON en un archivo guardado en UTF-8 y enviarlo con `--data-binary @archivo.json`.

---

## Paso 0. Preparar las variables

**Qué hace.** Crea `infra/.env` a partir de la plantilla. Ese archivo **no se versiona** (está en el
`.gitignore`).

```bash
cp infra/.env.example infra/.env
```

Abrirlo y completar, como mínimo:

| Variable | Valor para esta prueba |
|---|---|
| `RABBITMQ_USER` | `andesstay` |
| `RABBITMQ_PASSWORD` | Cualquier contraseña |
| `RABBITMQ_ERLANG_COOKIE` | Cualquier texto largo; lo comparten los dos nodos |
| `MYSQL_ROOT_PASSWORD`, `MYSQL_APP_PASSWORD` | Cualquier contraseña |
| `MYSQL_DATABASE`, `MYSQL_APP_USER` | `andesstay` (dejar los de la plantilla) |
| `MAIL_HOST` | `mailpit` |
| `MAIL_PORT` | `1025` |
| `MAIL_USER`, `MAIL_PASS` | Cualquier texto **no vacío**: notify siempre se autentica y Mailpit acepta cualquiera |

`AZURE_TENANT_ID` y `AZURE_CLIENT_ID` pueden quedar vacíos: los compose usan los del sistema por
omisión. Las variables de Oracle no se usan.

Para no repetir el comando largo, se define un alias de sesión:

```bash
DC="docker compose --env-file infra/.env -f infra/mq/compose.yml -f infra/mq/compose.e2e.yml"
```

`infra/mq/compose.yml` trae RabbitMQ (dos nodos), notify y el administrador. El overlay
`infra/mq/compose.e2e.yml` agrega MySQL, catalog, reservations y **Mailpit**, un servidor de correo
de prueba con bandeja web. El overlay es **solo para pruebas locales**; el despliegue en AWS usa
`infra/deploy/compose.yml`.

> No usar `infra/apps/compose.yml` para esta prueba: está desactualizado (apunta los servicios a
> Oracle, pero solo tienen el driver de MySQL) y exige la red de Kafka.

---

## Paso 1. Levantar el entorno — ✅ Verificado

**Qué hace.** Construye las imágenes de notify, rabbitadmin, catalog y reservations (compila cada
uno con Maven dentro de su `Dockerfile`), descarga las de RabbitMQ, MySQL y Mailpit, y arranca los
nueve contenedores en orden de dependencia.

```bash
$DC up -d --build
```

**Cuánto tarda.** La primera vez, entre 5 y 10 minutos. Unos 3 de ellos son de RabbitMQ: en el
primer arranque, con el volumen vacío, `rabbitmq1` intenta durante unos tres minutos encontrar a
`rabbitmq2` antes de arrancar solo, y `rabbitmq2` no se crea hasta que `rabbitmq1` está listo. Es
esperable; en los arranques siguientes no pasa.

**Comprobar** que los nueve estén sanos:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Resultado esperado (`rabbitmq-init` no aparece: termina con código 0 después de aplicar la política):

```
NAMES                        STATUS
andesstay-rabbitmq2          Up 37 seconds (healthy)
andesstay-rabbitmq1          Up 59 seconds (healthy)
andesstay-e2e-reservations   Up 25 seconds (healthy)
andesstay-rabbitadmin        Up 36 seconds (healthy)
andesstay-notify             Up 37 seconds (healthy)
andesstay-e2e-catalog        Up 4 minutes (healthy)
andesstay-e2e-mysql          Up 5 minutes (healthy)
andesstay-e2e-mailpit        Up 5 minutes (healthy)
```

Si `up` termina con `dependency failed to start: container andesstay-rabbitmq1 is unhealthy`, basta
volver a ejecutar `$DC up -d`: el nodo sigue arrancando y la segunda vez lo encuentra listo.

| Dirección | Qué es | Usuario |
|---|---|---|
| `http://localhost:15672` | Consola de RabbitMQ | `RABBITMQ_USER` / `RABBITMQ_PASSWORD` |
| `http://localhost:8025` | Bandeja de Mailpit | Sin login |
| `http://localhost:8086` | Administrador | JWT con rol Admin |
| `http://localhost:8081` | Reservations | JWT |
| `http://localhost:8082` | Catalog | JWT |

Todos los puertos se publican solo en `127.0.0.1`: no son alcanzables desde otro equipo.

---

## Paso 2. Revisar la topología en la consola — ✅ Verificado

**Qué se comprueba.** Que el clúster tiene dos nodos y que notify declaró al arrancar los 3
exchanges, las 6 colas y los 9 bindings del contrato (`docs/contracts/events/rabbit.md`).

Entrar a `http://localhost:15672` con `RABBITMQ_USER` y `RABBITMQ_PASSWORD`, y revisar:

| Pestaña | Qué se debe ver |
|---|---|
| **Overview → Nodes** | `rabbit@rabbitmq1` y `rabbit@rabbitmq2`, los dos en ejecución |
| **Exchanges** (vhost `andesstay`) | `cmd.direct` (direct), `cmd.topic` (topic) y `cmd.dead.dlx` (direct), los tres durables |
| **Queues** | Las 6 colas, cada una con **1 consumidor**. Las tres de trabajo con `DLX`, `TTL` y `Lim`, y la política `ha-colas-cmd` |
| **Queues → `q.cmd.email` → Bindings** | Desde `cmd.direct` con `email.send` y desde `cmd.topic` con `email.*` |
| **Admin → Policies** | `ha-colas-cmd`, patrón `^q\.cmd\.`, `ha-mode: all` |

> Los **valores** de esta tabla se verificaron por línea de comandos y por la API de gestión, que
> es la misma fuente que alimenta la consola. La vista web en sí no se revisó visualmente: los
> nombres exactos de columnas o pestañas pueden variar con la versión de RabbitMQ.

**Lo mismo por línea de comandos**, útil para una captura de evidencia:

```bash
# Nodos del clúster
docker exec andesstay-rabbitmq1 rabbitmqctl -q cluster_status | grep -A3 "Running Nodes"
# Colas con sus argumentos y consumidores
docker exec andesstay-rabbitmq1 rabbitmqctl -q -p andesstay list_queues name messages consumers arguments
# Bindings del sistema
docker exec andesstay-rabbitmq1 rabbitmqctl -q -p andesstay list_bindings source_name destination_name routing_key | grep -E "^cmd"
```

Resultado obtenido en la verificación:

```
name                    messages consumers arguments
q.cmd.voucher.dlq       0        1         [{"x-message-ttl",86400000}]
q.cmd.housekeeping.dlq  0        1         [{"x-message-ttl",86400000}]
q.cmd.email             0        1         [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","email.dead"}]
q.cmd.email.dlq         0        1         [{"x-message-ttl",86400000}]
q.cmd.housekeeping      0        1         [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","housekeeping.dead"}]
q.cmd.voucher           0        1         [{"x-dead-letter-exchange","cmd.dead.dlx"},{"x-message-ttl",300000},{"x-max-length",1000},{"x-dead-letter-routing-key","voucher.dead"}]

cmd.dead.dlx  q.cmd.email.dlq         email.dead
cmd.dead.dlx  q.cmd.housekeeping.dlq  housekeeping.dead
cmd.dead.dlx  q.cmd.voucher.dlq       voucher.dead
cmd.direct    q.cmd.email             email.send
cmd.direct    q.cmd.housekeeping      housekeeping.ticket
cmd.direct    q.cmd.voucher           voucher.gen
cmd.topic     q.cmd.email             email.*
cmd.topic     q.cmd.housekeeping      housekeeping.#
cmd.topic     q.cmd.voucher           voucher.*
```

Que cada DLQ tenga **un consumidor** es correcto: es `DeadLetterConsumer` de notify, que registra en
el log cada mensaje que llega. Se ve en el paso 6.

---

## Paso 3. Obtener un token de Entra ID — 🔑 pendiente con token real

**Qué se necesita.** Un *access token* de la App Registration de AndesStay con el rol **Admin**. Se
obtiene iniciando sesión en el frontend, como se explica paso a paso en el README de
`ms-andesstay-rabbitadmin`, sección *Obtener un token de Entra ID*. En resumen:

1. Iniciar sesión en el frontend con una cuenta que tenga el rol **Admin** asignado.
2. F12 → **Application → Local Storage** → la clave que contiene `accesstoken` y
   `api://704a544f-3d92-44f5-aef9-8559574cff34/AndesStay.Access` → copiar el campo `secret`.
3. Guardarlo en una variable de la sesión, junto con las bases de las URL:

```bash
export TOKEN="<el token copiado>"
export API=http://localhost:8086/api/v1/admin
export H="Content-Type: application/json"
```

El token dura alrededor de una hora. **El mismo token sirve para los pasos 4, 5 y 6**: los tres
servicios validan el mismo emisor y la misma audiencia.

---

## Paso 4. Administrar colas con el administrador — 🔑 Verificado con token local

Todo lo que se crea aquí usa nombres `q.demo.*` y `ex.demo*`, ajenos al sistema, y se elimina al
final del paso.

### 4.1 Seguridad

**Qué hace.** Llama sin token. Debe responder `401` con un cuerpo JSON.

```bash
curl -s -w "\n[HTTP %{http_code}]\n" $API/queues
```

```
{"error":"TOKEN_INVALIDO","mensaje":"Falta el token, o es inválido, está vencido o es de un emisor desconocido","timestamp":"…"}
[HTTP 401]
```

Con el token de un usuario que **no** es Admin (por ejemplo Operador), la respuesta es `403` con
`"error":"ROL_INSUFICIENTE"`. **Verificado con token local.**

### 4.2 Crear un exchange, dos colas y sus bindings

**Qué hace.** Crea un exchange `topic` para los mensajes y un `direct` que hará de dead letter
exchange; luego una cola de trabajo que manda sus mensajes rechazados o vencidos a ese exchange, la
cola que los recibe, y los dos bindings.

```bash
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo","tipo":"topic"}'
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo.dlx","tipo":"direct"}'
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"nombre":"q.demo.email","deadLetterExchange":"ex.demo.dlx","deadLetterRoutingKey":"demo.dead","ttlMensajesMs":60000,"maxMensajes":1000}'
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"q.demo.email.dlq"}'
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"exchange":"ex.demo","destino":"q.demo.email","routingKey":"demo.#"}'
curl -s -X POST $API/bindings -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"exchange":"ex.demo.dlx","destino":"q.demo.email.dlq","routingKey":"demo.dead"}'
```

Resultado esperado: cada uno responde `201`. La cola, por ejemplo:

```json
{"nombre":"q.demo.email","durable":true,"autoEliminar":false,
 "argumentos":{"x-dead-letter-exchange":"ex.demo.dlx","x-dead-letter-routing-key":"demo.dead","x-max-length":1000,"x-message-ttl":60000},
 "mensajes":0,"consumidores":0}
```

**En la consola:** *Queues* muestra `q.demo.email` con `DLX`, `DLK`, `TTL` y `Lim`, y en su detalle,
el binding desde `ex.demo` con `demo.#`.

### 4.3 Conflictos que protegen datos

**Qué hace.** Publica un mensaje en la cola desde la API de gestión de RabbitMQ (lo mismo que el
botón *Publish message* de la consola) y luego intenta borrarla.

```bash
source infra/.env   # para RABBITMQ_USER y RABBITMQ_PASSWORD
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "$H" -X POST \
  -d '{"properties":{},"routing_key":"demo.prueba","payload":"hola","payload_encoding":"string"}' \
  http://localhost:15672/api/exchanges/andesstay/ex.demo/publish
curl -s -X DELETE $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN"
```

```
{"routed":true}
{"error":"RECURSO_EN_CONFLICTO","mensaje":"La cola 'q.demo.email' tiene 1 mensaje(s) que se perderían. Use forzar=true para eliminarla igual.",…}
```

Del mismo modo, `PUT` sobre una cola con mensajes y `DELETE` sobre un exchange con bindings
responden `409` y explican el motivo.

### 4.4 La topología del sistema está protegida

**Qué hace.** Intenta borrar una cola y un exchange del sistema, **con `forzar=true`**.

```bash
curl -s -X DELETE "$API/queues/q.cmd.email?forzar=true" -H "Authorization: Bearer $TOKEN"
curl -s -X DELETE "$API/exchanges/cmd.dead.dlx?forzar=true" -H "Authorization: Bearer $TOKEN"
```

```
{"error":"OPERACION_NO_PERMITIDA","mensaje":"La cola 'q.cmd.email' coincide con el patrón protegido 'q.cmd.*' (andesstay.rabbitadmin.protegidos.colas): forma parte de la topología de la que dependen otros microservicios y no se puede eliminar desde el administrador",…}
{"error":"OPERACION_NO_PERMITIDA","mensaje":"El exchange 'cmd.dead.dlx' coincide con el patrón protegido 'cmd.*' …",…}
```

Ambos `403`. También se verificó que crear un binding **hacia** `q.cmd.email` responde `403`, que
crear uno **desde** `cmd.topic` hacia una cola nueva responde `201`, y que eliminar este último
responde `403`, porque sale de un exchange protegido.

### 4.5 Validación de la entrada

**Qué hace.** Envía peticiones mal formadas. Todas responden `400` **sin tocar el broker** y con un
error por campo.

```bash
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"ttlMensajesMs":-1}'
curl -s -X POST $API/queues -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"q.demo.x","ttlMensajes":60000}'
curl -s -X POST $API/exchanges -H "Authorization: Bearer $TOKEN" -H "$H" -d '{"nombre":"ex.demo.x","tipo":"headers"}'
```

```
{"error":"SOLICITUD_INVALIDA","mensaje":"La solicitud tiene 2 errores de validación",…,"campos":[{"campo":"ttlMensajesMs","mensaje":"no puede ser negativo"},{"campo":"nombre","mensaje":"es obligatorio"}]}
{"error":"SOLICITUD_INVALIDA",…,"campos":[{"campo":"ttlMensajes","mensaje":"campo desconocido; los válidos son [autoEliminar, deadLetterRoutingKey, ttlMensajesMs, maxMensajes, nombre, durable, deadLetterExchange]"}]}
{"error":"SOLICITUD_INVALIDA",…,"campos":[{"campo":"tipo","mensaje":"debe ser direct, topic o fanout"}]}
```

Además, `{"nombre":"q.demo.x","deadLetterExchange":"ex.no.existe"}` responde `404` (no se crea una
cola con un dead letter exchange inexistente) y `{"nombre":"amq.mio","tipo":"direct"}` en
`/exchanges` responde `403` (nombre reservado de RabbitMQ). El catálogo completo de errores está en
el README del administrador.

### 4.6 Actualizar, eliminar y limpiar

**Qué hace.** Vacía la cola (la API de gestión de RabbitMQ, igual que *Purge* en la consola), la
actualiza cambiando su TTL, comprueba que conservó su binding, y elimina todo lo creado.

```bash
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -X DELETE http://localhost:15672/api/queues/andesstay/q.demo.email/contents
curl -s -X PUT $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"deadLetterExchange":"ex.demo.dlx","deadLetterRoutingKey":"demo.dead","ttlMensajesMs":120000,"maxMensajes":1000}'
curl -s $API/bindings -H "Authorization: Bearer $TOKEN" | grep -o '"exchange":"ex.demo"[^}]*'
curl -s -X DELETE "$API/bindings?exchange=ex.demo&destino=q.demo.email&tipoDestino=COLA&routingKey=demo.%23" -H "Authorization: Bearer $TOKEN" -w "%{http_code}\n"
curl -s -X DELETE $API/queues/q.demo.email -H "Authorization: Bearer $TOKEN" -w "%{http_code}\n"
curl -s -X DELETE $API/queues/q.demo.email.dlq -H "Authorization: Bearer $TOKEN" -w "%{http_code}\n"
curl -s -X DELETE $API/exchanges/ex.demo -H "Authorization: Bearer $TOKEN" -w "%{http_code}\n"
curl -s -X DELETE $API/exchanges/ex.demo.dlx -H "Authorization: Bearer $TOKEN" -w "%{http_code}\n"
```

Resultado esperado: el `PUT` responde `200` con `"x-message-ttl":120000`; el listado sigue mostrando
`"exchange":"ex.demo","destino":"q.demo.email",…,"routingKey":"demo.#"`, es decir, el binding
sobrevivió a la recreación; cada `DELETE` responde `204`. El `#` de la routing key va como `%23`.

Al final, en *Queues* quedan solo las seis `q.cmd.*`, y los nueve bindings del sistema siguen
intactos.

---

## Paso 5. Publicar desde reservations y consumir en notify — 🔑 Verificado con token local

**Qué hace.** Prepara una unidad en catalog (reservations la consulta antes de crear una reserva),
crea una reserva y la confirma. Al crearla, reservations publica `email.send`; al confirmarla,
compromete el cupo en catalog y publica `email.send` y `voucher.gen`. Notify consume los tres.

```bash
IN=$(date -d "+10 days" +%F); OUT=$(date -d "+12 days" +%F)

# Un hostal y una unidad con un cupo (requiere rol Admin)
curl -s -X POST http://localhost:8082/api/catalog/hostales -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"codigo":"E2E-01","nombre":"Hostal E2E","comuna":"Pucon"}'
curl -s -X POST http://localhost:8082/api/catalog/units -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"hostalId":1,"name":"Cabana E2E","type":"CABANA","capacity":2,"pricePerNight":45000,"availableSlots":1}'

# La reserva: publica email.send
curl -s -X POST http://localhost:8081/api/reservations -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d "{\"guestId\":\"huesped-e2e\",\"guestEmail\":\"huesped@andesstay.test\",\"unitId\":1,\"checkIn\":\"$IN\",\"checkOut\":\"$OUT\",\"huespedes\":2}"

# Confirmarla: publica email.send y voucher.gen
curl -s -X PUT http://localhost:8081/api/reservations/1/status -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"status":"CONFIRMADA"}'
```

Los `id` 1 son los de una base recién creada; si ya había datos, usar los que devuelvan las
respuestas. Resultado esperado: `201`, `201`, `201` con `"status":"CREADA","totalPrice":90000.00`, y
`200` con `"status":"CONFIRMADA"`.

**Lo que publicó reservations:**

```bash
docker logs andesstay-e2e-reservations 2>&1 | grep "\[RabbitMQ\]"
```

```
[RabbitMQ] Publicando email.send → reserva=1 eventId=117e62f6-… traceId=a10b2dca-…
[RabbitMQ] Broker confirmó la publicación · email.send eventId=117e62f6-…
[RabbitMQ] Publicando email.send → reserva=1 eventId=90985c9a-… traceId=69f9ce27-…
[RabbitMQ] Publicando voucher.gen → reserva=1 eventId=be82618e-… traceId=69f9ce27-…
[RabbitMQ] Broker confirmó la publicación · email.send eventId=90985c9a-…
[RabbitMQ] Broker confirmó la publicación · voucher.gen eventId=be82618e-…
```

*Broker confirmó la publicación* es el *publisher confirm*: el broker aceptó y enrutó el mensaje.

**Lo que consumió notify:**

```bash
docker logs andesstay-notify 2>&1 | grep -E "\[Email\]|\[Voucher\]|\[Housekeeping\]"
```

```
[Email] Enviando a=huesped@andesstay.test asunto='Reserva recibida - AndesStay #1' traceId=a10b2dca-…
[Email] Enviado correctamente traceId=a10b2dca-…
[Email] Enviando a=huesped@andesstay.test asunto='Reserva confirmada - AndesStay #1' traceId=69f9ce27-…
[Voucher] VOUCHER generado reserva=1 destinatario=huesped@andesstay.test datos={unitId=1, fechaEntrada=…, noches=2, moneda=CLP, tarifaTotal=90000.0} traceId=69f9ce27-…
[Email] Enviado correctamente traceId=69f9ce27-…
```

El `traceId` permite seguir cada mensaje desde que reservations lo publica hasta que notify lo
procesa.

**Los correos:** abrir `http://localhost:8025`. Deben estar *Reserva recibida - AndesStay #1* y
*Reserva confirmada - AndesStay #1*, para `huesped@andesstay.test`.

**En la consola:** *Queues → `q.cmd.email`* muestra actividad en los gráficos de *Publish* y
*Deliver*, y la cola vuelve a 0 mensajes porque notify confirmó cada uno (ACK).

---

## Paso 6. Provocar errores y ver los mensajes en la DLQ — 🔑 Verificado con token local

Notify distingue dos clases de error (ver el Javadoc de `EmailConsumer`):

| Error | Ejemplo | Qué hace notify |
|---|---|---|
| **Permanente** | Destinatario inválido, cuerpo ilegible | Rechaza **sin reintentar**: el mensaje va de inmediato a la DLQ |
| **Transitorio** | El servidor de correo no responde | **Reintenta 3 veces** con espera creciente; agotados los intentos, va a la DLQ |

En los dos casos el mensaje viaja por `cmd.dead.dlx` a `q.cmd.email.dlq`, donde `DeadLetterConsumer`
lo registra en el log con el motivo que RabbitMQ deja en la cabecera `x-death`.

### 6.1 Error permanente: destinatario inválido — ✅ Verificado

No necesita token: el mensaje se publica directamente en el broker, imitando a reservations.

**Qué hace.** Publica en `cmd.direct`, con la routing key `email.send`, un envelope válido cuyo
destinatario no es un correo.

**Desde la consola:** *Exchanges → `cmd.direct` → Publish message*, con *Routing key* `email.send`,
la propiedad `content_type` = `application/json` y como *Payload*:

```json
{"type":"email.send","eventId":"e2e-permanente-001","timestamp":"2026-10-11T23:55:00Z","traceId":"e2e-traza-permanente","correlationId":"e2e","source":"prueba-e2e","actor":{"userId":"e2e","role":"Admin","tenant":"staff"},"payload":{"plantilla":"RESERVA_CONFIRMADA","destinatario":"no-es-un-correo","reservationId":999,"datos":{}}}
```

> La publicación desde el formulario de la consola **no se probó visualmente**; se verificó su
> equivalente exacto por la API de gestión:

```bash
PAYLOAD='{"type":"email.send","eventId":"e2e-permanente-001","timestamp":"2026-10-11T23:55:00Z","traceId":"e2e-traza-permanente","correlationId":"e2e","source":"prueba-e2e","actor":{"userId":"e2e","role":"Admin","tenant":"staff"},"payload":{"plantilla":"RESERVA_CONFIRMADA","destinatario":"no-es-un-correo","reservationId":999,"datos":{}}}'
BODY=$(node -e 'console.log(JSON.stringify({properties:{content_type:"application/json"},routing_key:"email.send",payload:process.argv[1],payload_encoding:"string"}))' "$PAYLOAD")
curl -s -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" -H "$H" -X POST -d "$BODY" \
  http://localhost:15672/api/exchanges/andesstay/cmd.direct/publish
```

Responde `{"routed":true}`. Si se repite, cambiar el `eventId`: notify descarta los duplicados.

**En los logs de notify**, en el mismo segundo y **sin reintentos**:

```bash
docker logs andesstay-notify 2>&1 | grep -E "AmqpRejectAndDontRequeue|\[DLQ\]" | tail -2
```

```
Caused by: org.springframework.amqp.AmqpRejectAndDontRequeueException: destinatario inválido 'no-es-un-correo': Missing final '@domain'
[DLQ] Mensaje en cuarentena en q.cmd.email.dlq · motivo=rejected colaOrigen=q.cmd.email routingKeys=[email.send] intentos=1 · cuerpo={"type":"email.send","eventId":"e2e-permanente-001",…}
```

En la verificación, entre la publicación y la línea `[DLQ]` pasaron 5 ms.

### 6.2 Error transitorio: el servidor de correo cae

**Qué hace.** Detiene Mailpit y provoca un correo cancelando la reserva del paso 5. Notify no puede
conectarse, reintenta y finalmente lo manda a la DLQ.

```bash
docker stop andesstay-e2e-mailpit
curl -s -X PUT http://localhost:8081/api/reservations/1/status -H "Authorization: Bearer $TOKEN" -H "$H" \
  -d '{"status":"CANCELADA"}'
```

**Esperar alrededor de 90 segundos**, sin levantar Mailpit todavía (si se levanta antes, el
reintento siguiente tiene éxito y el mensaje no llega a la DLQ). Luego:

```bash
docker logs -t andesstay-notify 2>&1 | grep -E "\[Email\] Enviando|Retry Policy Exhausted|\[DLQ\]" | tail -5
```

Resultado de la verificación: tres intentos y la DLQ, en 79 segundos.

```
23:50:04  [Email] Enviando … asunto='Reserva cancelada - AndesStay #1' traceId=9e0ee030-…
23:51:16  [Email] Enviando … asunto='Reserva cancelada - AndesStay #1' traceId=9e0ee030-…
23:51:22  [Email] Enviando … asunto='Reserva cancelada - AndesStay #1' traceId=9e0ee030-…
23:51:22  ListenerExecutionFailedException: Retry Policy Exhausted
23:51:22  [DLQ] Mensaje en cuarentena en q.cmd.email.dlq · motivo=rejected colaOrigen=q.cmd.email routingKeys=[email.send] intentos=1 · …
```

El primer intento tarda más porque espera a que falle la resolución del nombre `mailpit`. Cada
fallo deja además `MailConnectException: Couldn't connect to host, port: mailpit, 1025`.

**Volver a levantar Mailpit al terminar:**

```bash
docker start andesstay-e2e-mailpit
```

> **Hacerlo pronto.** Mientras el SMTP está caído, `/actuator/health` de notify responde `503` (ver
> *Hallazgos*) y, pasados unos dos minutos y medio, Docker marcaría el contenedor `unhealthy`.

### 6.3 Ver la DLQ

**En los logs:** las líneas `[DLQ]` de arriba. El campo `motivo` sale de la cabecera `x-death`:
`rejected` cuando el consumidor rechazó el mensaje, `expired` si venció su TTL de 5 minutos y
`maxlen` si la cola superó los 1000 mensajes.

**En la consola:** *Queues → `q.cmd.email.dlq`*. **La columna de mensajes listos sigue en 0**: la
DLQ tiene un consumidor, `DeadLetterConsumer`, que toma cada mensaje, lo registra y lo confirma. La
evidencia en la consola son los contadores de entregas y confirmaciones. Valores obtenidos al
terminar la verificación, por la API de gestión:

```
q.cmd.email       publicados=5  entregados=5  ack=3   ← 2 de los 5 no se confirmaron: fueron a la DLQ
q.cmd.email.dlq   publicados=0  entregados=2  ack=2   ← los 2 que llegaron, registrados por DeadLetterConsumer
q.cmd.voucher     publicados=1  entregados=1  ack=1
q.cmd.housekeeping publicados=1 entregados=1  ack=1
```

`publicados=0` en la DLQ no es un error: RabbitMQ no cuenta el *dead lettering* como una
publicación.

**En las métricas de notify** (su puerto no se publica, así que se consulta desde dentro del
contenedor). `/actuator/metrics` **exige un token con el rol Admin**, el mismo `$TOKEN` del paso 3:

```bash
docker exec andesstay-notify wget -qO- --header "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8085/actuator/metrics/notify.messages.dlq
```

```json
{"name":"notify.messages.dlq","description":"Mensajes que llegaron a una DLQ","measurements":[{"statistic":"COUNT","value":2.0}],"availableTags":[{"tag":"queue","values":["q.cmd.email.dlq"]}]}
```

Sin token responde `401` y con otro rol `403`. La métrica responde `404` hasta que llega el primer
mensaje a una DLQ.

> **Estado de este comando.** La respuesta de arriba se obtuvo el 2026-10-11, **antes** de que
> notify protegiera `/actuator/metrics` (rama `feat/notify-seguridad-jwt` de
> `ms-andesstay-notify`). La exigencia del rol Admin está cubierta por los tests de capa web de
> notify (`SeguridadWebTest`: 401, 403 y 200), pero **el comando con `--header` no se repitió en el
> entorno Docker**. Si se prueba con una versión de notify anterior a esa rama, la métrica responde
> sin token.

---

## Paso 7. Apagar y limpiar — ✅ Verificado

**Qué hace.** Detiene y elimina los nueve contenedores y la red, y **borra los volúmenes**: las
colas, los mensajes y la base de datos de la prueba. Las imágenes construidas se conservan para la
próxima vez.

```bash
$DC down -v
```

Sin `-v` se conservan los datos y el siguiente `up` arranca más rápido, pero la base y las colas
mantienen lo de la prueba anterior.

---

## Hallazgos durante la verificación

| # | Hallazgo | Estado |
|---|---|---|
| 1 | **Primer arranque de RabbitMQ.** Con el volumen vacío, `rabbitmq1` tarda unos 3 minutos en arrancar (busca a `rabbitmq2`, que compose todavía no creó) y el healthcheck lo declaraba `unhealthy` segundos antes, con lo que todo lo demás fallaba. | **Corregido** en `mq/compose.yml`: `start_period` de 40 s a 240 s |
| 2 | **Notify no tiene timeout de SMTP.** El log dice `timeout -1`. En la prueba el fallo llegó porque el nombre `mailpit` dejó de resolver; un servidor que resolviera pero no respondiera dejaría al consumidor de correos bloqueado sin reintentar ni llegar a la DLQ. | Pendiente, en `ms-andesstay-notify`: fijar `mail.smtp.connectiontimeout`, `timeout` y `writetimeout` |
| 3 | **El health de notify depende del SMTP.** Spring Boot agrega solo el indicador de salud del correo; con el SMTP caído, `/actuator/health` responde `503` y el contenedor quedaría `unhealthy`, aunque sigue consumiendo y mandando a la DLQ. | Pendiente, en `ms-andesstay-notify`: `management.health.mail.enabled: false` o tratarlo aparte |
| 4 | **"intentos" en el log de la DLQ** muestra el `count` de `x-death`, que cuenta cuántas veces el mensaje fue a parar a la DLQ, no cuántos intentos de entrega hubo. Tras tres intentos fallidos muestra `intentos=1`. | Pendiente, cosmético, en `DeadLetterConsumer` |
| 5 | **`apps/compose.yml` está desactualizado**: apunta a Oracle y exige la red de Kafka. | Sin cambios; esta guía usa `mq/compose.yml` y el overlay |
| 6 | **Tildes en `curl -d` desde Git Bash** se envían mal codificadas (`400 Invalid UTF-8 middle byte`). | Documentado en *Requisitos* |

---

## Resumen del estado de verificación

| Paso | Estado |
|---|---|
| 1. Levantar el entorno | ✅ Verificado |
| 2. Topología en la consola | ✅ Verificado (valores por línea de comandos y API de gestión; vista web no revisada visualmente) |
| 3. Token de Entra ID | 🔑 **Pendiente con token real** |
| 4. Administrador: seguridad, creación, conflictos, protección, validación, actualización y limpieza | 🔑 Verificado con token local — **falta con token real** |
| 5. Reservations publica y notify consume | 🔑 Verificado con token local — **falta con token real** |
| 6.1 DLQ por error permanente | ✅ Verificado (no requiere token); el formulario de la consola no se probó visualmente |
| 6.2 DLQ por error transitorio | 🔑 Verificado con token local — **falta con token real** |
| 6.3 Ver la DLQ en logs, consola y métricas | ✅ Verificado logs y consola. La métrica con token: ⚠️ no repetida en Docker tras proteger `/actuator/metrics` (cubierta por tests) |
| 7. Apagar | ✅ Verificado |
