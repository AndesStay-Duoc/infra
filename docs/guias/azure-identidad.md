# Guía — Configuración de identidad en Azure

Paso a paso para dejar operativa la identidad de AndesStay. Es el trabajo de la Fase 1 y el de
mayor peso de todo el proyecto: **60% de la EP1 y 45% de la EP2**.

Todo esto se hace en el portal, no en código. Al terminar, se anotan los identificadores en
[`../idaas/`](../idaas/) y el código solo los lee por configuración.

## Un tenant, dos aplicaciones

**Cambio de diseño, 2026-09-11.** El plan original usaba dos tenants: uno corporativo y uno de
Entra External ID para huéspedes. No fue posible: la cuenta de Azure disponible **no permite
crear un segundo tenant**, sea por falta de suscripción, por política del tenant institucional
o por cuota de directorios.

El esquema quedó así: **un solo tenant con dos app registrations.**

| | Aplicación del personal | Aplicación de huéspedes |
|---|---|---|
| App registration | `AndesStay-Staff` | `AndesStay-Guest` |
| Quiénes | Admin, Recepcionista, Auditor | Huésped |
| Scope | `access_as_staff` | `access_as_guest` |
| Alta de usuarios | El administrador las crea | **User flow de auto-registro** |
| Rutas del gateway | `/staff/*` | `/guest/*` |

Las dos comparten **issuer** —es el mismo tenant— y tienen **audience distinta**, porque son
aplicaciones distintas. Eso alcanza para mantener la separación:

- En el **API Gateway**: dos authorizers con el mismo issuer y audience distinta, uno por grupo
  de rutas.
- En el **BFF**: un solo emisor que acepta las dos audiences, y el claim `scp` distingue
  personal de huésped.

### El auto-registro sin External ID

El indicador 5 de la EP2 (10%) pide que los usuarios creen sus cuentas desde el frontend. Entra
ID corporativo **sí tiene user flows de auto-registro**, aunque no sean los de External ID:

**Entra ID → External Identities → User flows → New user flow**

Para que la opción aparezca hay que habilitar antes:

**External Identities → External collaboration settings →
"Enable guest self-service sign up via user flows" = Yes**

> **Verificar esto primero.** La disponibilidad depende de la configuración del tenant y de que
> admita el proveedor de correo con código de un solo uso. Si está bloqueado, hay que avisarle al
> docente que el indicador 5 no es alcanzable con la cuenta disponible, y quedarse con alta de
> huéspedes por invitación del administrador.

---

# Parte A — Aplicación de huéspedes y auto-registro

Se hace **primero** porque carga el indicador que ningún otro camino cubre.

## A.1 Habilitar el auto-registro en el tenant

Esto va **antes** de crear la aplicación, porque determina si el resto de la Parte A es
posible.

1. Entrar a [entra.microsoft.com](https://entra.microsoft.com).
2. **External Identities → External collaboration settings**.
3. Poner **"Enable guest self-service sign up via user flows"** en **Yes**. Guardar.
4. **External Identities → All identity providers**: confirmar que **Email one-time passcode**
   está habilitado. Es el proveedor que no requiere registrar nada en un tercero.

Si el paso 3 no está disponible o el portal lo rechaza, el auto-registro no es alcanzable con
esta cuenta. En ese caso: avisarle al docente, y seguir con la Parte A tratando a los huéspedes
como usuarios que el administrador invita.

## A.2 Registrar la aplicación de huéspedes

En el **mismo tenant** donde ya existe la aplicación del personal.

1. **Applications → App registrations → New registration**.
2. Name: `AndesStay-Guest`
3. Supported account types: **Accounts in this organizational directory only**
4. Redirect URI: plataforma **Single-page application (SPA)**, valor `http://localhost:4200`

   Elegir SPA no es un detalle: **fuerza Authorization Code con PKCE** y deshabilita el flujo
   implícito. Es lo que evalúa el indicador 6 de la EP2 (15%). Si se elige "Web", MSAL intentará
   usar un client secret y el flujo no será el que pide la rúbrica.
5. Registrar y **copiar el Application (client) ID** y el **Directory (tenant) ID**.

## A.3 Agregar la URI de producción

Cuando el frontend esté desplegado hay que volver acá:

**Authentication → Single-page application → Add URI** → la URL pública del frontend.

> Si esto se olvida, el login funciona en local y **falla en la demo**. Es el error más común y
> se paga caro en una presentación de 5 a 10 minutos.

## A.4 Exponer la API

Esto es lo que hace que el token tenga el `aud` correcto.

1. **Expose an API → Add** junto a *Application ID URI*.
2. Aceptar el valor propuesto `api://<guest-client-id>`. Copiarlo.
3. **Add a scope**:
   - Scope name: `access_as_guest`
   - Who can consent: **Admins and users**
   - Admin consent display name: `Acceder a AndesStay como huesped`
   - Admin consent description: `Permite a la aplicacion llamar a la API de AndesStay en nombre del huesped`
   - State: Enabled
4. El scope completo queda `api://<guest-client-id>/access_as_guest`. **Es el que el frontend
   debe pedir.**

> **La trampa del audience.** Si el frontend pide un scope de Microsoft Graph como `User.Read`,
> el token que recibe tiene `aud` de Graph, no de tu API, y el BFF lo rechazará con 401 aunque
> el login se vea perfecto. Hay que pedir **el scope propio**.

## A.5 Definir el rol de aplicación

1. **App roles → Create app role**:
   - Display name: `Huesped`
   - Allowed member types: **Users/Groups**
   - Value: `Huesped` — exactamente así, es lo que llega en el claim `roles`
   - Description: `Cliente que crea y sigue sus reservas`
2. Habilitar.

El valor del campo *Value* es el que el converter del backend transforma en `ROLE_HUESPED`. Ver
[`../contracts/roles.md`](../contracts/roles.md).

## A.6 Crear el flujo de usuario — el indicador 5 de la EP2

Acá está el 10%. Requiere haber hecho A.1.

1. **External Identities → User flows → New user flow**.
2. Name: `AndesStay-SignUpSignIn`
3. Identity providers: **Email one-time passcode**, o el que esté disponible
4. **User attributes**: marcar los que se piden al registrarse:
   - Given Name
   - Surname
   - Email Address
5. Crear.
6. Entrar al flujo recién creado → **Applications → Add application** → seleccionar
   `AndesStay-Guest`.

   **Este paso se olvida seguido.** Sin asociar la aplicación, el flujo existe pero nunca se
   dispara.
7. En el mismo flujo → **User attributes** → confirmar qué se recolecta, y en
   **Application claims** → marcar qué se devuelve en el token. Incluir nombre y email.

## A.7 Probar el auto-registro

1. En el flujo de usuario → **Run user flow** (o usar directamente la app cuando esté lista).
2. Registrar un usuario de prueba real, por ejemplo `huesped.prueba@<dominio>`.
3. Verificar en **Users** que aparece.

Capturar: el flujo creado, la aplicación asociada y el usuario en la lista. Van a
`../evidencias/idaas/`.

## A.8 Asignar el rol al usuario de prueba

1. **Applications → Enterprise applications → AndesStay-Guest → Users and groups**.
2. **Add user/group** → el usuario de prueba → rol `Huesped`.

> En el tier gratuito se puede asignar **usuarios** a roles de aplicación, pero **no grupos**:
> la asignación por grupo requiere Entra ID P1. Asignar usuario por usuario.

---

# Parte B — Aplicación del personal

## B.1 El tenant

Es el mismo de la Parte A. Para este proyecto ya está creado y verificado:

| Dato | Valor |
|---|---|
| Tenant ID | `cfe8706e-e5ae-44dd-8092-b4941bda8bd9` |
| Dominio | `appdemo113.onmicrosoft.com` |

La aplicación `AndesStay-Staff` también existe ya, con su API expuesta y el scope
`access_as_staff` verificado. Los pasos B.2 y B.3 quedan como referencia de lo que se hizo.

## B.2 Registrar la aplicación

1. **App registrations → New registration**.
2. Name: `AndesStay-Staff`
3. Redirect URI: plataforma **Single-page application (SPA)**, `http://localhost:4200`
4. Copiar client ID y tenant ID.

## B.3 Exponer la API

Igual que A.4, pero el scope es `access_as_staff`:

- Application ID URI: `api://<staff-client-id>`
- Scope: `access_as_staff`, consentimiento de admins y usuarios

## B.4 Definir los tres roles

**App roles → Create app role**, uno por cada uno:

| Display name | Value | Descripción |
|---|---|---|
| `Admin` | `Admin` | Administra el inventario de unidades y ve KPIs de ocupación |
| `Recepcionista` | `Recepcionista` | Confirma reservas, hace check-in y check-out |
| `Auditor` | `Auditor` | Consulta el timeline. Solo lectura |

Allowed member types: **Users/Groups** en los tres.

## B.5 Crear un usuario de prueba por rol — el indicador 3 de la EP2

La rúbrica pide al 100% que el tenant "incluya usuarios de prueba, roles, políticas y parámetros
que el sistema requiere". Tres usuarios, uno por rol:

1. **Identity → Users → New user → Create new user**.
2. Crear `admin.prueba`, `recepcion.prueba` y `auditor.prueba`.
3. **Enterprise applications → AndesStay-Staff → Users and groups → Add user/group**: asignar a
   cada uno su rol.

Sin esto no se puede demostrar que la autorización por rol funciona, que es la mitad de lo que
se evalúa en la EP1 y la EP2.

---

# Parte C — Datos a registrar

Al terminar, completar `../idaas/tenants.md` con esta tabla. **Nada de esto es secreto**: son
identificadores públicos que van en la configuración del frontend.

| Dato | Personal | Huéspedes |
|---|---|---|
| Tenant ID | `cfe8706e-e5ae-44dd-8092-b4941bda8bd9` | *(el mismo)* |
| Tenant domain | `appdemo113.onmicrosoft.com` | *(el mismo)* |
| Client ID | | |
| Application ID URI | `api://<client-id>` | `api://<client-id>` |
| Scope completo | `api://<client-id>/access_as_staff` | `api://<client-id>/access_as_guest` |
| Authority | `https://login.microsoftonline.com/<tenant-id>` | *(la misma)* |
| Issuer del token (`iss`) | `https://login.microsoftonline.com/<tenant-id>/v2.0` | *(el mismo)* |
| JWKS | `<authority>/discovery/v2.0/keys` | *(el mismo)* |
| Roles | `Admin`, `Recepcionista`, `Auditor` | `Huesped` |
| **Client ID y scope** | **propios de cada app** | **propios de cada app** |
| User flow | — | `AndesStay-SignUpSignIn` |

**El `issuer` y el `audience` son los dos valores que alimentan todo lo demás**: los authorizers
del API Gateway (indicador 7 de la EP2, 20%) y la validación del BFF (indicador 2 de la EP1,
40%). Conviene verificarlos leyendo el documento de descubrimiento:

```bash
curl -s https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration | python -m json.tool
```

El campo `issuer` de esa respuesta es, literalmente, el valor que hay que configurar. No
deducirlo a mano.

---

# Parte D — Verificación

## D.1 Inspeccionar un token real

Una vez que el frontend haga login, tomar el access token y decodificarlo. Comprobar:

| Claim | Valor esperado |
|---|---|
| `iss` | Exactamente el issuer de la tabla de la Parte C |
| `aud` | `api://<client-id>` del tenant correspondiente, **no** un id de Graph |
| `roles` | El rol asignado al usuario |
| `scp` | `access_as_staff` o `access_as_guest` |
| `sub` | Identificador estable. Es el `guestId` de las reservas |

Para decodificar sin herramientas externas:

```bash
python -c "import base64,json,sys; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))" "<el-token>"
```

> Conviene decodificar localmente en vez de pegar el token en un sitio web: aunque sea de
> prueba, es una credencial válida.

## D.2 Evidencia de PKCE — indicador 6 de la EP2, 15%

MSAL usa Authorization Code con PKCE por defecto cuando la app está registrada como SPA, pero
**hay que demostrarlo**:

1. Abrir las herramientas de desarrollo del navegador, pestaña **Red**, y marcar *Preserve log*.
2. Iniciar sesión.
3. Buscar la petición a `/authorize` y capturar la URL, verificando que lleva:
   - `response_type=code`
   - `code_challenge=...`
   - `code_challenge_method=S256`
   - `state=...`
   - `nonce=...`
4. Buscar la petición `POST` a `/token` y capturar el cuerpo, con `code` y `code_verifier`.

Si aparece `response_type=id_token token`, la app está registrada como Web o con flujo implícito
habilitado: volver a la Parte A.2 y corregir la plataforma.

Las capturas van a `../evidencias/pkce/`.

## D.3 Checklist de cierre de la Parte A y B

- [ ] Auto-registro habilitado en External collaboration settings
- [ ] `AndesStay-Guest` registrada como SPA con las dos redirect URIs
- [ ] API expuesta con scope `access_as_guest`
- [ ] Rol `Huesped` creado
- [ ] User flow `AndesStay-SignUpSignIn` creado **y asociado a la aplicación**
- [ ] Un huésped registrado desde el propio flujo, con rol asignado
- [ ] `AndesStay-Staff` registrada como SPA con las dos redirect URIs
- [ ] API expuesta con scope `access_as_staff`
- [ ] Roles `Admin`, `Recepcionista` y `Auditor` creados
- [ ] Un usuario de prueba por rol, con su rol asignado
- [ ] `../idaas/tenants.md` completo
- [ ] Token inspeccionado: `iss`, `aud`, `roles` y `scp` correctos
- [ ] Capturas de PKCE guardadas

---

# Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `AADSTS50011: redirect URI mismatch` | La URI del código no coincide con la registrada | Revisar Authentication; deben calzar exacto, incluido puerto y barra final |
| El BFF responde 401 con un login que se ve correcto | El token tiene `aud` de Graph | Pedir el scope propio `api://<client-id>/access_as_*` |
| El claim `roles` no aparece | El usuario no tiene el rol asignado en Enterprise applications | Asignar en Users and groups |
| `AADSTS700054: response_type 'id_token' is not enabled` | La app está registrada como Web | Cambiar la plataforma a SPA |
| El flujo de registro nunca aparece | El user flow no está asociado a la aplicación | Paso A.6.6 |
| Funciona en local y falla desplegado | Falta la redirect URI de producción | Paso A.3 |
| No se pueden asignar grupos a roles | La asignación por grupo requiere P1 | Asignar usuarios individualmente |
