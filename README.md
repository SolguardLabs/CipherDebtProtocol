# CipherDebtProtocol

![banner](./assets/banner.png)

CipherDebtProtocol es un protocolo EVM de refinanciacion interna para mercados de deuda
sobregarantizada. Permite crear mercados con curvas de interes propias, aportar liquidez,
abrir posiciones de prestamo, migrar deuda y colateral entre mercados compatibles,
refinanciar posiciones, amortizar deuda y liquidar cuentas que dejan de cumplir los
parametros de riesgo.

El repositorio usa Solidity y Hardhat. Los contratos principales estan en `src/`, las
pruebas de integracion en `test/` y los scripts reproducibles en `scripts/`.

## Componentes

```text
src/
  CipherDebtProtocol.sol         Nucleo de mercados, deuda, colateral y liquidaciones
  access/                        Roles operativos y administracion
  governance/                    Catalogo de mercados y limites operativos
  interest/                      Modelo de tipos por utilizacion
  interfaces/                    Superficies publicas para integraciones
  lens/                          Consultas agregadas para bots e interfaces
  libraries/                     Matematicas, accounting, riesgo y transferencias
  oracle/                        Oracle local configurable para pruebas e integracion
  security/                      Guardia de reentrada
  tokens/                        Activos ERC-20 y recibos de suministro
  treasury/                      Custodia operativa de reservas y pagos
```

## Modelo de mercado

Cada mercado define:

- activo prestable;
- activo de colateral compatible;
- indice acumulado de deuda;
- tipo de interes por segundo;
- factor de colateral;
- umbral y bonificacion de liquidacion;
- factor de reserva;
- limites de suministro, deuda minima y deuda total.

Los proveedores aportan liquidez al mercado y reciben recibos ERC-20. Los prestatarios
depositan colateral, piden prestado contra su capacidad disponible y mantienen un
checkpoint de deuda asociado al indice del mercado.

## Flujos principales

1. El administrador configura oracle, treasury y mercados.
2. Los proveedores suministran liquidez y reciben recibos.
3. Un usuario deposita colateral en un mercado.
4. El usuario abre deuda dentro de su capacidad de prestamo.
5. El indice del mercado acumula intereses con el tiempo.
6. El usuario puede amortizar, refinanciar o migrar deuda a otro mercado compatible.
7. Si el factor de salud cae por debajo de 1, un liquidador puede sanear la posicion.

## Migraciones internas

Las migraciones usan ordenes con:

- prestatario;
- mercado origen;
- mercado destino;
- deuda a trasladar;
- colateral a reasignar;
- snapshot de cotizacion;
- factor de salud minimo;
- vencimiento;
- nonce.

El contrato admite ejecucion directa por el prestatario o por un migrador aprobado. Esto
permite que routers internos preparen refinanciaciones entre curvas de interes sin que el
usuario tenga que cerrar manualmente la posicion anterior.

## Requisitos

- Node.js 22 o superior para reproducir el entorno de CI.
- npm.
- Git Bash, WSL o Bash compatible para ejecutar scripts `*.sh` en Windows.

Instalacion:

```bash
npm install
```

Compilacion:

```bash
npm run compile
```

Pruebas:

```bash
npm test
```

Validacion local completa:

```bash
bash scripts/ci.sh
```

Comprobacion del tamano de `src/`:

```bash
bash scripts/check-loc.sh
```

## Pruebas incluidas

La suite Hardhat valida:

- creacion de prestamos sobregarantizados;
- acumulacion de interes;
- migraciones de deuda y colateral entre mercados;
- refinanciaciones con amortizacion y nuevo principal;
- repayments parciales;
- liquidaciones tras repricing de colateral;
- pausas operativas, caps y migradores delegados.

## Desarrollo

Los contratos evitan dependencias externas de runtime para que el protocolo sea facil de
auditar localmente. Los tokens y el oracle incluidos sirven para entornos de prueba,
devnets y despliegues controlados.

Comandos utiles:

```bash
npm run compile
npm test
npm run loc
npm run lint
```

## CI

El workflow de GitHub Actions instala dependencias con `npm ci`, compila contratos,
ejecuta la suite Hardhat, comprueba el rango de LOC en `src/` y valida formato con
Prettier.

## Seguridad operativa

Antes de desplegar un mercado real, revise:

- precision y frescura de precios;
- caps de suministro y deuda;
- tipos de interes por utilizacion;
- factor de reserva;
- colateral aceptado;
- parametros de liquidacion;
- cuentas con roles administrativos;
- procesos de pausa;
- limites de migradores y routers.

La politica de comunicacion de hallazgos esta en `SECURITY.md`.

## Licencia

MIT.
