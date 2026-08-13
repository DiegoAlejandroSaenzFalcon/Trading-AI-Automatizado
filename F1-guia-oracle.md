# F1 - Oracle Cloud Free Tier: guía de alta

## Qué vas a necesitar (5 min)
- Tu correo electrónico (el que usaste con GitHub: diegoalejandrosaenzfalcon@gmail.com)
- Una tarjeta de débito o crédito (SOLO se usa para verificar identidad; se hace un
  cargo temporal de ~$1 que se REVOCA automáticamente. Oracle NO cobra nada mientras
  te mantengas dentro del Free Tier)
- Tu teléfono (verificación por SMS o llamada)
- Documento de identidad a mano (en algunos países Oracle pide verificación extra)

## Pasos exactos

1. Entra a:  https://signup.oraclecloud.com
2. Pon tu correo y elige una contraseña fuerte (guárdala en tu gestor de contraseñas).
   Mismo correo es recomendable.
3. Completa los datos: país, nombre, teléfono.
4. Verifica el teléfono (te llega un código por SMS o llamada).
5. Añade la tarjeta. Importante: la dirección de facturación debe coincidir con la
   tarjeta o puede rechazarla. Si falla, prueba con otra tarjeta o corrige la dirección.
6. Confirmas los términos y terminas el alta. Oracle crea tu cuenta "cloud" y te
   lleva al panel (cloud.oracle.com).

## ⚠️ DECISIÓN CRÍTICA: elegir la REGIÓN (home region)

- La región se elige DURANTE el alta y NO se puede cambiar después.
- Los recursos Always Free (nuestro ARM Ampere y los AMD Micro) SOLO existen en la
  home region.
- RECOMENDACIÓN para tu caso (Colombia, y cercanía con servidores MT5 de Exness):
  **Santiago de Chile (sa-santiago-1)** como primera opción por latencia a Colombia.
  Alternativa: **São Paulo, Brasil (sa-saopaulo-1)**.
- Nota: la disponibilidad de Ampere A1 (instancias ARM) varía por región/tiempo.
  Si en tu región no hay capacidad, Oracle te dejará crear los AMD Micro siempre;
  para el Ampere habrá que reintentar o cambiar de región (con cuenta nueva).

## Qué NO hacer
- NO actives el "Upgrade" a cuenta de pago mientras estemos en fase gratuita.
- NO crees instancias más grandes que las Always Free.
- NO pongas tarjeta con fondos de más de ~$2 de margen (no lo necesita).

## Después del alta (avísame)
- Me pasas: la región elegida y confirmas que entras al panel (cloud.oracle.com).
- Yo preparo todo lo demás (claves SSH, firewall, scripts de hardening) y te guío
  para crear las 2 instancias sin salir de lo gratuito.