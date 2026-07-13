# Politica de seguridad

CipherDebtProtocol mantiene un proceso privado y coordinado para recibir, evaluar y
corregir hallazgos de seguridad relacionados con contratos, scripts y configuracion del
repositorio.

## Versiones mantenidas

| Version                   | Estado                         |
| ------------------------- | ------------------------------ |
| Rama `main`               | Mantenida                      |
| Ultima version etiquetada | Mantenida                      |
| Versiones anteriores      | Solo bajo evaluacion explicita |

Los despliegues pueden variar por parametros, oracles, activos y roles. Incluya siempre
red, direccion, bloque y configuracion relevante al reportar un caso sobre una instancia
desplegada.

## Alcance

Se consideran dentro del alcance:

- contratos en `src/`;
- contabilidad de deuda, indices y colateral;
- migraciones y refinanciaciones internas;
- repayments y liquidaciones;
- oracle local y validaciones de precio;
- modelo de tipos;
- roles, pausas, caps y permisos de migrador;
- treasury y catalogo operativo;
- scripts de compilacion, pruebas y CI.

Normalmente quedan fuera del alcance:

- forks modificados por terceros;
- dependencias del entorno local no usadas por los contratos;
- indisponibilidad de servicios externos sin impacto economico;
- frontends o indexadores no mantenidos aqui;
- parametros de despliegue no recomendados;
- ataques que requieran credenciales comprometidas fuera del repositorio.

## Invariantes esperadas

El protocolo se opera bajo estas invariantes:

- una posicion no puede aumentar deuda si su factor de salud resultante queda bajo 1;
- una retirada de colateral debe conservar solvencia;
- la liquidacion solo procede sobre posiciones bajo el umbral;
- la deuda agregada de mercado debe evolucionar con el indice acumulado;
- las operaciones sensibles deben respetar caps, pausas y roles;
- los precios usados para riesgo deben estar configurados, no pausados y vigentes;
- los recibos de suministro deben representar liquidez retirada o retirada pendiente;
- las ordenes de migracion deben estar dentro de plazo y no reutilizar nonce operativo.

## Comunicacion privada

Use el canal privado indicado por los mantenedores. No publique detalles tecnicos en
issues, discusiones, redes sociales ni canales comunitarios antes de coordinar una
respuesta.

Incluya cuando sea posible:

- componente afectado;
- commit o version;
- red y direccion si aplica;
- condiciones previas;
- comportamiento esperado;
- comportamiento observado;
- impacto economico;
- pasos minimos de reproduccion;
- trazas, logs o tests;
- mitigacion temporal sugerida.

No adjunte claves privadas, frases semilla ni credenciales. Si el material requiere
cifrado, solicite un canal adecuado antes de enviarlo.

## Proceso de respuesta

El equipo intentara seguir estos plazos:

1. acuse de recibo en dos dias laborables;
2. evaluacion inicial en cinco dias laborables;
3. actualizacion semanal mientras continue el analisis;
4. coordinacion de correccion, despliegue y comunicacion segun el alcance confirmado.

La prioridad se asigna por fondos en riesgo, reproducibilidad, permisos necesarios,
alcance entre mercados y disponibilidad de controles operativos.

## Investigacion responsable

Para proteger a usuarios y redes:

- use redes locales o forks controlados;
- no acceda a datos ajenos;
- no degrade servicios;
- no retenga fondos de terceros;
- limite transacciones publicas al minimo necesario;
- preserve evidencias reproducibles;
- detenga pruebas que puedan afectar a terceros.

El proyecto procurara no iniciar acciones contra investigaciones de buena fe que respeten
esta politica y la legislacion aplicable.

## Dependencias

Los paquetes de desarrollo se usan para compilacion, pruebas y formato. Dependabot revisa
ecosistema npm y GitHub Actions. Un hallazgo en una dependencia debe reportarse tambien al
mantenedor correspondiente cuando proceda.

## Divulgacion coordinada

La fecha y el contenido de una comunicacion publica se acordaran despues de disponer de
una correccion o de medidas razonables para proteger a usuarios. El reconocimiento se
realizara cuando la persona informante lo solicite y sea apropiado.
