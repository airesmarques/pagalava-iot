# Instruções de Instalação

Este guia fornece instruções passo a passo para a instalação e configuração do Raspberry Pi OS Bullseye 64-bit Lite no seu Raspberry Pi.

## 1. Preparação do dispositivo

### 1.1: Instalar o Raspberry Pi Imager

Para começar, precisa do Raspberry Pi Imager para escrever a imagem do sistema operacional no cartão SD. Siga os passos:

1. Faça o download do Raspberry Pi Imager a partir do site oficial: [Raspberry Pi Imager](https://www.raspberrypi.org/software/).
2. Instale o aplicativo no seu computador, seguindo as instruções fornecidas.

### 1.2: Escrever a Imagem do Sistema Operativo

Com o Raspberry Pi Imager instalado, pode gravar a imagem do sistema operativo no cartão SD.

1. Insira o cartão SD no computador.
2. Abra o Raspberry Pi Imager.
3. Em Raspberry Pi Device, escolha o modelo Raspberry Pi 4, ou Pi Zero, dependendo do que está a utilizar.
3. Selecione a opção "Escolher SO" (Choose OS).
4. Vá até a secção "Raspberry Pi OS (Outras)" (Raspberry Pi OS (Other)) e selecione "Raspberry Pi OS (Legacy, 64-bit) Lite".
5. Selecione a opção "Escolher Cartão" (Choose Storage) e selecione o cartão SD que você inseriu.
6. Clique em "Escrever" (Write) para começar a escrever a imagem no cartão SD.

![Exemplo de versão Debian Bullseye](/instructions/Debian_Bullseye_version.png)

### 1.3: Configurar Wi-Fi e utilizador linux

Para o nome de utizador do raspberry, digite: pagalava.
É aconselhável configurar as definições da Wi-Fi da loja antes de iniciar o Raspberry Pi pela primeira vez.

## 2: Preparação do hardware / relés para ativação das máquinas de lavar e secar

Nesta versao vamos usar apenas o módulo 2. A Tabela está abaixo 


| Relay Module | Relay Index / Relay Number | GPIO Pin | Physical Pin |
|--------------|----------------------------|----------|--------------|
| Module 1     | 1 - Relay 1-1              | GPIO 22  | 15           |
| Module 1     | 2 - Relay 1-2              | GPIO 23  | 16           |
| Module 1     | 3 - Relay 1-3              | GPIO 24  | 18           |
| Module 1     | 4 - Relay 1-4              | GPIO 25  | 22           |
| Module 1     | 5 - Relay 1-5              | GPIO 26  | 37           |
| Module 1     | 6 - Relay 1-6              | GPIO 27  | 13           |
| Module 1     | 7 - Relay 1-7              | GPIO 17  | 11           |
| Module 1     | 8 - Relay 1-8              | GPIO 18  | 12           |
| Module 2     | 9 - Relay 2-1              | GPIO 12  | 32           |
| Module 2     | 10 - Relay 2-2             | GPIO 16  | 36           |
| Module 2     | 11 - Relay 2-3             | GPIO 20  | 38           |
| Module 2     | 12 - Relay 2-4             | GPIO 21  | 40           |
| Module 2     | 13 - Relay 2-5             | GPIO 17  | 37           |
| Module 2     | 14 - Relay 2-6             | GPIO 13  | 35           |
| Module 2     | 15 - Relay 2-7             | GPIO 19  | 33           |
| Module 2     | 16 - Relay 2-8             | GPIO 26  | 11           |

Module 2 VCC - Raspberry Pin 4 (VCC 5V)
Module 2 GND - Raspberry Pin 9 (GND)



Por exemplo, o relés com indice 9, que é o primeiro do segundo módulo de relés, deverá ser ligado ao GPIO 12, que é o 32 pino do Raspberry.


![Pinout do Raspberry 3-4 e ZeroW](/instructions/raspberry-pi-gpio-pinout.jpg)




## Configuração do sistema PagaLava
Para instalar todos os components do sistema Pagalava, execute o script abaixo:

curl -sSL -o setup_pagalava_iot.sh https://raw.githubusercontent.com/airesmarques/pagalava-iot/main/setup_pagalava_iot.sh
chmod +x setup_pagalava_iot.sh
. ./setup_pagalava_iot.sh
rm setup_pagalava_iot.sh

### Testar módulos de relés

executar o script:
. ./test.sh

Escolher 2, após esta escolha, sequencialmente cada um dos módulos de relés serão ligados durante 1 segundo
## Ligação à Cloud Pagalava
A ligação do Raspberry à Cloud Pagalava é feita durante a instalação, desde que a IOT_CONNECTION_STRING esteja correta.

para verificar a ligação:
. ./get_journalctl.sh 

O resultado será semelhante às linhas abaixo:

INFO:azure.iot.device.common.mqtt_transport:Creating client for connecting using MQTT over TCP
INFO:azure.iot.device.iothub.sync_clients:Enabling feature:c2d...
INFO:azure.iot.device.common.mqtt_transport:Connect using port 8883 (TCP)
INFO:azure.iot.device.common.mqtt_transport:connected with result code: 0
INFO:azure.iot.device.common.pipeline.pipeline_stages_mqtt:_on_mqtt_connected called
INFO:azure.iot.device.iothub.abstract_clients:Connection State - Connected

## Configuração das máquinas de lavar e secar

Para já, fazemos por mensagens de WhatsApp :D
Para o futuro irei criar uma dashboard de configuração.

## Configuração do IfThenPay

Irei documentar o processo daqui a uns dias...
