"""Fábrica común para crear cada servicio Flask con Swagger y manejo de errores."""
from flasgger import Swagger
from flask import Flask, jsonify

from common.errores import registrar_manejadores


def crear_app(import_name, nombre_servicio, descripcion, usa_bd=False, **kwargs):
    app = Flask(import_name, **kwargs)
    app.json.ensure_ascii = False
    app.json.sort_keys = False

    Swagger(app, template={
        "swagger": "2.0",
        "info": {"title": f"Servicio de {nombre_servicio}", "description": descripcion, "version": "1.0.0"},
        "consumes": ["application/json"],
        "produces": ["application/json"],
        "securityDefinitions": {
            "Bearer": {"type": "apiKey", "name": "Authorization", "in": "header",
                       "description": "Escriba: Bearer &lt;token&gt;"},
            "ServiceKey": {"type": "apiKey", "name": "X-Service-Key", "in": "header",
                           "description": "Clave interna entre servicios"},
        },
    })
    registrar_manejadores(app)

    @app.get("/api/salud")
    def salud():
        """Estado del servicio
        ---
        tags: [Salud]
        responses:
          200:
            description: El servicio está activo (incluye el estado de la base de datos si la usa)
        """
        datos = {"servicio": nombre_servicio, "estado": "activo"}
        if usa_bd:
            from sqlalchemy import text
            from common.db import engine
            try:
                with engine.connect() as con:
                    con.execute(text("SELECT 1"))
                datos["base_datos"] = "activa"
            except Exception:
                datos["base_datos"] = "caída"
        return jsonify(datos)

    return app
