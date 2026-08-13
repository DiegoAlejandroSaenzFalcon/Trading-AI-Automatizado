#!/usr/bin/env python3
"""
Calculadora y Generador de Resumen de Nómina Básica (Colombia)
Diseñado para microempresas y tenderos con 1 a 9 empleados.
Ajustado a la normatividad laboral vigente (Salario Mínimo y Auxilio de Transporte 2026 de referencia).
"""

import sys

def calcular_nomina(salario_base, dias_trabajados, auxilio_transporte_legal=200000):
    """
    Calcula devengados, deducciones de ley (4% salud, 4% pensión) y neto a pagar.
    """
    # Proporcional a los días trabajados (mes de 30 días)
    devengado_basico = (salario_base / 30) * dias_trabajados
    
    # Auxilio de transporte proporcional si gana menos de 2 salarios mínimos
    # (Referencia estimada estándar)
    if salario_base <= 3000000:
        aux_transporte = (auxilio_transporte_legal / 30) * dias_trabajados
    else:
        aux_transporte = 0.0
        
    total_devengado = devengado_basico + aux_transporte
    
    # Deducciones empleado (4% salud + 4% pensión sobre el devengado base sin auxilio)
    salud = devengado_basico * 0.04
    pension = devengado_basico * 0.04
    total_deducciones = salud + pension
    
    neto_pagar = total_devengado - total_deducciones
    
    return {
        "devengado_basico": round(devengado_basico, 2),
        "aux_transporte": round(aux_transporte, 2),
        "total_devengado": round(total_devengado, 2),
        "salud": round(salud, 2),
        "pension": round(pension, 2),
        "total_deducciones": round(total_deducciones, 2),
        "neto_pagar": round(neto_pagar, 2)
    }

def main():
    print("=" * 60)
    print("  LIQUIDADOR DE NÓMINA MULTI-EMPLEADO (TENDEROS)")
    print("=" * 60)
    
    try:
        num_empleados = int(input("¿Cuántos empleados tiene este negocio?: "))
        aux_transporte_legal = float(input("Valor Auxilio de Transporte vigente (COP): "))
        
        total_nomina_negocio = 0.0
        
        for i in range(1, num_empleados + 1):
            print(f"\n--- Empleado {i} ---")
            nombre = input(f"Nombre del empleado {i}: ")
            salario_base = float(input(f"Salario básico mensual de {nombre} (COP): "))
            dias = int(input(f"Días trabajados en el mes por {nombre} (1-30): "))
            
            resultado = calcular_nomina(salario_base, dias, aux_transporte_legal)
            total_nomina_negocio += resultado['neto_pagar']
            
            print(f"\n   [Resultado {nombre}]")
            print(f"   - Devengado básico  : $ {resultado['devengado_basico']:,.2f}")
            print(f"   - Auxilio transporte: $ {resultado['aux_transporte']:,.2f}")
            print(f"   - TOTAL DEVENGADO   : $ {resultado['total_devengado']:,.2f}")
            print(f"   - Salud (4%)        : $ {resultado['salud']:,.2f}")
            print(f"   - Pensión (4%)      : $ {resultado['pension']:,.2f}")
            print(f"   - TOTAL DEDUCCIONES : $ {resultado['total_deducciones']:,.2f}")
            print(f"   -> NETO A PAGAR     : $ {resultado['neto_pagar']:,.2f}")
            print("-" * 40)
            
        print("\n" + "=" * 60)
        print(f" TOTAL A PAGAR EN NÓMINA POR EL NEGOCIO: $ {total_nomina_negocio:,.2f}")
        print("=" * 60)
        
    except ValueError:
        print("Error: Por favor ingrese valores numéricos válidos.")

if __name__ == "__main__":
    main()
