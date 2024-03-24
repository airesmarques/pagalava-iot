# Instruções de Instalação

Este guia fornece instruções passo a passo para a instalação e configuração do Raspberry Pi OS Bullseye 64-bit Lite no seu Raspberry Pi.


## Pre-requisitos

1. Raspberry 3, 4, ou ZeroW com HAT Ethernet.
2. Cartão SD com pelo menos 4GB.
3. Cabo para ligação Ethernet ao Raspberry.
4. 1 ou 2 módulos de relés de 8 canais DC 5V
5. Cabos jumper fêmea-fêmea para ligar o Raspberry ao(s) módulos de relés.

<img src="./instructions/Relay.jpg" width="40%" alt="Exemplo de componente 4 - módulo de relés 8 canais">



## 1. Preparação do dispositivo

### 1.1: Instalar o Raspberry Pi Imager

Para começar, precisa do Raspberry Pi Imager para escrever a imagem do sistema operativo no cartão SD. Siga os passos:

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

### 1.3: Configuração geral 

Nome de utizador: pagalava.
Password: À sua escolha, uma password segura.

Para sistemas em loja, apenas a ligação por Ethernet é suportada.
Pode usar WiFi para a configuração apenas por comodidade.
Seleccione o país e teclado.

![Configuração geral](/instructions/Rpi-Imager-General.png)

### 1.4: Serviço SSH

Ative o serviço SSH. Pode usar password para autenticação ou uma chave SSH (recomendado).

![SSH](/instructions/Rpi-Imager-Services.png)



## 2: Preparação do hardware / relés para ativação das máquinas de lavar e secar

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


![Pinout do Raspberry 3-4 e ZeroW](/instructions/raspberry-pi-gpio-pinout.jpg)




## Configuração do sistema PagaLava
Localize o Raspberry na sua rede, identificando o endereço IP, e ligue-se ao Raspberry por SSH. 

Não é necessário atualizar o sistema operativo, os updates serão executados no script de instalação.
Para instalar todos os components do sistema Pagalava, execute o script abaixo:

```
curl -sSL -o setup_pagalava_iot.sh https://raw.githubusercontent.com/airesmarques/pagalava-iot/main/setup_pagalava_iot.sh
chmod +x setup_pagalava_iot.sh
. ./setup_pagalava_iot.sh
rm setup_pagalava_iot.sh
```

### Testar módulos de relés

executar o script:  
. ./test.sh

Escolher m1, m2, ou m3. Após esta escolha, sequencialmente cada um dos módulos de relés serão ligados durante uma fração do tempo de uma ativação convencional. Isto permite verificar se o módulo de relés está montado corretamente.

## Ligação à Cloud Pagalava
A ligação do Raspberry à Cloud Pagalava é feita durante a instalação, desde que a IOT_CONNECTION_STRING esteja correta.

para verificar a ligação:
```
. ./get_journalctl.sh 
```

O resultado será semelhante às linhas abaixo:

```
INFO:azure.iot.device.common.mqtt_transport:Creating client for connecting using MQTT over TCP
INFO:azure.iot.device.iothub.sync_clients:Enabling feature:c2d...
INFO:azure.iot.device.common.mqtt_transport:Connect using port 8883 (TCP)
INFO:azure.iot.device.common.mqtt_transport:connected with result code: 0
INFO:azure.iot.device.common.pipeline.pipeline_stages_mqtt:_on_mqtt_connected called
INFO:azure.iot.device.iothub.abstract_clients:Connection State - Connected
```

## Updates do sofrware Pagalava IoT
Para fazer atualizações ao software, deve executar o comando abaixo:

```
. update_pagalava.sh
```

Após a execução, deve fazer um reboot ou reinicializar o servico "receive_messages.service".

## Configuração das máquinas de lavar e secar

Para já, entrar em contacto comigo :D
No futuro irei criar uma dashboard de configuração.


## Configuração do IfThenPay

Irei documentar o resto processo progressivamente... onde é usada a nomenclatura dashboard, atualmente não existindo dashboard, deverá ser tratado com o autor do projecto através do WhatsApp.



Entrar no Backoffice to IfThenPay com a chave de Backoffice.
https://backoffice.ifthenpay.com/Account/Login

No menu da esquerda, siga o menu "Contrato".
Na lista dropdown, escolha a conta MbWay.
![Conta MbWay](/instructions/IfThenPay_DetalhesDoContrato.png)

Copie o número da conta, neste exemplo QNW-006650. Este deverá ser introduzido na Dashboard Pagalava.

Após gravar o número de conta, é gerada a Chave Antifishing, esta chave é aleatoria. A Chave Antifishing permite ao sistema IfThenPay identificar-se perante o PagaLava para confirmar com segurança de que o pagamento foi efectuado.


De seguida iremos ativar a Callback. Introduza o texto em ambos os campos.
### Sistema de testes.

URL de Callback: https://pagalava-services-dev.washstation.io/api/paycallback/mbway?key=[ANTI_PHISHING_KEY]&id=[ID]&amount=[AMOUNT]&payment_datetime=[PAYMENT_DATETIME]&payment_method=[PAYMENT_METHOD]


### Sistema produção.
URL de Callback: https://pagalava-services.washstation.io/api/paycallback/mbway?key=[ANTI_PHISHING_KEY]&id=[ID]&amount=[AMOUNT]&payment_datetime=[PAYMENT_DATETIME]&payment_method=[PAYMENT_METHOD]

Chave Anti-Fishing: Chave dada pela dashboard.

Gravar.


## Referências

[Hardware Raspberry](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html)

