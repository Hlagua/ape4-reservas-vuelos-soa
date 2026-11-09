"""Configuración compartida por todos los servicios (se lee desde .env o de las variables de Render)."""
import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

# Base de datos PostgreSQL (Supabase). Ejemplo del "Session pooler" de Supabase:
# postgresql://postgres.<proyecto>:<clave>@aws-0-<region>.pooler.supabase.com:5432/postgres
DATABASE_URL = os.getenv("DATABASE_URL", "")

# Las fechas de los vuelos se manejan en hora de Ecuador, sin importar dónde corra el servidor
ZONA_HORARIA = os.getenv("ZONA_HORARIA", "America/Guayaquil")
# Desfase fijo para la sesión de PostgreSQL (Ecuador no tiene horario de verano)
ZONA_HORARIA_BD = os.getenv("ZONA_HORARIA_BD", "-05")

JWT_SECRET = os.getenv("JWT_SECRET", "cambiar-esta-clave")
JWT_HORAS = int(os.getenv("JWT_HORAS", "2"))
SERVICE_KEY = os.getenv("SERVICE_KEY", "clave-interna")
# Clave para detener/iniciar servicios desde el Gateway (pruebas de tolerancia a fallos).
# Si está vacía, la administración queda deshabilitada.
ADMIN_KEY = os.getenv("ADMIN_KEY", "")

# Host de los servicios internos y del Gateway (en Render los internos quedan en 127.0.0.1)
BIND_HOST = os.getenv("BIND_HOST", "0.0.0.0")
GATEWAY_HOST = os.getenv("GATEWAY_HOST", BIND_HOST)
RETENCION_MINUTOS = int(os.getenv("RETENCION_MINUTOS", "5"))
# Máximo de asientos que un usuario puede seleccionar / pasajeros por reserva
MAX_ASIENTOS = int(os.getenv("MAX_ASIENTOS", "5"))
IVA_PORCENTAJE = float(os.getenv("IVA_PORCENTAJE", "0.15"))

# Render asigna el puerto público en la variable PORT
GATEWAY_PORT = int(os.getenv("PORT") or os.getenv("GATEWAY_PORT", "5000"))
USUARIOS_PORT = int(os.getenv("USUARIOS_PORT", "5001"))
AUTH_PORT = int(os.getenv("AUTH_PORT", "5002"))
VUELOS_PORT = int(os.getenv("VUELOS_PORT", "5003"))
RESERVAS_PORT = int(os.getenv("RESERVAS_PORT", "5004"))
FACTURACION_PORT = int(os.getenv("FACTURACION_PORT", "5005"))
# Control interno del supervisor (run_backend.py); solo escucha en 127.0.0.1
SUPERVISOR_PORT = int(os.getenv("SUPERVISOR_PORT", "5099"))

# Registro de servicios: dónde vive cada proveedor
USUARIOS_URL = os.getenv("USUARIOS_URL", f"http://127.0.0.1:{USUARIOS_PORT}")
AUTH_URL = os.getenv("AUTH_URL", f"http://127.0.0.1:{AUTH_PORT}")
VUELOS_URL = os.getenv("VUELOS_URL", f"http://127.0.0.1:{VUELOS_PORT}")
RESERVAS_URL = os.getenv("RESERVAS_URL", f"http://127.0.0.1:{RESERVAS_PORT}")
FACTURACION_URL = os.getenv("FACTURACION_URL", f"http://127.0.0.1:{FACTURACION_PORT}")
SUPERVISOR_URL = f"http://127.0.0.1:{SUPERVISOR_PORT}"


def ahora():
    """Fecha y hora actual de Ecuador (sin zona, igual que las columnas de la base)."""
    return datetime.now(ZoneInfo(ZONA_HORARIA)).replace(tzinfo=None)
