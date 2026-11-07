"""Servidor del frontend (cliente web). Se ejecuta independiente del backend.

Uso:  python server.py
Solo entrega los archivos HTML/CSS/JS; el navegador consume el backend
directamente a través del API Gateway configurado en API_URL (.env).
"""
import json
import os
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, Response, send_from_directory

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

API_URL = os.getenv("API_URL", "http://127.0.0.1:5000").rstrip("/")
FRONT_HOST = os.getenv("FRONT_HOST", "0.0.0.0")
FRONT_PORT = int(os.getenv("FRONT_PORT", "8080"))

app = Flask(__name__, static_folder="static", static_url_path="/static")


@app.get("/")
def inicio():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/config.js")
def configuracion():
    """Configuración que lee el navegador: dónde está el backend."""
    return Response(f"window.APP_CONFIG = {json.dumps({'apiUrl': API_URL})};", mimetype="application/javascript")


if __name__ == "__main__":
    print(f"Frontend en http://{FRONT_HOST}:{FRONT_PORT}  ->  backend {API_URL}")
    app.run(host=FRONT_HOST, port=FRONT_PORT, threaded=True)
