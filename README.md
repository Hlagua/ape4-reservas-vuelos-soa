# APE 4: Sistema de reservas de vuelos con Arquitectura Orientada a Servicios (SOA)

Aplicación distribuida de reservas de vuelos:

- **Cliente:** Flutter (Android, Windows y web).
- **Backend:** servicios web **REST** en **Flask** que intercambian **JSON** y **XML** (facturas).
- **Base de datos:** **Supabase (PostgreSQL)** en la nube.
- **Despliegue:** el backend se publica en **Render** (HTTPS).

```
app_flutter/  cliente Flutter                                  (cada usuario)
backend/      API Gateway + 5 servicios REST (Flask)           (Render)
render.yaml   blueprint de despliegue en Render
frontend/     cliente web anterior (HTML + JS), ya no es el cliente principal
```

## Arquitectura

```
  App Flutter (usuario A)      App Flutter (usuario B)
            │      HTTPS · JSON / XML      │
            └──────────────┬───────────────┘
                           ▼
  ┌────────────────── Render (backend) ──────────────────────┐
  │              API Gateway  :$PORT  (público, CORS)         │
  │   ┌──────────┬──────────┬──────────┬──────────┬─────────┐ │
  │   ▼          ▼          ▼          ▼          ▼         │ │
  │ Usuarios   Auth       Vuelos    Reservas  Facturación   │ │
  │  :5001     :5002      :5003      :5004      :5005       │ │
  │                                                         │ │
  │ Auth ──► Usuarios        (valida credenciales)            │
  │ Vuelos ──► Auth          (valida token)                   │
  │ Reservas ──► Auth, Vuelos  (token, ocupa/libera asientos) │
  │ Facturación ──► Reservas (datos de la reserva → XML)      │
  └────────────────────────────┬─────────────────────────────┘
                               │ PostgreSQL · SSL
                               ▼
            Supabase: esquemas usuarios · autenticacion · vuelos · reservas
```

| Componente | Rol SOA | Consume a |
|---|---|---|
| App Flutter | Consumidor | API Gateway |
| API Gateway | Intermediario (enrutador, CORS) | Todos los servicios |
| Usuarios | Proveedor | — |
| Autenticación | Proveedor y consumidor | Usuarios |
| Vuelos | Proveedor y consumidor | Autenticación |
| Reservas | Proveedor y consumidor | Autenticación, Vuelos |
| Facturación | Proveedor y consumidor (sin base de datos) | Reservas |

- **Servicios autónomos:** cada servicio es un proceso con su propio puerto y es dueño de su esquema de datos. Los servicios se comunican solo por HTTP.
- **Contratos:** cada servicio publica su contrato OpenAPI (Swagger) en `/apidocs`.
- **Seguridad:**
  - JWT (`Authorization: Bearer <token>`) registrado en la tabla `autenticacion.tokens`; al cerrar sesión el token queda **REVOCADO**.
  - Contraseñas cifradas con **PBKDF2-SHA256**.
  - Clave interna `X-Service-Key` para los endpoints que solo usan otros servicios.
  - Conexión a Supabase con SSL.
- **Tolerancia a fallos:** si un servicio no responde se devuelve `503`, y si falla un paso de la reserva se liberan los asientos (compensación).

## Modelo de datos (Supabase / PostgreSQL)

Sigue el modelo de la guía (usuarios, vuelos, reservas y tokens), más las tablas de asientos y pasajeros que necesita el mapa de asientos:

| Esquema.tabla | Dueño | Columnas principales |
|---|---|---|
| `usuarios.usuarios` | Usuarios | **id** (PK), nombre, **correo** (único), password_hash, fecha_registro |
| `autenticacion.tokens` | Autenticación | **id** (PK), **usuario_id** (FK), jti, token_hash (SHA-256 del JWT), fecha_emision, expiracion, estado (ACTIVO/REVOCADO) |
| `vuelos.vuelos` | Vuelos | **id** (PK), codigo, aerolinea, origen, destino, **fecha**, **hora_salida**, **hora_llegada**, precio, asientos_totales, **asientos_disponibles** |
| `vuelos.asientos` | Vuelos | **PK (vuelo_id, asiento)**, vuelo_id (FK), clase, estado (BLOQUEADO/RETENIDO/OCUPADO), usuario_id, reserva_id, expira_en |
| `reservas.reservas` | Reservas | **id** (PK), **usuario_id** (FK), **vuelo_id** (FK), **cantidad_asientos**, total, estado, fecha_reserva |
| `reservas.pasajeros` | Reservas | id (PK), reserva_id (FK), asiento, clase, nombre, tipo_documento, documento, precio |

- **Relaciones 1:N:** un usuario tiene muchas reservas y muchos tokens; un vuelo tiene muchas reservas y muchos asientos; una reserva tiene de 1 a 5 pasajeros.
- **Columnas derivadas:** `fecha`, `hora_salida` y `hora_llegada` se calculan de `fecha_salida` y `fecha_llegada`.
- **`asientos_disponibles`:** la mantienen actualizada triggers sobre `vuelos.asientos`.
- **Token:** por seguridad no se guarda el JWT, sino su huella SHA-256.

## Concurrencia en la selección de asientos

1. Al tocar un asiento libre, Vuelos crea una **retención** de 5 minutos para ese usuario.
2. La app consulta el mapa **cada 3 segundos**: los demás usuarios ven el asiento en amarillo (*Bloqueado*).
3. Si dos usuarios lo toman al mismo tiempo, la **clave primaria `(vuelo_id, asiento)`** hace que PostgreSQL acepte solo a uno. El otro recibe `409`.
4. Al confirmar, los asientos pasan a *Ocupado* dentro de una transacción con `SELECT … FOR UPDATE` (todo o nada).
5. Si la reserva no se completa, la retención vence y el asiento queda libre.

## Contratos (endpoints)

Todas las rutas se consumen a través del Gateway: `https://<servicio>.onrender.com` (o `http://127.0.0.1:5000` en local).

| Servicio | Método y ruta | Auth | Descripción |
|---|---|---|---|
| Usuarios | `POST /api/usuarios/registro` (o `POST /api/usuarios`) | — | Registro `{nombre, email, password}` |
| Usuarios | `GET /api/usuarios/perfil` | Bearer | Perfil del usuario del token |
| Usuarios | `GET /api/usuarios/{id}` | Bearer | Consultar el propio usuario |
| Autenticación | `POST /api/auth/login` | — | Login → JWT (se guarda en `tokens`) |
| Autenticación | `GET /api/auth/verificar` | Bearer | Verifica firma, expiración y estado del token |
| Autenticación | `POST /api/auth/logout` | Bearer | Revoca el token |
| Vuelos | `GET /api/vuelos?origen=&destino=&fecha=&pasajeros=` | — | Consulta de vuelos |
| Vuelos | `GET /api/vuelos/ciudades` | — | Ciudades de origen y destino |
| Vuelos | `GET /api/vuelos/{id}/asientos` | Bearer opcional | Mapa de asientos por clase |
| Vuelos | `POST` / `DELETE /api/vuelos/{id}/asientos/{asiento}/retener` | Bearer | Seleccionar o soltar un asiento |
| Reservas | `POST /api/reservas` | Bearer | Reservar `{vuelo_id, pasajeros:[{asiento, nombre, tipo_documento, documento}]}` |
| Reservas | `POST /api/reservas` | Bearer | Formato de la guía: `{usuario_id, vuelo_id, cantidad}` → `{mensaje, reserva_id, total, estado: "confirmada"}` (asigna los asientos automáticamente) |
| Reservas | `GET /api/reservas` · `GET /api/reservas/{id}` | Bearer | Gestión: listar y consultar |
| Reservas | `PUT /api/reservas/{id}` · `DELETE /api/reservas/{id}` | Bearer | Gestión: modificar y cancelar |
| Facturación | `POST /api/facturas` | — | JSON `{factura, cliente, detalles}` → **XML** con IVA 15 % |
| Facturación | `GET /api/facturas/reserva/{id}` | Bearer | Factura **XML** de una reserva confirmada |

Errores: `{"error": "...", "detalle": {...}}`. Facturación, como el servicio visto en clase, responde `{"estado": "error", "mensaje": "Datos invalidos", "errores": [{"campo", "error"}]}`.

Ejemplo de factura (`application/xml`):

```xml
<Factura>
  <Cabecera><Numero>F001-000000001</Numero><Fecha>2026-11-07</Fecha></Cabecera>
  <Cliente><Nombre>Ana Ruiz</Nombre><CedulaRuc>1710034065</CedulaRuc></Cliente>
  <Vuelo><Codigo>IB1109015</Codigo><Origen>Quito</Origen><Destino>Guayaquil</Destino>...</Vuelo>
  <detalle><producto><nombre>Asiento 31C (ECONOMY) - Ana Ruiz</nombre><cantidad>1</cantidad>
    <precio_unitario>91.99</precio_unitario><subtotal>91.99</subtotal></producto></detalle>
  <totales><Subtotal>91.99</Subtotal><IVA>13.80</IVA><Total>105.79</Total></totales>
  <Estado>Generado</Estado>
</Factura>
```

## Campos controlados

Las mismas reglas se validan en la app (`app_flutter/lib/utils/validaciones.dart`) y en el backend (`backend/common/validaciones.py`):

| Campo | Regla |
|---|---|
| Nombre | 3 a 60 caracteres, solo letras y un espacio entre palabras |
| Email | Máximo 50 caracteres, sin mayúsculas y sin espacios, formato válido y único |
| Contraseña | 8 a 64 caracteres, con letras y números, sin espacios; la confirmación no se puede pegar |
| Cédula / pasaporte | Cédula ecuatoriana válida (módulo 10); pasaporte de 6 a 9 letras mayúsculas o números |
| Asientos | Máximo 5 por usuario y por reserva, sin asientos ni documentos repetidos |
| Búsqueda | Origen distinto del destino, fecha entre hoy y un año, de 1 a 5 pasajeros |

## Puesta en marcha

### 1. Base de datos en Supabase

1. Cree un proyecto en [supabase.com](https://supabase.com) (región `us-east-1`).
2. En **Connect > Session pooler**, copie la cadena de conexión `postgresql://postgres.<proyecto>:<clave>@aws-0-<region>.pooler.supabase.com:5432/postgres`.
3. Cree `backend/.env` a partir de `backend/.env.example` y pegue la cadena en `DATABASE_URL`.
4. Cree las tablas y los datos de ejemplo (30 días de vuelos y el usuario `demo@uta.edu.ec` / `demo1234`):

```bash
cd backend
```
```bash
python -m venv .venv
```
```bash
.venv\Scripts\pip install -r requirements.txt
```
```bash
.venv\Scripts\python -m database.init_db
```

`--reset` borra los esquemas del sistema y los vuelve a crear.

### 2. Backend en Render

1. En [render.com](https://render.com), entre a **New > Blueprint** y seleccione este repositorio: se usa `render.yaml`.
2. Cuando lo pida, ingrese `DATABASE_URL` (la misma cadena de Supabase). `JWT_SECRET` y `SERVICE_KEY` se generan solos.
3. Al terminar, el backend queda en `https://aeroreservas-backend.onrender.com` (o el nombre que asigne Render). Pruebe `.../api/salud`.

El plan gratuito de Render apaga el servicio tras 15 minutos sin uso, y la primera petición puede tardar cerca de un minuto. La app espera hasta 60 segundos.

Para ejecutar el backend en local con la misma base:

```bash
.venv\Scripts\python run_backend.py
```

### 3. App Flutter

```bash
cd app_flutter
```
```bash
flutter pub get
```
```bash
flutter run --dart-define=API_URL=https://aeroreservas-backend.onrender.com
```

- La dirección del backend también se puede cambiar dentro de la app, en **Estado > Cambiar dirección**.
- Use `-d windows`, `-d chrome` o un teléfono Android. Windows requiere el *Modo de desarrollador*.

### Demostración de la concurrencia

1. Abra la app en dos dispositivos con cuentas distintas y entre al mismo vuelo con **Asientos**.
2. Seleccione un asiento en el primero: en menos de 3 segundos aparece en amarillo en el segundo.
3. Si el segundo lo intenta tomar, recibe *"El asiento acaba de ser tomado por otro usuario"*.

## Pruebas

Con el backend levantado:

```bash
cd backend
```
```bash
.venv\Scripts\python -m pytest
```
```bash
cd app_flutter
```
```bash
flutter test
```

Cubren registro y validaciones, login, logout con revocación del token, perfil, búsqueda, mapa de asientos y **concurrencia**. Por ejemplo: 10 y 50 clientes simultáneos compiten por un asiento y solo uno lo obtiene, y no hay doble venta al reservar. También cubren reservar, modificar y cancelar, la factura XML (IVA 15 % y errores por campo), los permisos, los endpoints internos y el caso de un servicio caído (503).

La colección `backend/postman/APE4.postman_collection.json` se ejecuta con el *Collection Runner* de Postman.
