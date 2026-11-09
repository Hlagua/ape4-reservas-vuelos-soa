"""Formato uniforme de errores JSON para todos los servicios."""
from flask import jsonify
from sqlalchemy.exc import DisconnectionError, InterfaceError, OperationalError, SQLAlchemyError
from sqlalchemy.exc import TimeoutError as TiempoAgotadoPool
from werkzeug.exceptions import HTTPException


class ErrorApi(Exception):
    """Error controlado que se devuelve al cliente como JSON."""

    def __init__(self, mensaje, codigo=400, detalle=None):
        super().__init__(mensaje)
        self.mensaje = mensaje
        self.codigo = codigo
        self.detalle = detalle


def respuesta_error(mensaje, codigo, detalle=None):
    cuerpo = {"error": mensaje}
    if detalle is not None:
        cuerpo["detalle"] = detalle
    return jsonify(cuerpo), codigo


def registrar_manejadores(app):
    @app.errorhandler(ErrorApi)
    def _error_api(e):
        return respuesta_error(e.mensaje, e.codigo, e.detalle)

    @app.errorhandler(HTTPException)
    def _error_http(e):
        return respuesta_error(e.name, e.code, e.description)

    @app.errorhandler(SQLAlchemyError)
    def _error_bd(e):
        if getattr(getattr(e, "orig", None), "sqlstate", None) in ("40P01", "40001"):
            # PostgreSQL abortó la transacción por interbloqueo (deadlock) o conflicto de serialización
            return respuesta_error("Conflicto de concurrencia, intente de nuevo", 409)
        if isinstance(e, (OperationalError, InterfaceError, DisconnectionError, TiempoAgotadoPool)):
            # No hay conexión con PostgreSQL (Supabase caído, red, límite de conexiones...)
            app.logger.error("Base de datos no disponible: %s", str(getattr(e, "orig", e)).splitlines()[0])
            return respuesta_error("Base de datos no disponible", 503, "Intente de nuevo en unos momentos")
        app.logger.exception("Error de base de datos")
        return respuesta_error("Error de base de datos", 500, str(e.__class__.__name__))

    @app.errorhandler(Exception)
    def _error_general(e):
        app.logger.exception("Error no controlado")
        return respuesta_error("Error interno del servidor", 500, str(e))


def leer_json(request):
    """Obtiene el cuerpo JSON o lanza 400 si no se envió."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ErrorApi("Debe enviar un JSON", 400)
    return data
