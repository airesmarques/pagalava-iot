# Instruções de Instalação

Este guia fornece instruções passo a passo para a instalação e configuração do sistema de Pagamentos PagaLava usando um  Raspberry Pi.

**Versões suportadas:**
- Raspberry Pi OS Bullseye (Debian 11) - `setup_pagalava_iot_debian11.sh`
- Raspberry Pi OS Bookworm (Debian 12) - `setup_pagalava_iot.sh`
- Raspberry Pi OS Trixie (Debian 13) - `setup_pagalava_iot_debian13.sh`


## Pre-requisitos

1. Raspberry 4, 5.
2. Cartão SD com pelo menos 16 GB.
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

Nome de utilizador: pagalava (recomendado).
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




## Ficheiro de instalação (sem escrever a connection string)

A connection string identifica o dispositivo e é o único passo verdadeiramente
delicado da instalação. Em vez de a escrever no terminal, pode descarregá-la do
dashboard e copiá-la para o cartão SD.

**No dashboard:** abra a lavandaria → *Ligar Raspberry* → **Descarregar ficheiro
de instalação**. Obtém um ficheiro `pagalava-provisioning-laundry-<id>.txt`.

**No cartão SD:** copie esse ficheiro para a **partição de arranque** (a partição
pequena, em FAT, que o Windows e o macOS montam como `boot` / `bootfs`). Não o
coloque em nenhuma subpasta.

A partir daqui há dois caminhos:

- **Imagem PagaLava** (ver secção seguinte): ligue o Raspberry e ele configura-se
  sozinho no primeiro arranque. Não é preciso SSH.
- **Instalação normal:** siga o procedimento habitual abaixo. Os scripts de
  instalação passaram a procurar este ficheiro e, se o encontrarem, deixam de
  pedir a connection string.

> **Atenção:** este ficheiro contém a credencial do dispositivo. Quem tiver o
> ficheiro, ou uma cópia do cartão, consegue fazer-se passar por esta lavandaria.
> A imagem PagaLava apaga-o do cartão no primeiro arranque; nas instalações
> normais, apague-o do cartão e da pasta de downloads depois de terminar.
>
> Se o mesmo ficheiro for usado em dois Raspberry, ambos ficam com a mesma
> identidade e o comportamento é imprevisível. Um ficheiro por dispositivo.

Se copiar dois ficheiros de instalação para o mesmo cartão, o Raspberry
**recusa-se a arrancar configurado** em vez de adivinhar qual usar. Deixe apenas
um e reinicie.

## Imagem PagaLava (instalação simplificada)

A imagem PagaLava é um Raspberry Pi OS já preparado: traz o software instalado,
o serviço configurado e o SSH ligado. Descarregue-a a partir do dashboard, na
mesma página do ficheiro de instalação.

O procedimento é: gravar a imagem no cartão com o Raspberry Pi Imager, **recusar
as "definições personalizadas"** quando o Imager as oferecer, copiar o ficheiro
de instalação para a partição de arranque, e ligar o Raspberry com **cabo de
rede**.

> As definições personalizadas do Imager escrevem a sua própria configuração de
> utilizador e de rede, que entra em conflito com a da imagem. Responda **não**.

### O que acontece no primeiro arranque

O dispositivo procura o ficheiro de instalação na partição de arranque e, se o
encontrar:

1. Guarda a connection string na configuração do ambiente correspondente.
2. Passa a chamar-se como o dispositivo se chama no dashboard — uma lavandaria
   `rpiPagalava99` responde na rede como `rpiPagalava99.local`.
3. Define a palavra-passe de SSH indicada no ficheiro.
4. **Apaga o ficheiro do cartão**, para que a credencial não fique lá.
5. Arranca o serviço, que pede a configuração das máquinas à cloud.

Se o ficheiro não existir — por já ter sido consumido, ou por nunca ter sido
copiado — o arranque não faz nada e o dispositivo comporta-se como qualquer
outro. Voltar a arrancar um dispositivo já configurado é seguro.

### Acesso ao dispositivo

O utilizador é `pagalava` e a palavra-passe é gerada por dispositivo, visível no
dashboard junto às instruções de instalação. É composta por palavras simples
para poder ser lida de um ecrã e escrita num telemóvel.

```bash
ssh pagalava@rpiPagalava99.local
```

O endereço local também aparece no dashboard depois da verificação da
instalação. Se o nome `.local` não resolver na rede da lavandaria, use o
endereço IP.

> A palavra-passe é diferente em cada dispositivo, de propósito: uma lavandaria
> comprometida não dá acesso às restantes. Não existe, para já, forma de a
> rodar sem reinstalar o dispositivo.

### Rede sem fios

A imagem **não** traz credenciais de Wi-Fi, pelo que a instalação exige cabo de
rede. Para configurar Wi-Fi depois, por SSH:

```bash
sudo nmcli device wifi connect "<nome-da-rede>" password "<palavra-passe>"
```

O país regulatório já vem definido na imagem (PT), sem o qual o rádio fica
bloqueado.

## Configuração do sistema PagaLava
Localize o Raspberry na sua rede, identificando o endereço IP, e ligue-se ao Raspberry por SSH.

Este é o procedimento clássico e continua a funcionar exactamente como sempre.
Se tiver copiado um ficheiro de instalação para o cartão, o script encontra-o e
não pergunta nada; caso contrário pede a connection string como antes.

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

## Gestão de ambientes (configurar)

O dispositivo pode ter vários ambientes guardados localmente em ficheiros `.env.<id>`
(por exemplo `.env.1`, `.env.140`, `.env.prod.02`). O ambiente activo é aquele para
onde `.env` aponta (normalmente um symlink, por exemplo `.env -> .env.1`).

Para ver e trocar o ambiente activo existe uma aplicação de terminal (TUI) baseada em
`textual`. Execute a partir da pasta do projeto, usando o ambiente virtual:

```bash
.venv/bin/python configurar.py
```

A aplicação lista os ambientes disponíveis, mostra o `DeviceId` e se é `dev` ou `prod`
(a chave de acesso é sempre mascarada), e marca o ambiente activo. Ao escolher um
ambiente e confirmar, o `.env` é actualizado (o symlink é reapontado; se o `.env` for
um ficheiro normal, é copiado com backup em `.env.bak`) e o serviço
`receive_messages.service` é reiniciado, pelo que a mudança fica imediata sem reiniciar
o sistema operativo.

Para apenas listar os ambientes (sem interface, útil por SSH não interativo):

```bash
.venv/bin/python configurar.py --listar
```

## Configuração das máquinas de lavar e secar

A configuração das máquinas é feita na dashboard PagaLava:

- Sistema de testes: gerir-dev.pagalava.pt 
- Sistema de produção: gerir.pagalava.pt 

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
| 1.4    | 25/02/2026 | Verificação de conectividade remota: ao receber mensagem de diagnóstico, o dispositivo envia        |
|        |            | callback HTTP para a cloud com o endereço IP local e código de verificação, permitindo confirmar    |
|        |            | a conectividade e IP do dispositivo diretamente a partir da dashboard PagaLava                      |
| 1.6    | 07/06/2026 | Adicionada aplicação de terminal (configurar) para ver e trocar o ambiente activo (.env)            |
|        |            | `.env` passa a ser autoritativo (load_dotenv override); nova dependência `textual`                  |

## Referências

[Hardware Raspberry](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html)
