"""Detiene o inicia un servicio del backend para probar la tolerancia a fallos.

Uso (en local o contra Render):
    python servicio.py estado
    python servicio.py detener vuelos
    python servicio.py iniciar vuelos
    python servicio.py detener vuelos --url https://aeroreservas-backend.onrender.com

Servicios: usuarios, auth, vuelos, reservas, facturas.
La clave se toma de ADMIN_KEY (backend/.env o variable de entorno). El Gateway no se puede
detener por aquí: es el punto de entrada y el supervisor lo reinicia si se cae.
"""
import argparse
import os
import sys

import requests

from common import config


def main():
    parser = argparse.ArgumentParser(description="Control de servicios para pruebas de tolerancia a fallos")
    parser.add_argument("accion", choices=["estado", "detener", "iniciar"])
    parser.add_argument("servicio", nargs="?", choices=["usuarios", "auth", "vuelos", "reservas", "facturas"])
    parser.add_argument("--url", default=os.getenv("API_URL", f"http://127.0.0.1:{config.GATEWAY_PORT}"),
                        help="Dirección del API Gateway (local o Render)")
    args = parser.parse_args()
    if args.accion != "estado" and not args.servicio:
        parser.error("indique el servicio")
    if not config.ADMIN_KEY:
        sys.exit("Falta ADMIN_KEY en backend/.env")

    base = args.url.rstrip("/")
    cabeceras = {"X-Admin-Key": config.ADMIN_KEY}
    if args.accion == "estado":
        resp = requests.get(f"{base}/api/admin/servicios", headers=cabeceras, timeout=90)
    else:
        resp = requests.post(f"{base}/api/admin/servicios/{args.servicio}/{args.accion}", headers=cabeceras,
                             timeout=120)
    datos = resp.json()
    if resp.status_code != 200:
        sys.exit(f"Error {resp.status_code}: {datos.get('error')}")
    if datos.get("mensaje"):
        print(datos["mensaje"])
    for clave, s in datos["servicios"].items():
        print(f"  {s['nombre']:<15} {clave:<9} {s['proceso']}")


if __name__ == "__main__":
    main()
