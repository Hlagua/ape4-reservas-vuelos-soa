"""Servicio de Usuarios (proveedor): registro y consulta de usuarios.

Es el único dueño del esquema `usuarios`. El servicio de Autenticación
lo consume para validar credenciales.
"""
from flask import jsonify, request
from sqlalchemy import text
from werkzeug.security import check_password_hash, generate_password_hash

from common import config
from common.app_base import crear_app
from common.clientes import requerir_clave_servicio, requerir_token
from common.db import engine
from common.errores import ErrorApi, leer_json
from common.validaciones import validar_email, validar_nombre, validar_password

app = crear_app(__name__, "Usuarios", "Registro y consulta de usuarios del sistema de reservas", usa_bd=True)


def cifrar(password):
    """Contraseña cifrada con PBKDF2-SHA256 (nunca se guarda en texto plano)."""
    return generate_password_hash(password, method="pbkdf2:sha256")


def usuario_a_dict(fila):
    return {
        "id": fila.id,
        "nombre": fila.nombre,
        "email": fila.correo,
        "fecha_registro": fila.fecha_registro.isoformat(timespec="seconds"),
    }


@app.post("/api/usuarios/registro")
@app.post("/api/usuarios")
def registrar_usuario():
    """Registrar un nuevo usuario (también disponible en POST /api/usuarios)
    ---
    tags: [Usuarios]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          required: [nombre, email, password]
          properties:
            nombre: {type: string, example: Juan Pérez, description: "Solo letras, 3 a 60 caracteres"}
            email: {type: string, example: juan@uta.edu.ec, description: "Máximo 50, sin mayúsculas ni espacios"}
            password: {type: string, example: secreto123, description: "8 a 64 caracteres, letras y números, sin espacios"}
    responses:
      201: {description: Usuario registrado}
      400: {description: Datos inválidos}
      409: {description: El email ya está registrado}
    """
    data = leer_json(request)
    # Se valida el valor tal como llega: espacios extra o mayúsculas en el email son errores
    nombre = str(data.get("nombre", ""))
    email = str(data.get("email", ""))
    password = str(data.get("password", ""))

    errores = {}
    for campo, error in (("nombre", validar_nombre(nombre)), ("email", validar_email(email)),
                         ("password", validar_password(password))):
        if error:
            errores[campo] = error
    if errores:
        raise ErrorApi("Datos inválidos", 400, errores)

    with engine.begin() as con:
        existe = con.execute(text("SELECT 1 FROM usuarios.usuarios WHERE correo = :email"), {"email": email}).first()
        if existe:
            raise ErrorApi("El email ya está registrado", 409)
        fila = con.execute(text("""
            INSERT INTO usuarios.usuarios (nombre, correo, password_hash)
            VALUES (:nombre, :email, :hash)
            RETURNING id, nombre, correo, fecha_registro
        """), {"nombre": nombre, "email": email, "hash": cifrar(password)}).first()

    return jsonify({"mensaje": "Usuario registrado correctamente", "usuario": usuario_a_dict(fila)}), 201


@app.get("/api/usuarios/perfil")
def perfil():
    """Perfil del usuario autenticado
    ---
    tags: [Usuarios]
    security: [{Bearer: []}]
    responses:
      200: {description: Datos del usuario del token}
      401: {description: Token inválido o ausente}
    """
    return jsonify(buscar_usuario(requerir_token()["id"]))


@app.get("/api/usuarios/<int:usuario_id>")
def obtener_usuario(usuario_id):
    """Consultar un usuario (solo el propio usuario autenticado)
    ---
    tags: [Usuarios]
    security: [{Bearer: []}]
    parameters:
      - {in: path, name: usuario_id, type: integer, required: true}
    responses:
      200: {description: Datos del usuario}
      401: {description: Token inválido o ausente}
      403: {description: No puede consultar otro usuario}
      404: {description: Usuario no encontrado}
    """
    actual = requerir_token()
    if actual["id"] != usuario_id:
        raise ErrorApi("No tiene permiso para consultar este usuario", 403)
    return jsonify(buscar_usuario(usuario_id))


def buscar_usuario(usuario_id):
    with engine.connect() as con:
        fila = con.execute(text("""
            SELECT id, nombre, correo, fecha_registro FROM usuarios.usuarios WHERE id = :id
        """), {"id": usuario_id}).first()
    if not fila:
        raise ErrorApi("Usuario no encontrado", 404)
    return usuario_a_dict(fila)


@app.post("/api/usuarios/validar-credenciales")
def validar_credenciales():
    """[Interno] Validar email y contraseña (usado por el servicio de Autenticación)
    ---
    tags: [Interno]
    security: [{ServiceKey: []}]
    parameters:
      - in: body
        name: body
        required: true
        schema:
          type: object
          properties:
            email: {type: string}
            password: {type: string}
    responses:
      200: {description: Credenciales válidas, devuelve el usuario}
      401: {description: Credenciales inválidas}
      403: {description: Falta la clave de servicio}
    """
    requerir_clave_servicio()
    data = leer_json(request)
    email = str(data.get("email", "")).strip().lower()
    with engine.connect() as con:
        fila = con.execute(text("""
            SELECT id, nombre, correo, password_hash, fecha_registro FROM usuarios.usuarios WHERE correo = :email
        """), {"email": email}).first()
    if not fila or not check_password_hash(fila.password_hash, str(data.get("password", ""))):
        raise ErrorApi("Credenciales inválidas", 401)
    return jsonify(usuario_a_dict(fila))


if __name__ == "__main__":
    app.run(host=config.BIND_HOST, port=config.USUARIOS_PORT, threaded=True)
