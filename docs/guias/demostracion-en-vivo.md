# Demostración en vivo · guion operativo

Qué se ejecuta, dónde y en qué orden para la defensa de RabbitMQ. Complementa al guion de
exposición: aquel dice **qué se cuenta**, este dice **qué se teclea**.

Todos los comandos de este documento se verificaron contra el entorno desplegado el 16 de octubre
de 2026.

---

## Lo primero, porque cambia el montaje: son DOS instancias

El guion de exposición afirma que «todo el sistema corre en esta instancia EC2». No es así, y la
pantalla lo desmiente en cuanto se abre una terminal:

| Instancia | Dirección | Qué corre |
|---|---|---|
| `ec2-apps` | `44.212.152.92` | bff, catalog, reservations, report, audit, web, mysql |
| `ec2-mq` | `34.227.147.53` | rabbitmq1, rabbitmq2, notify, mq, mailpit |

En **ninguna** de las dos terminales se ven los microservicios y RabbitMQ juntos. Hay que enseñar
las dos, y conviene decir por qué: los dos nodos del broker más notify no caben en la instancia de
aplicaciones, así que la mensajería se separó a la suya. Es una decisión de arquitectura que se
defiende sola; disimularla es lo que daría problemas.

Las direcciones son **elásticas**: no cambian aunque se reinicie el laboratorio.

## No hace falta Docker en el equipo del expositor

Los `docker compose` del guion se ejecutan **dentro de las instancias**, por SSH. Levantar una copia
local no solo es innecesario: sería otro sistema, con otra base de datos y otro broker, y ninguna
captura coincidiría con lo desplegado.

El equipo del expositor solo necesita cliente SSH, navegador y Postman.

---

## Preparación · 15 minutos antes

### 1 · Las cuatro terminales

Cada una en su ventana. Las dos primeras se dejan quietas; la tercera y la cuarta corren todo el
rato.

**Terminal A · estado de `ec2-apps`**

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@44.212.152.92 \
  'cd /opt/andesstay && docker compose --env-file .env -f infra/deploy/compose.yml ps'
```

**Terminal B · estado de `ec2-mq`**

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'cd /opt/andesstay && docker compose --env-file mq.env -f infra/mq/compose.yml ps'
```

**Terminal C · logs de notify en vivo** — la mejor evidencia del ACK y de la DLQ

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'cd /opt/andesstay && docker compose --env-file mq.env -f infra/mq/compose.yml logs -f notify'
```

**Terminal D · el túnel** — se queda en blanco y sin prompt; eso significa que funciona

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem -N \
  -L 15672:localhost:15672 -L 8025:localhost:8025 \
  -L 8086:localhost:8086  -L 8085:localhost:8085 \
  ubuntu@34.227.147.53
```

> **El `--env-file` no es opcional.** Para `ps`, `logs`, `stop` y `start` su ausencia solo hace que
> compose no encuentre el servicio. Pero en un `up` sin él las credenciales del broker quedan en
> blanco, los contenedores se recrean sin poder autenticarse contra el volumen que ya existe y el
> clúster se cae. Ha ocurrido.

### 2 · Las pestañas del navegador

| # | Pestaña | Estado en el que debe quedar |
|---|---|---|
| 1 | AWS → EC2 | las **dos** instancias en `running` |
| 2 | AWS → API Gateway | las rutas y el authorizer JWT |
| 3 | AndesStay | **sesión cerrada**, para mostrar el login desde cero |
| 4 | `http://localhost:15672` | Management UI, en *Queues and Streams* |
| 5 | `http://localhost:8025` | Mailpit, bandeja vacía |
| 6 | Postman | colección cargada y token pegado |

Las dos últimas dependen del túnel: si la terminal D se cierra, dejan de responder.

Usuario del broker: `andesstay`. La contraseña sale de:

```bash
grep '^RABBITMQ_PASSWORD=' AndesStay/secrets/andesstay-mq.env | cut -d= -f2-
```

**En la Management UI, poner el refresco en 1 segundo**, arriba a la derecha. Por omisión son 5 y
los saltos del backoff se pierden entre dos refrescos.

### 3 · Subir la escalera de reintentos

Con la escalera por omisión —1, 2 y 4 segundos— el recorrido completo dura unos 12 segundos y los
tres ciclos ocurren casi entre dos refrescos de la interfaz: no se ve nada.

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'cd /opt/andesstay && NOTIFY_BACKOFF_LADDER=3000,6000,12000 \
   docker compose --env-file mq.env -f infra/mq/compose.yml up -d --no-build notify'
```

Con esto el recorrido pasa a unos **41 segundos** y cada entrada en la cola de espera es visible.

### 4 · El token

Dura unos 80 minutos, así que se genera **justo antes** de entrar. Desde la aplicación, con las
herramientas de desarrollo abiertas (F12 → Console):

```javascript
Object.entries(sessionStorage).filter(([k,v])=>k.includes('accesstoken')).map(([k,v])=>JSON.parse(v).secret)[0]
```

Se pega en Postman → *Environments* → `tokenAdmin` → columna **Current value**, y se pone
`tunelAbierto` a `si` para que las carpetas 10 y 11 no se salten.

### 5 · Un ensayo completo

Crear una reserva y confirmarla una vez, para que el camino esté caliente y para comprobar que el
token tiene el rol. Después, vaciar Mailpit.

---

## El recorrido, bloque a bloque

### 1 · Arquitectura

**Pantalla:** AWS → EC2 con las dos instancias, luego terminales A y B.

Las dos terminales juntas son el argumento: siete contenedores de aplicación en una, cinco de
mensajería en la otra, todos `healthy`.

### 2 · Seguridad de entrada

**Pantalla:** API Gateway → rutas y authorizer. Después, login en la aplicación con F12 → Network.

En la petición se ve la cabecera `Authorization: Bearer`. El token se valida en dos capas: el
authorizer del gateway y cada microservicio.

Dato comprobable si lo preguntan: el gateway declara **20 rutas y ninguna sin authorizer**.

### 3 · Topología

**Pantalla:** Management UI → *Exchanges*, luego *Queues and Streams* → `q.cmd.email` →
*Features/Arguments* → *Bindings*.

Tres exchanges —`cmd.direct`, `cmd.topic` y `cmd.dead.dlx`— y **nueve colas**: tres de trabajo, tres
de espera y tres de descarte.

En los argumentos de `q.cmd.email` se ven `durable`, `x-dead-letter-exchange`, `x-message-ttl` y
`x-max-length`.

> **Ojo con lo que se dice de las colas de espera.** Las tres `.retry` **no** llevan
> `x-message-ttl`: el plazo va por mensaje, en la propiedad `expiration`. Es justo lo que permite
> que cada reintento espere un tiempo distinto en la misma cola, y es una pregunta natural.
>
> Y su columna *Consumers* está en **0**, que es correcto y conviene adelantarse a explicarlo: de
> ahí los mensajes salen por vencimiento, no por consumo. Un consumidor ahí se los comería antes de
> que venzan y el reintento dejaría de existir.

### 4 · El camino feliz

**Pantalla:** aplicación → crear una reserva. Management UI → *Overview*. Terminal C. Mailpit.

Crear la reserva publica `RESERVA_RECIBIDA` en `cmd.direct` con la routing key `email.send`. En la
terminal C aparecen tres líneas:

```
[Email] Enviando a=... asunto='Reserva recibida - AndesStay #N'
[Email] Enviado correctamente
[Email] ACK tag=N intento=1/4
```

`intento=1/4` es el dato que vale: entró y salió al primer intento, y **4** es el total de intentos
posibles, no 3.

**Confirmar la reserva dispara dos mensajes en dos colas**, y ese abanico es más demostrativo que
la creación: `RESERVA_CONFIRMADA` a `q.cmd.email` y `VOUCHER` a `q.cmd.voucher`, por el mismo
exchange con routing keys distintas.

| Acción en la aplicación | Mensajes | Colas |
|---|---|---|
| Crear reserva | `RESERVA_RECIBIDA` | correo |
| **Confirmar** | `RESERVA_CONFIRMADA` + `VOUCHER` | **correo + voucher** |
| Pasar a check-in | `PREPARACION` + `RECORDATORIO_CHECKIN` | limpieza + correo |
| Check-out | `LIMPIEZA` + `CHECKOUT_REALIZADO` | limpieza + correo |
| Cancelar | `RESERVA_CANCELADA` | correo |

### 5 · Error transitorio

**Pantalla:** terminal → aplicación → terminal C → Management UI.

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'cd /opt/andesstay && docker compose --env-file mq.env -f infra/mq/compose.yml stop mailpit'
```

Crear otra reserva. En la terminal C se ven los intentos; en la Management UI, `q.cmd.email.retry`
subiendo y bajando **tres veces**. Con la escalera en 3-6-12 el recorrido dura unos 41 segundos, así
que conviene lanzarlo y pasar al bloque 6 mientras corre.

Al terminar:

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'cd /opt/andesstay && docker compose --env-file mq.env -f infra/mq/compose.yml start mailpit'
```

### 6 · Error permanente

**Pantalla:** Management UI → `cmd.direct` → *Publish message*.

Routing key `email.send` y un cuerpo con destinatario inválido. Va a la DLQ **de inmediato**, sin
pasar por la cola de espera. Esa es la ruta diferenciada: reintentar una dirección mal escrita
cuatro veces no la va a arreglar.

La prueba de que son rutas distintas es que `q.cmd.email.retry` **se queda plana** en este caso.

### 7 · Observar la DLQ

**Pantalla:** terminal C → Postman.

> **La profundidad de una DLQ nunca se ve en la interfaz.** `DeadLetterConsumer` confirma cada
> mensaje que llega, así que las tres vuelven a cero de inmediato y no hay forma de abrir un mensaje
> en cuarentena para leerle las cabeceras.
>
> Esa evidencia está en el log, y es donde hay que mirarla:
>
> ```bash
> ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
>   "docker logs andesstay-notify | grep '\[DLQ\]'"
> ```
>
> Ahí salen `x-andesstay-intentos` y el resumen de `x-death`, que es lo que la rúbrica pide ver.

En Postman, la carpeta **11** contra `GET /api/v1/notify/status` con el token de Admin: los
contadores de las nueve colas. Sin token, 401.

### 8 · El microservicio administrador

**Pantalla:** Postman carpeta **10** → Management UI.

Se corre con *Run folder*, no petición a petición: los pasos dependen entre sí y el último borra lo
que creó el primero.

| Paso | Esperado |
|---|---|
| Crear `q.demo.presentacion` | 201 |
| Crear exchange y binding de demo | 201 |
| Crear cola con nombre inválido | **400** |
| Borrar `q.cmd.email` con `forzar=true` | **409** |
| La misma llamada sin token | **401** |
| Borrar la cola de demo | 204 |

---

## Tres datos del guion que no cuadran

Conviene corregirlos antes de decirlos en voz alta.

**«Lo intenta hasta tres veces».** La escalera tiene tres esperas, y tres esperas significan
**cuatro intentos**. El log lo dice en cada línea: `intento=1/4`.

**«Cerca de 79 segundos».** Con la configuración actual el recorrido completo dura unos **12
segundos**, o unos **41** si se sube la escalera como indica la preparación. El 79 viene de otra
configuración.

**«Protegemos los patrones `q.cmd.*` y `cmd.*`».** No son patrones: la comprobación es
`protegidos.contains(nombre)`, igualdad exacta sobre una **lista de doce nombres** enumerados en la
configuración. La consecuencia importa si lo preguntan: una cola nueva llamada `q.cmd.loquesea`
**no queda protegida**, porque no está en la lista. El diseño se defiende —cambiar la topología
exige editar la configuración y volver a desplegar, no un parámetro en una petición— pero hay que
describirlo como lista explícita.

---

## Plan B

Un fallo explicado con calma vale más que una demostración forzada.

| Si pasa esto | Hacer esto |
|---|---|
| El token caducó y todo da 401 | Cerrar sesión, volver a entrar, pegar el nuevo. Y decirlo: es la validación de vigencia funcionando |
| El correo no llega a Mailpit | Comprobar que `MAIL_PORT` es 1025 y no 587 |
| El túnel se cayó | La terminal D; reabrirla. Las pestañas 4, 5 y Postman 10-11 dependen de ella |
| Las instancias no responden | Terminó la sesión del laboratorio. Reiniciarla y `instancias.sh encender` |
| RabbitMQ tarda en levantar | El arranque en frío de un nodo puede tomar hasta 3 minutos |
| Borrar algo inexistente da 204 | Es correcto: `deleteQueue` es idempotente. `purge` sí da 404, y esa asimetría es deliberada |

**Capturas de respaldo**, tomadas con el sistema funcionando y antes de entrar: las dos terminales
de estado, la topología con las nueve colas, el recorrido de reintentos, las líneas `[DLQ]` del log
y la ejecución de la carpeta 10 en Postman.

---

## Comprobación previa automática

Antes de entrar conviene correr la batería, que verifica las nueve colas y cuadra el balance de
mensajes sin tocar nada que importe:

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'bash -s' < AndesStay/infra/deploy/scripts/verificar-colas.sh
```

Termina con «Las nueve colas recibieron tráfico y el balance cuadra». Si sale en rojo, hay algo que
arreglar antes de exponer.

Y si se quiere que la Management UI tenga movimiento que enseñar:

```bash
ssh -i ~/.ssh/andesstay-key-20261012222825.pem ubuntu@34.227.147.53 \
  'bash -s -- --modo acumular --duracion 60 --tasa 10' \
  < AndesStay/infra/deploy/scripts/carga-colas.sh
```

Detiene notify, deja que los mensajes se acumulen a la vista y después lo levanta para enseñar el
vaciado. Demuestra algo que importa: un consumidor caído **acumula** trabajo, no lo descarta.
