# Preparação do Hardware

Este guia descreve o material necessário e a ligação dos módulos de relés ao Raspberry Pi.
Aplica-se a qualquer método de instalação do software PagaLava.

[← Voltar à página principal](../readme.md)

## Pre-requisitos

1. Raspberry 4, 5.
2. Cartão SD com pelo menos 16 GB.
3. Cabo para ligação Ethernet ao Raspberry.
4. 1 ou 2 módulos de relés de 8 canais DC 5V
5. Cabos jumper fêmea-fêmea para ligar o Raspberry ao(s) módulos de relés.

<img src="./Relay.jpg" width="40%" alt="Exemplo de componente 4 - módulo de relés 8 canais">

## Ligação dos relés para ativação das máquinas de lavar e secar

Nesta versao vamos usar apenas o módulo 2. A Tabela está abaixo 


| Relay Module | Relay Index / Relay Number | GPIO Pin | Physical Pin |
|--------------|----------------------------|----------|--------------|
| Module 1     | 1 - Relay 1-1              | GPIO 22  | 15           |
| Module 1     | 2 - Relay 1-2              | GPIO 23  | 16           |
| Module 1     | 3 - Relay 1-3              | GPIO 24  | 18           |
| Module 1     | 4 - Relay 1-4              | GPIO 25  | 22           |
| Module 1     | 5 - Relay 1-5              | GPIO     |              |
| Module 1     | 6 - Relay 1-6              | GPIO 27  | 13           |
| Module 1     | 7 - Relay 1-7              | GPIO     |              |
| Module 1     | 8 - Relay 1-8              | GPIO 18  | 12           |
| Module 2     | 9 - Relay 2-1              | GPIO 12  | 32           |
| Module 2     | 10 - Relay 2-2             | GPIO 16  | 36           |
| Module 2     | 11 - Relay 2-3             | GPIO 20  | 38           |
| Module 2     | 12 - Relay 2-4             | GPIO 21  | 40           |
| Module 2     | 13 - Relay 2-5             | GPIO 17  | 11           |
| Module 2     | 14 - Relay 2-6             | GPIO 13  | 33           |
| Module 2     | 15 - Relay 2-7             | GPIO 19  | 35           |
| Module 2     | 16 - Relay 2-8             | GPIO 26  | 37           |

Module 2 VCC - Raspberry Pin 4 (VCC 5V).
Module 2 GND - Raspberry Pin 9 (GND).



Por exemplo, o relés com indice 9, que é o primeiro do segundo módulo de relés, deverá ser ligado ao GPIO 12, que é o 32 pino do Raspberry.


![Pinout do Raspberry 3-4 e ZeroW](./raspberry-pi-gpio-pinout.jpg)

## Próximos passos

- Instalar o software: siga as instruções de instalação por cartão SD em [gerir.pagalava.pt](https://gerir.pagalava.pt).
- Depois de instalado, verifique a montagem com o [teste aos módulos de relés](../readme.md#testar-módulos-de-relés).
