# KipuBankV2

Repositorio: KipuBankV2
Trabajo Final - Módulo 3 (2025-S2-EDP-HENRY-M3)

## Resumen
KipuBankV2 extiende el contrato original (KipuBank) agregando:
- Control de acceso con roles (ADMIN_ROLE)
- Soporte multi-token (ERC-20) y ETH (address(0))
- Integración con oráculos Chainlink (token/USD) para valorar depósitos y aplicar `bankCap` en USD
- Manejo de decimales por token
- Límites por transacción por token
- ReentrancyGuard y SafeERC20 para seguridad
- Eventos y errores personalizados
- Función de rescate para tokens/ETH enviados por error
- Pausable simple mediante variable `paused` (toggle por admin)

## Archivos clave
- /src/KipuBankV2.sol  -> Contrato principal
- README.md            -> Este documento
- /deploy/README.md    -> (opcional) scripts/ejemplos de deploy (Hardhat/Foundry/Truffle)

## Diseño y decisiones
- **Bank cap en USD**: usar USD (8 decimals) evita que la liquidez total en tokens/ETH exceda un umbral económico. Chainlink price feeds se usan para estimar exposure.
- **Contabilidad por token**: balances por token y usuario (`mapping(address => mapping(address => uint256))`) facilita multi-asset.
- **Per-tx withdraw limit**: configurable por token. Zero = sin límite.
- **Decimales**: convertimos token units → USD usando `decimals()` del token y la lectura Chainlink (8 decimals).
- **Trade-offs**:
  - La conversión USD es instantánea con Chainlink; sin embargo, el precio puede fluctuar entre deposit y withdraw (slippage o front-running de precios). Para mayor exactitud se podrían usar oráculos con vendedoras o mecanismos de timelock.
  - El `bankCapUSD` se comprueba al depositar. Si el precio sube rápido, puede permitir exposiciones ligeramente mayores entre bloques — para mitigarlo, pensar en colateralización o checkpoints off-chain.
  - Almacenar `totalDepositedUSD` y `totalWithdrawnUSD` es aproximado (depende del precio al momento de cada operación). Para una contabilidad perfecta se podrían mantener snapshots por depósito.

## Requisitos para desplegar y verificar
1. Node + npm, proyecto Hardhat o Foundry.
2. Instalar dependencias:
   - `npm install @openzeppelin/contracts @chainlink/contracts`
3. Compilar el contrato en la versión `^0.8.19`.
4. Deploy:
   - Proveer `bankCapUSD` (ej: `500000 * 10**8` = $500k con 8 decimales).
5. Después del deploy (por admin):
   - `setPriceFeed(address(0), <ETH/USD_feed_address_on_testnet>)`
   - `setPriceFeed(<TOKEN>, <TOKEN/USD_feed_address>)` para cada token que quieras soportar.
   - Opcional: `setPerTxWithdrawLimit(<token>, <limit_in_token_units>)`

## Interacción (ejemplos)
- **Depositar ETH**:
  - Llamar `depositETH()` poniendo `msg.value`.
- **Depositar ERC20**:
  - `approve(KipuBankV2_address, amount)` en el token, luego `depositERC20(token, amount)`.
- **Retirar**:
  - `withdrawETH(amount)` o `withdrawERC20(token, amount)`.
- **Admin**:
  - `setPriceFeed(token, feed)`, `setPerTxWithdrawLimit(token, limit)`, `rescue(token, to, amount)`.

## Notas de seguridad
- Uso de `ReentrancyGuard` y `SafeERC20` para evitar reentrancy y errores en transferencias ERC20.
- `rescue` sólo para administradores — ten cuidado con su uso y audita las claves privadas del admin.
- Validar feeds Chainlink y su presencia antes de aceptar depósitos para un token.

## Posibles extensiones futuras
- Soporte de stablecoins (p. ej. USDC interno) y contabilidad en "USDC units" para evitar conversión repetida.
- Mecanismo de comisiones y treasury.
- Snapshot histórico y permisos finos por función (pausar depósitos pero permitir retiros).
- Testing unitario con Hardhat/Foundry y verificación en testnet (Sepolia/Goerli/Scroll según disponibilidad).

