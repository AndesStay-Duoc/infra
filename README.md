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
| `kafka/` | Compose de Zookeeper y Kafka para `ec2-kafka` |

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
