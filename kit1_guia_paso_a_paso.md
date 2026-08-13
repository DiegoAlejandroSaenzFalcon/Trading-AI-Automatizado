# Guía Operativa: Servicio de Nómina Electrónica para Tenderos

Esta guía detalla el paso a paso para ofrecer y ejecutar el servicio de gestión y transmisión de nómina electrónica ante la DIAN a pequeños negocios y tiendas de barrio (con 1 a 9 empleados).

---

## 1. El Marco Legal (Lo que debes saber)
* **Obligación:** Según la Resolución 000013 de 2021 de la DIAN, **todo empleador** en Colombia (incluyendo tenderos y microempresas con 1 solo empleado) debe transmitir mensualmente el Documento Soporte de Pago de Nómina Electrónica (DSPNE).
* **Plazo:** Se debe transmitir dentro de los primeros **10 días hábiles del mes siguiente** al pago (ej: la nómina de mayo se transmite entre el 1 y el 10 de junio).
* **La Herramienta Gratuita:** La DIAN cuenta con una herramienta web gratuita para empleadores de menos de 10 trabajadores. Esto significa que **no necesitas comprar ni desarrollar software costoso**: operas directamente usando el portal de la DIAN en nombre del tendero.

---

## 2. Requisitos Previos por Negocio
Antes de empezar a liquidar y transmitir, el establecimiento debe tener:
1. **RUT actualizado** con responsabilidad de facturador electrónico / nómina electrónica.
2. **Firma electrónica (certificado digital de la DIAN)** activo.
3. Estar habilitado en el portal de la DIAN como emisor de nómina electrónica (proceso de habilitación que se hace una sola vez).

---

## 3. Flujo Operativo Mensual (Paso a Paso)

### Paso 1: Recopilación de Novedades (Últimos días del mes)
* Contactas al tendero por WhatsApp y le pides los datos básicos de cada empleado del mes:
  * Días trabajados (si faltó o entró nuevo).
  * Horas extras o recargos (si aplica).
  * Préstamos o adelantos (si hubo).

### Paso 2: Liquidación y Cálculo
* Usas nuestra **Plantilla de Cálculo de Nómina** (puedes usar el script de Python `kit1_calculadora_nomina.py`) para calcular automáticamente:
  * Salario devengado según días trabajados.
  * Auxilio de transporte (si aplica por ley).
  * Aportes a Salud (4% empleado) y Pensión (4% empleado).
  * Neto a pagar al empleado.

### Paso 3: Transmisión en la DIAN
* Ingresas al portal de la DIAN con las credenciales del tendero.
* Seleccionas la herramienta gratuita de nómina electrónica.
* Ingresas los valores liquidados.
* Generas, firmas y transmites el documento soporte.
* Descargas el comprobante PDF/XML y se lo envías al tendero por WhatsApp como prueba de cumplimiento.

### Paso 4: Cobro del Servicio
* Envías tu cuenta de cobro o link de pago (Nequi / Daviplata) por el valor acordado (ej. $50.000 a $100.000 COP por mes).
