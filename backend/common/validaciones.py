"""Reglas de validación de los campos que llena el usuario (las mismas que usa el frontend)."""
import re

NOMBRE_MAX = 60
EMAIL_MAX = 50
PASSWORD_MIN, PASSWORD_MAX = 8, 64

NOMBRE_RE = re.compile(r"^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+( [A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+)*$")
# Solo minúsculas, números y . _ % + - ; un único @ y un dominio con extensión
EMAIL_RE = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$")
PASAPORTE_RE = re.compile(r"^[A-Z0-9]{6,9}$")


def validar_nombre(valor):
    if not valor:
        return "El nombre es obligatorio"
    if not 3 <= len(valor) <= NOMBRE_MAX:
        return f"Debe tener entre 3 y {NOMBRE_MAX} caracteres"
    if not NOMBRE_RE.match(valor):
        return "Solo se permiten letras y un espacio entre palabras, sin espacios al inicio ni al final"
    return None


def validar_email(valor):
    if not valor:
        return "El email es obligatorio"
    if len(valor) > EMAIL_MAX:
        return f"Máximo {EMAIL_MAX} caracteres"
    if re.search(r"\s", valor):
        return "No se permiten espacios"
    if valor != valor.lower():
        return "No se permiten letras mayúsculas"
    if not EMAIL_RE.match(valor) or ".." in valor or valor.startswith(".") or ".@" in valor:
        return "Formato de email inválido"
    return None


def validar_password(valor):
    if not valor:
        return "La contraseña es obligatoria"
    if re.search(r"\s", valor):
        return "La contraseña no puede contener espacios"
    if not PASSWORD_MIN <= len(valor) <= PASSWORD_MAX:
        return f"Debe tener entre {PASSWORD_MIN} y {PASSWORD_MAX} caracteres"
    if not re.search(r"[A-Za-z]", valor) or not re.search(r"\d", valor):
        return "Debe contener al menos una letra y un número"
    return None


def cedula_valida(cedula):
    """Algoritmo módulo 10 de la cédula ecuatoriana."""
    if not re.fullmatch(r"\d{10}", cedula):
        return False
    provincia, tercer_digito = int(cedula[:2]), int(cedula[2])
    if not (1 <= provincia <= 24 or provincia == 30) or tercer_digito >= 6:
        return False
    suma = 0
    for i, digito in enumerate(cedula[:9]):
        valor = int(digito) * (2 if i % 2 == 0 else 1)
        suma += valor - 9 if valor > 9 else valor
    return (10 - suma % 10) % 10 == int(cedula[9])


def validar_documento(tipo, numero):
    if not numero:
        return "El documento es obligatorio"
    if tipo == "CEDULA":
        return None if cedula_valida(numero) else "Cédula ecuatoriana inválida"
    if tipo == "PASAPORTE":
        return None if PASAPORTE_RE.match(numero) else "El pasaporte debe tener de 6 a 9 letras mayúsculas o números"
    return "El tipo de documento debe ser CEDULA o PASAPORTE"
