# Instruções de Instalação

Este guia fornece instruções passo a passo para a instalação e configuração do Raspberry Pi OS no seu Raspberry Pi.

**Versões suportadas:**
- Raspberry Pi OS Bullseye (Debian 11) - `setup_pagalava_iot_debian11.sh`
- Raspberry Pi OS Bookworm (Debian 12) - `setup_pagalava_iot.sh`
- Raspberry Pi OS Trixie (Debian 13) - `setup_pagalava_iot_debian13.sh`


## Pre-requisitos

1. Raspberry 3, 4, 5.
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
4. Selecione a versão do sistema operativo:
   - **Recomendado:** "Raspberry Pi OS (64-bit) Lite" - baseado em Debian Bookworm/Trixie
   - **Legacy:** "Raspberry Pi OS (Legacy, 64-bit) Lite" - baseado em Debian Bullseye
5. Selecione a opção "Escolher Cartão" (Choose Storage) e selecione o cartão SD que você inseriu.
6. Clique em "Escrever" (Write) para começar a escrever a imagem no cartão SD.

### 1.3: Configuração geral 

Nome de utizador: pagalava.
Password: À sua escolha, uma password segura.

Para sistemas em loja, apenas a ligação por Ethernet é suportada.
Pode usar WiFi para a configuração apenas por comodidade.
Para instruções detalhadas sobre configuração WiFi, consulte o [Guia de Configuração WiFi](./instructions/configuracao_wifi.md).
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

### Debian 12 (Bookworm) - Recomendado
Para instalar em Raspberry Pi OS Bookworm, execute:

```bash
curl -sSL -o setup_pagalava_iot.sh https://raw.githubusercontent.com/airesmarques/pagalava-iot/main/setup_pagalava_iot.sh
chmod +x setup_pagalava_iot.sh
. ./setup_pagalava_iot.sh
rm setup_pagalava_iot.sh
```

### Debian 13 (Trixie)
Para instalar em Raspberry Pi OS Trixie, execute:

```bash
curl -sSL -o setup_pagalava_iot.sh https://raw.githubusercontent.com/airesmarques/pagalava-iot/main/setup_pagalava_iot_debian13.sh
chmod +x setup_pagalava_iot.sh
. ./setup_pagalava_iot.sh
rm setup_pagalava_iot.sh
```

### Debian 11 (Bullseye) - Legacy
Para instalações em Raspberry Pi OS Bullseye (legacy), execute:

```bash
curl -sSL -o setup_pagalava_iot.sh https://raw.githubusercontent.com/airesmarques/pagalava-iot/main/setup_pagalava_iot_debian11.sh
chmod +x setup_pagalava_iot.sh
. ./setup_pagalava_iot.sh
rm setup_pagalava_iot.sh
```

### Testar módulos de relés
Atenção: este script não testa a conectividade com a cloud PagaLava, apenas verifica se os relés estão na sequência correta e bem ligados ao Raspberry.

executar o script:  
```bash
. ./test.sh
```


Escolher m1, m2, ou m3. Após esta escolha, sequencialmente cada um dos módulos de relés serão ligados durante uma fração do tempo de uma ativação convencional. Isto permite verificar se o módulo de relés está montado corretamente.

### Executar diagnósticos do dispositivo
Para verificar o estado geral do dispositivo IoT, incluindo conectividade de rede, estado do serviço, e configuração GPIO, execute o script de diagnósticos:

```bash
./diagnosticos.sh
```

O script irá:
- Verificar se o ambiente virtual está configurado corretamente
- Testar a conectividade de rede
- Verificar o estado do serviço receive_messages
- Testar a conectividade com a Cloud Pagalava
- Validar a configuração do dispositivo

O resultado do diagnóstico será apresentado no terminal com indicadores coloridos (verde = OK, amarelo = aviso, vermelho = erro).

## Ligação manual à Cloud Pagalava
A ligação do Raspberry à Cloud Pagalava é feita durante a instalação, desde que a IOT_CONNECTION_STRING esteja correta.

para verificar a ligação:
```bash
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

```bash
. ./update_pagalava.sh
```

Após a execução, deve fazer um reboot ou reinicializar o servico "receive_messages.service".

## Configuração das máquinas de lavar e secar

Para já, entrar em contacto comigo :D
No futuro irei criar uma dashboard de configuração.

## Configuração do IfThenPay

Para fazer a configuração do IfThenPay, basta seguir as instruções na dashboard da cloud PagaLava, na seção Proprietário.

### Configuração da Callback

### Sistema de testes.

gerir-dev.pagalava.pt

### Sistema produção.

gerir.pagalava.pt

# Resolução de Problemas

## Reinstalação do PagaLava

### Opção 1 - Com backup da instalação atual
Para mover o diretório para um diretório de backup:
```bash
mv pagalava-iot pagalava-iot_backup
```

### Opção 2 - Sem backup da instalação atual
Para apagar completamente a instalação atual:
```bash
rm -rf pagalava-iot
```
Após a remoção da instalação do PagaLava, pode ser reinstalado de forma segura.


## Histórico de Versões

| Versão | Data       | Melhorias                                                                                           |
|--------|------------|-----------------------------------------------------------------------------------------------------|
| 1.0    |            | Primeira versão do dispositivo IoT com funcionalidades básicas                                      |
| 1.1    |            | Adicionado controlo de tempo dos relés                                                              |
| 1.2    |            | Adicionado intervalo entre impulsos e número de impulsos para ativação                              |
|        |            | Implementado sistema de relatório de versão e suporte para atualização remota                       |
| 1.3    | 28/04/2025 | Adicionado suporte para mensagens de diagnóstico com ferramentas de verificação de conectividade    |
|        |            | Implementada recuperação de conexão e melhoria da lógica de tentativas após falhas de rede          |
| 1.3    | 16/01/2026 | Compatibilidade com Debian 12/13                                                                    |

## Referências

[Hardware Raspberry](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html)

