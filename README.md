# infra

Infraestructura y contratos del sistema **AndesStay**, la plataforma de reservas de hostales,
cabañas y lodges.

Este repositorio es la **fuente de verdad** de los contratos: si un cambio afecta la máquina de
estados, los roles, las rutas del API Gateway o el formato de los eventos, se actualiza aquí en
el mismo PR.

## Contenido

| Ruta | Qué contiene |
|---|---|
| `docs/contracts/` | Contratos canónicos: estados, roles, rutas del gateway, eventos y OpenAPI |
| `oracle/` | Compose de Oracle Free y scripts de creación de esquemas |
| `apps/` | Compose de los microservicios para `ec2-apps` |
| `mq/` | Compose del clúster RabbitMQ para `ec2-mq` |
| `kafka/` | Compose de 3 Zookeeper, 3 brokers y Kafka UI para `ec2-kafka`, más los scripts de administración de tópicos y consumer groups |
| `deploy/` | Scripts de creación de las tres instancias en AWS y el compose de despliegue |

## Levantar el sistema en local

En este orden, desde la carpeta que contiene `infra` y los repositorios de los servicios:

```bash
# 1. RabbitMQ (2 nodos), ms-andesstay-notify, ms-andesstay-mq y el buzón Mailpit
cp infra/.env.example infra/.env            # completar valores
docker compose --env-file infra/.env -f infra/mq/compose.yml up -d

# 2. Kafka: 3 Zookeeper, 3 brokers, kafka-init (crea y configura los tópicos) y Kafka UI
docker compose -f infra/kafka/compose.yml up -d

# 3. MySQL y los microservicios (bff, reservations, catalog, report, audit, kafka-admin)
cp infra/apps/.env.example infra/apps/.env  # completar valores
docker compose --env-file infra/apps/.env -f infra/apps/compose.yml up -d --build
```

`apps/compose.yml` se conecta a las redes `andesstay-mq` y `andesstay-kafka`, que los dos primeros
compose crean con ese nombre exacto. Por eso el orden importa.

| Interfaz | Dirección |
|---|---|
| Kafka UI | http://localhost:8090 |
| RabbitMQ Management | http://localhost:15672 |
| Mailpit | http://localhost:8025 |
| BFF | http://localhost:8080 |
| Administrador de Kafka (`ms-andesstay-kafka`) | http://localhost:8087 |
| Administrador de RabbitMQ (`ms-andesstay-mq`) | http://localhost:8086 |

Para reparar o inspeccionar los tópicos y los grupos sobre un clúster en marcha:
`bash infra/kafka/scripts/crear-topicos.sh`, `describir-topicos.sh` e `inspeccionar-grupos.sh`.

### La bandera de Kafka de reservations

`ms-andesstay-reservations` solo publica en `reservations.events` si
`ANDESSTAY_EVENTS_KAFKA_ENABLED` vale `true`. En su `application.yml` vale `false` por defecto, a
propósito: permite arrancar el servicio con `./mvnw spring-boot:run` sin ningún clúster, sin que
cada reserva espere el `max.block.ms` del productor. Los dos compose que lo levantan junto al
clúster, `apps/compose.yml` y `deploy/compose.yml`, la encienden (`true` por defecto) y la dejan
como variable para poder apagarla sin editar el archivo. RabbitMQ tiene su propia bandera,
`ANDESSTAY_EVENTS_RABBIT_ENABLED`, independiente de esta.

## Contratos

Antes de escribir código contra otro servicio, revisar:

| Documento | Para qué |
|---|---|
| [`docs/contracts/estados.md`](docs/contracts/estados.md) | Transiciones válidas de una reserva y quién puede ejecutarlas |
| [`docs/contracts/roles.md`](docs/contracts/roles.md) | Mapeo de claims a authorities por tenant y matriz endpoint × rol |
| [`docs/contracts/rutas-gateway.md`](docs/contracts/rutas-gateway.md) | Rutas del API Gateway, sus authorizers y la configuración de CORS |
| [`docs/contracts/events/envelope.md`](docs/contracts/events/envelope.md) | Envelope común de todo mensaje y evento |
| [`docs/contracts/events/kafka.md`](docs/contracts/events/kafka.md) | Tópicos y esquemas de eventos |
| [`docs/contracts/events/rabbit.md`](docs/contracts/events/rabbit.md) | Exchanges, colas, DLQ y esquemas de mensajes |
| [`docs/contracts/openapi/`](docs/contracts/openapi/) | Contrato REST de cada servicio |

## Guias de configuracion

Trabajo de portal y consola, paso a paso. Se ejecutan antes de escribir el codigo que las usa.

| Guia | Para que |
|---|---|
| [`docs/guias/azure-identidad.md`](docs/guias/azure-identidad.md) | Los dos tenants: app registrations, roles, user flow de auto-registro y evidencia de PKCE |
| [`docs/guias/aws-gateway-ec2.md`](docs/guias/aws-gateway-ec2.md) | API Gateway con sus dos authorizers, las 16 rutas, CORS, las instancias EC2 y la bateria de pruebas |
| [`docs/idaas/tenants.md`](docs/idaas/tenants.md) | Plantilla donde se registran los identificadores resultantes |

## Arquitectura

```
Angular (MSAL) ──Bearer JWT──► AWS API Gateway (HTTP API)
                               ├─ /staff/*  → authorizer entra-staff
                               └─ /guest/*  → authorizer entra-guest
                                        │
                                        ▼
                              ms-andesstay-bff (Spring Security)
                                        │
              ┌────────────┬────────────┼────────────┬────────────┐
              ▼            ▼            ▼            ▼            ▼
        reservations    catalog       audit        report      notify
```

Ningún microservicio de dominio se expone directo al frontend: el camino es siempre
`JWT → API Gateway → BFF → servicio de dominio`.

## Repositorios del sistema

| Repositorio | Rol |
|---|---|
| [`frontend-andesstay`](https://github.com/AndesStay-Duoc/frontend-andesstay) | Angular + MSAL |
| [`ms-andesstay-bff`](https://github.com/AndesStay-Duoc/ms-andesstay-bff) | BFF, único punto de entrada al dominio |
| [`ms-andesstay-reservations`](https://github.com/AndesStay-Duoc/ms-andesstay-reservations) | Reservas y máquina de estados |
| [`ms-andesstay-catalog`](https://github.com/AndesStay-Duoc/ms-andesstay-catalog) | Unidades, tarifas y disponibilidad |
| [`ms-andesstay-notify`](https://github.com/AndesStay-Duoc/ms-andesstay-notify) | Consumidor RabbitMQ |
| [`ms-andesstay-audit`](https://github.com/AndesStay-Duoc/ms-andesstay-audit) | Consumidor Kafka, timeline de auditoría |
| [`ms-andesstay-report`](https://github.com/AndesStay-Duoc/ms-andesstay-report) | Consumidor Kafka, KPIs |

## Cómo contribuir

Ver [`CONTRIBUTING.md`](CONTRIBUTING.md). En resumen: ramas `feature/*` y `fix/*` desde
`develop`, Conventional Commits en español, PR con un revisor y squash merge. `main` no se toca.
