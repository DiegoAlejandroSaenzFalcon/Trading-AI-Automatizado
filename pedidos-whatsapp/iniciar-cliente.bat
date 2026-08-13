@echo off
if "%1"=="" (
  echo Uso: iniciar-cliente.bat ^<nombre-cliente^>
  echo Ejemplo: iniciar-cliente.bat perro-transmilenio
  pause
  exit /b
)
node index.js --cliente "clientes\%1.json"
