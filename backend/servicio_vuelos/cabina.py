"""Configuración de cabina del avión (Airbus A340-600): clases, filas y columnas.

`grupos` son los bloques de asientos separados por pasillos.
`factor` multiplica el precio base del vuelo (precio de Economy).
"""
AVION = "Airbus A340-600"

CLASES = [
    {"clase": "FIRST", "nombre": "First", "filas": list(range(1, 3)),
     "grupos": [["A"], ["D", "G"], ["K"]], "factor": 6.0},
    {"clase": "BUSINESS", "nombre": "Business", "filas": list(range(4, 9)),
     "grupos": [["A", "C"], ["D", "G"], ["H", "K"]], "factor": 3.5},
    {"clase": "PREMIUM", "nombre": "Premium Economy", "filas": list(range(20, 24)),
     "grupos": [["A", "C"], ["D", "E", "F"], ["H", "K"]], "factor": 1.6},
    {"clase": "ECONOMY", "nombre": "Economy", "filas": list(range(31, 51)),
     "grupos": [["A", "C"], ["D", "E", "F", "G"], ["H", "K"]], "factor": 1.0},
]

# Asiento ("31A") -> clase ("ECONOMY")
ASIENTOS = {
    f"{fila}{letra}": c["clase"]
    for c in CLASES for fila in c["filas"] for grupo in c["grupos"] for letra in grupo
}
TOTAL_ASIENTOS = len(ASIENTOS)
FACTOR = {c["clase"]: c["factor"] for c in CLASES}


def precio_asiento(precio_base, asiento):
    return round(float(precio_base) * FACTOR[ASIENTOS[asiento]], 2)
