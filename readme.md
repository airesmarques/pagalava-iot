# PagaLava IoT

Este repositório contém o software e a documentação do dispositivo de Pagamentos PagaLava, baseado num Raspberry Pi.

## Instalação

| | Guia | Descrição |
|---|------|-----------|
| 1 | [Preparação do Hardware](./instructions/hardware.md) | Material necessário e ligação dos módulos de relés ao Raspberry. |
| 2 | [Instalação por cartão SD](https://gerir.pagalava.pt) | Método recomendado. As instruções estão na dashboard PagaLava, em gerir.pagalava.pt. |

Já usava o método anterior (Raspberry Pi Imager + scripts de instalação por SSH)? Continua disponível em
[Instalação Manual (método anterior)](./instructions/instalacao_legacy.md).

## Depois da instalação

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
