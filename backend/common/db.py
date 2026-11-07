"""Conexión a PostgreSQL (Supabase) mediante SQLAlchemy + psycopg."""
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url

from common import config


def crear_engine(**kwargs):
    if not config.DATABASE_URL:
        raise RuntimeError("Falta DATABASE_URL en backend/.env (cadena de conexión de Supabase)")
    url = make_url(config.DATABASE_URL).set(drivername="postgresql+psycopg")
    connect_args = {
        # Cada conexión trabaja en hora de Ecuador (LOCALTIMESTAMP, CURRENT_DATE)
        "options": f"-c timezone={config.ZONA_HORARIA_BD}",
        # Compatible con el pooler de Supabase (no usa sentencias preparadas)
        "prepare_threshold": None,
    }
    if url.host not in (None, "localhost", "127.0.0.1"):
        connect_args["sslmode"] = "require"  # Supabase exige conexión cifrada (SSL)
    return create_engine(url, pool_pre_ping=True, pool_size=5, max_overflow=5,
                         connect_args=connect_args, **kwargs)


engine = crear_engine()
