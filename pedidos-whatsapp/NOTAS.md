# Notas de desarrollo — Pedidos WhatsApp (multi-cliente + KDS + POS)

> Documento vivo para pruebas y mejoras. NO se commitea ningún dato privado (ver `.gitignore`).
> Objetivo: publicar en GitHub cuando el sistema esté 100% terminado.

## Propósito
Bot de pedidos por WhatsApp **adaptable a varios clientes** (no exclusivo de uno), con:
- Toma de pedidos y cobro automático desde el menú.
- Gestor de pedidos / KDS (estados: recibido → en_cocina → listo → entregado/cancelado).
- Integración con POS existentes (y base para construir el nuestro).
- Modelo de negocio: pocos clientes, mensualidad.

## Cliente piloto
- Negocio familiar de comida rápida (ex vecino del dueño), ya interesado.
- Menú cargado: 78 productos (hamburguesas, perros, mazorcadas, salchipapas, platos, jugos, bebidas, adicionales) en `config.json` / `clientes/*.json` (archivos privados, no se commitean).

## Arquitectura implementada (fase actual)
- **Multi-cliente por instancia**: `node index.js --cliente clientes/<id>.json` (o env `CLIENTE_CONFIG`).
  - Sin parámetro usa `config.json` (modo histórico, compatible).
  - Cada cliente tiene datos y sesión de WhatsApp aislados: `data/<id>/` y `auth_info_<id>/`, y su propio `puerto`.
- **Integración POS genérica** (`core/integracion.js`): contrato JSON estándar + adaptadores `webhook | archivo | telegram | kds`. Se dispara al guardar cada pedido.
  - Para conectar cualquier POS: poner `"integracion":{"tipo":"webhook","url":"..."}` en el config del cliente.
- **KDS** en el panel web: botones de estado por pedido + al marcar "Listo" se avisa al cliente por WhatsApp.
- **Conversaciones** (`core/conversacion.js`): se guarda cada mensaje (cliente/bot) por número; el panel tiene pestaña "Conversaciones" para auditar cómo responde el bot.

## Lanzadores
- `iniciar-cliente.bat <nombre>` → un cliente.
- `lanzar-todos.bat` → abre una ventana por cada `clientes/*.json`.

## Privacidad / Legal / GitHub (IMPORTANTE)
- `.gitignore` excluye: `config.json`, `clientes/`, `data/`, `auth_info*/`, `backup*/`, `*.jsonl`, `.llm_key`, `.env`.
- **Nunca commitear**: claves API, número del dueño, menús de clientes reales, ni PII de pedidos (nombres, teléfonos, GPS, conversaciones).
- Plantillas seguras para el repo: `config.example.json` y `clientes/EJEMPLO.json` (sin claves ni datos reales).
- Publicar solo cuando esté 100% terminado.

## Pendientes / mejoras sugeridas
1. **Parser de plurales**: hoy "2 perros transmilenio" no se detecta (sí "2 perro transmilenio"). Mejorar para la demo.
2. **Vista Cocina** a pantalla completa (grande, solo ítems y tiempos).
3. Notificación al cliente cuando el bot de WhatsApp NO está conectado (¿email/SMS/cola?).
4. Confirmar con el ex vecino: ¿qué POS usa? → elegir adaptador real (webhook/API de Siigo/Alegra/etc.).
5. Definir si el "nuestro POS" evoluciona a facturación electrónica DIAN (posterior).
6. Multi-cliente: confirmar si se queda en "instancia por cliente" o se pasa a panel central híbrido.

## Incidente 2026-08-13 — prueba con "cliente difícil"
Síntoma reportado: "antes era demasiado inteligente, ahora es idiota".
Causas encontradas y corregidas:
1. **Cuota de Gemini (RAÍZ):** el LLM usa Gemini gratis (20 consultas/día). Al agotarse la cuota, cada llamada da error y el bot caía en bucle del mensaje de bienvenida. Solución recomendada: usar **Groq gratis** (llave en `config.json` → `llm.api_key`, provider `groq`, modelo `llama-3.1-8b-instant`) en vez del límite de 20/día. Mientras haya cuota, el bot es "inteligente"; sin ella, el fallback evita el bucle.
2. **Parser interpretaba preguntas como pedidos:** "¿Qué trae la hamburguesa especial?" generaba un pedido #8 falso. Corregido: si el texto es pregunta (¿? o palabras qué/cuánto/trae/me dices…), no se convierte en orden.
3. **Plurales no detectados:** "2 perros transmilenio" no se tomaba. Corregido: alias tolerantes a plural (`s?` por palabra).
4. **La IA se inventaba "se reinició" y datos falsos de ingredientes.** Corregido en el system prompt (reglas 7 y 8): nunca afirmar reinicios/errores técnicos ni inventar ingredientes; solo confirmar nombre+precio y derivar al local.
5. **Fallback de IA:** al fallar la IA ahora responde `mensaje_fallback` (no el de bienvenida, ni afirma reinicios).

Pendiente: agregar llave de Groq (o OpenRouter) para que la demo no se quede "tonta" tras 20 mensajes.

## Nota del dueño ("quiero que notes algo")
> [Pendiente de la próxima interacción — completar aquí lo que el usuario indique.]
