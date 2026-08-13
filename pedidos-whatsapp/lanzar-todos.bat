@echo off
if not exist "clientes" (
  echo No existe la carpeta clientes/. Crea un config por cliente en clientes/*.json
  pause
  exit /b
)
for %%f in (clientes\*.json) do (
  start "Bot %%~nf" cmd /k node index.js --cliente "%%f"
)
echo Se abrio una ventana por cada cliente. Cierra las ventanas para detener.
