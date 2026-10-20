# TripFund

ДЗ №2: сбор на поездку, включая бонус V2.

Нужны [Foundry 1.8.5](https://getfoundry.sh/introduction/installation/) и Node.js 22+.
Solidity: 0.8.24. Версии библиотек закреплены в `package.json` и `package-lock.json`.

Установка и запуск из корня проекта:

```bash
export PATH="$PWD/.tools/bin:$PATH"
npm ci --ignore-scripts --no-audit --no-fund
forge install --no-git --shallow foundry-rs/forge-std@rev=77041d2ce690e692d6e03cc812b57d1ddaa4d505
forge build
forge test
```

Пример в тесте Foundry (`fund` — прокси, `token` — ERC20 с 18 знаками):

```solidity
vm.startPrank(alice);
token.approve(address(fund), 10 ether);
fund.contribute(10 ether);
vm.stopPrank();
```
