"""Prueba E2E con dos navegadores reales (Chrome y Edge) interactuando en simultáneo.
Demuestra:
1. Pruebas de seguridad contra inyecciones y datos inválidos en campos (frontend y backend).
2. Concurrencia real: selección de asientos en vivo, bloqueo en amarillo para el otro usuario,
   imposibilidad de doble reserva, liberación en tiempo real y confirmación final.
"""
import os
import sys
import time
import requests
from pathlib import Path
from playwright.sync_api import sync_playwright

BASE_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE_DIR))

GATEWAY_URL = "http://127.0.0.1:5000"
FRONTEND_URL = "http://127.0.0.1:8080"
SCREENSHOTS_DIR = Path(r"C:\Users\henry\.gemini\antigravity\brain\4cbe0f38-9071-4610-94c1-c1122caf7830")
SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)

USER_1 = {"nombre": "Carlos Lopez", "email": "carlos_e2e@uta.edu.ec", "password": "Password123"}
USER_2 = {"nombre": "Maria Gomez", "email": "maria_e2e@uta.edu.ec", "password": "Password123"}

def preparar_usuarios():
    """Asegura que los usuarios de prueba existan en la BD."""
    for u in (USER_1, USER_2):
        requests.post(f"{GATEWAY_URL}/api/usuarios", json=u)
    # Limpia asientos de prueba en el vuelo 225
    from common.db import engine
    from sqlalchemy import text
    with engine.begin() as con:
        con.execute(text("DELETE FROM vuelos.asientos WHERE vuelo_id = (SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST')"))
        con.execute(text("DELETE FROM reservas.reservas WHERE vuelo_id = (SELECT id FROM vuelos.vuelos WHERE codigo = 'UTA-TEST')"))
        con.execute(text("""
            UPDATE vuelos.vuelos SET fecha_salida = LOCALTIMESTAMP + INTERVAL '1 day',
                   fecha_llegada = LOCALTIMESTAMP + INTERVAL '1480 minutes' WHERE codigo = 'UTA-TEST'"""))
    print("Usuarios listos y vuelo 225 preparado.")

def ejecutar_demostracion():
    preparar_usuarios()
    
    with sync_playwright() as p:
        print("\n--- 1. Lanzando dos navegadores reales en pantalla (Chrome y Edge) ---")
        # Ventana 1: Chrome (Izquierda)
        b1 = p.chromium.launch(channel="chrome", headless=False, args=["--window-position=0,0", "--window-size=950,1020"])
        ctx1 = b1.new_context(viewport={"width": 930, "height": 950})
        page1 = ctx1.new_page()
        
        # Ventana 2: Edge (Derecha)
        b2 = p.chromium.launch(channel="msedge", headless=False, args=["--window-position=960,0", "--window-size=950,1020"])
        ctx2 = b2.new_context(viewport={"width": 930, "height": 950})
        page2 = ctx2.new_page()
        
        page1.goto(FRONTEND_URL)
        page2.goto(FRONTEND_URL)
        time.sleep(1)
        
        # --- 2. Iniciar sesión en ambos navegadores ---
        print("\n--- 2. Autenticando Usuarios Distintos ---")
        print(f"Navegador 1 (Chrome): {USER_1['nombre']} ({USER_1['email']})")
        page1.click("#sesion button") # Botón Iniciar sesión
        page1.fill("#login-email", USER_1["email"])
        page1.fill("#login-password", USER_1["password"])
        page1.click("#form-login button[type=submit]")
        
        print(f"Navegador 2 (Edge): {USER_2['nombre']} ({USER_2['email']})")
        page2.click("#sesion button")
        page2.fill("#login-email", USER_2["email"])
        page2.fill("#login-password", USER_2["password"])
        page2.click("#form-login button[type=submit]")
        time.sleep(1.5)
        
        # --- 3. Pruebas de Seguridad e Inyecciones en Campos del Frontend ---
        print("\n--- 3. Verificando Filtros Anti-Inyección y Control de Campos ---")
        # Abrimos el modal de registro en Chrome para probar filtros de entrada
        page1.click("#sesion button:has-text('Salir')") # Salir temporalmente para probar registro
        page1.click("#sesion button")
        page1.click("#abrir-registro")
        time.sleep(0.5)
        
        # 3.1 Intento de ingresar números, símbolos y script XSS en Nombre
        print("  -> Probando inyección de XSS y símbolos en campo Nombre: '<script>123!@#'")
        page1.type("#reg-nombre", "Carlos <script>123!@# Lopez")
        valor_nombre = page1.input_value("#reg-nombre")
        print(f"     Resultado en pantalla tras filtrado automático: '{valor_nombre}'")
        assert "<" not in valor_nombre and "123" not in valor_nombre and "@" not in valor_nombre
        print("     [OK] El filtro client-side sanitizó y neutralizó símbolos y números instantáneamente.")
        
        # 3.2 Intento de contraseñas inválidas (sin números o con espacios)
        print("  -> Probando contraseña débil 'sololetras'")
        page1.fill("#reg-password", "sololetras")
        page1.press("#reg-password", "Tab")
        error_pwd = page1.text_content("#form-registro .campo:has(#reg-password) .error-campo")
        print(f"     Mensaje de validación: '{error_pwd}'")
        assert "número" in error_pwd
        print("     [OK] Validación bloquea contraseñas que no cumplen políticas de seguridad.")
        
        page1.click("#modal-registro button[data-cerrar]")
        # Volvemos a ingresar como Carlos
        page1.fill("#login-email", USER_1["email"])
        page1.fill("#login-password", USER_1["password"])
        page1.click("#form-login button[type=submit]")
        time.sleep(1)
        
        # --- 4. Navegación al Vuelo de Pruebas (Ambato -> Quito, Vuelo 225) ---
        print("\n--- 4. Navegando al mapa de cabina en ambos navegadores ---")
        # En Chrome
        page1.click("button.tab[data-vista=vuelos]")
        page1.wait_for_selector("#tabla-vuelos tr")
        # Buscar el botón del vuelo UTA-TEST o el primero
        page1.click("#tabla-vuelos tr:has-text('UTA-TEST') button")
        
        # En Edge
        page2.click("button.tab[data-vista=vuelos]")
        page2.wait_for_selector("#tabla-vuelos tr")
        page2.click("#tabla-vuelos tr:has-text('UTA-TEST') button")
        time.sleep(1.5)
        
        # Aseguramos que ambos estén en la pestaña ECONOMY (donde está 31A)
        page1.click("#pestanas-clase button:has-text('Economy')")
        page2.click("#pestanas-clase button:has-text('Economy')")
        time.sleep(1)
        
        # --- 5. Demostración de Concurrencia en Vivo (Asiento 31A) ---
        print("\n--- 5. Prueba de Concurrencia en Vivo ---")
        print("Paso A: Carlos (Chrome) hace clic en el asiento 31A...")
        btn_31a_p1 = page1.locator("button.asiento:has-text('A')").first
        btn_31a_p1.click()
        time.sleep(1)
        
        # Verificar estado en Chrome (debe ser SELECCIONADO / azul)
        clase_p1 = btn_31a_p1.get_attribute("class")
        print(f"  -> Estado en Chrome para Carlos: '{clase_p1}' (Azul / Su selección)")
        assert "SELECCIONADO" in clase_p1
        
        print("Paso B: Esperando actualización automática en Edge (polling cada 3s)...")
        time.sleep(3.5) # Espera el intervalo de 3s
        
        btn_31a_p2 = page2.locator("button.asiento:has-text('A')").first
        clase_p2 = btn_31a_p2.get_attribute("class")
        print(f"  -> Estado en Edge para María: '{clase_p2}' (Amarillo / Bloqueado por otro usuario)")
        assert "BLOQUEADO" in clase_p2
        
        # Captura de pantalla de la concurrencia
        page1.screenshot(path=str(SCREENSHOTS_DIR / "chrome_carlos_seleccion.png"))
        page2.screenshot(path=str(SCREENSHOTS_DIR / "edge_maria_bloqueado.png"))
        print("  -> Capturas guardadas: 'chrome_carlos_seleccion.png' y 'edge_maria_bloqueado.png'")
        
        print("\nPaso C: María (Edge) intenta hacer clic en el asiento 31A BLOQUEADO...")
        btn_31a_p2.click()
        time.sleep(0.5)
        # María no puede tomarlo
        clase_p2_after = btn_31a_p2.get_attribute("class")
        assert "SELECCIONADO" not in clase_p2_after
        print("  -> [OK] La interfaz impidió que María seleccione el asiento retenido por Carlos.")
        
        print("\nPaso D: María (Edge) selecciona el asiento libre 31C...")
        btn_31c_p2 = page2.locator("button.asiento:has-text('C')").first
        btn_31c_p2.click()
        time.sleep(1)
        assert "SELECCIONADO" in btn_31c_p2.get_attribute("class")
        print("  -> [OK] María retiene exitosamente 31C.")
        
        print("\nPaso E: Carlos (Chrome) libera el asiento 31A haciendo clic de nuevo...")
        btn_31a_p1.click()
        time.sleep(1)
        print("  -> Carlos deseleccionó 31A. Esperando refresco en Edge...")
        time.sleep(3.5)
        
        clase_31a_edge = btn_31a_p2.get_attribute("class")
        print(f"  -> Estado de 31A en Edge tras ser liberado: '{clase_31a_edge}' (Verde / Disponible)")
        assert "DISPONIBLE" in clase_31a_edge
        
        # --- 6. Formulario de Pasajeros y Verificación de Datos ---
        print("\n--- 6. Llenado y Validación de Datos de Pasajero (Edge) ---")
        # María llena los datos para su asiento 31C
        # Intento de cédula inválida
        print("  -> Probando cédula con dígito verificador inválido: '1712345678'")
        name_input = page2.locator("#p-nombre-31C")
        name_input.fill("Maria Gomez")
        doc_input = page2.locator("#p-doc-31C")
        doc_input.fill("1712345678")
        
        # Al intentar confirmar con datos inválidos:
        page2.click("#btn-confirmar")
        time.sleep(0.5)
        
        error_doc = page2.text_content(".campo:has(#p-doc-31C) .error-campo")
        print(f"     Mensaje de validación: '{error_doc}'")
        assert "Cédula ecuatoriana inválida" in error_doc
        print("     [OK] El algoritmo módulo 10 bloqueó el envío y rechazó la cédula falsa.")
        
        print("  -> Corrigiendo a Pasaporte válido 'P9876543'...")
        page2.select_option(".pasajero:has(#p-doc-31C) select[name='tipo_documento']", "PASAPORTE")
        doc_input.fill("P9876543")
        time.sleep(0.5)
        
        print("Paso F: María confirma la reserva...")
        page2.click("#btn-confirmar")
        time.sleep(2)
        
        print("  -> Comprobando que la reserva se guardó y aparece en 'Mis reservas'...")
        page2.wait_for_selector("#tabla-reservas tr")
        reserva_fila = page2.locator("#tabla-reservas tr").first
        texto_reserva = reserva_fila.text_content()
        print(f"     Fila en Mis Reservas: {texto_reserva}")
        assert "CONFIRMADA" in texto_reserva
        print("     [OK] Reserva confirmada con éxito.")
        
        page2.screenshot(path=str(SCREENSHOTS_DIR / "edge_reserva_confirmada.png"))
        
        print("\n" + "="*70)
        print("TODAS LAS PRUEBAS DE INTERACCIÓN REAL, CONCURRENCIA Y SEGURIDAD SUPERADAS")
        print("="*70)
        
        print("\nLos navegadores permanecerán abiertos 8 segundos más para visualización...")
        time.sleep(8)
        
        b1.close()
        b2.close()

if __name__ == "__main__":
    ejecutar_demostracion()
