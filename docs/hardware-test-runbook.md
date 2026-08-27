# Runbook: testar uma versão de firmware em hardware real

Este runbook valida uma versão de firmware nos **dois caminhos de instalação**,
usando um PiKVM para não ser preciso mexer em cartões. Serve para correr à mão
hoje e está escrito para poder passar a um *job* de CI mais tarde — ver
[Caminho para CI](#caminho-para-ci) no fim.

Guia do dispositivo PiKVM em si (acesso, `kvmd-otgconf`, alimentação):
`devhub/IT_Standards/pikvm.md`.

## Quando correr isto

- Antes de fazer merge para `main`. **O merge é o gate de release**: o
  `update_pagalava.sh` está fixo em `origin/main`, portanto o que entrar em
  `main` chega a todos os dispositivos que fizerem upgrade. Não existe separação
  dev/prod no firmware.
- Sempre que mudar algo que só se manifesta em hardware: regras de `sudoers`,
  ficheiros de unidade `systemd`, GPIO/SPI, o arranque inicial.

## O que precisas

| | |
|---|---|
| PiKVM | `pikvm-l01.local`, root por chave SSH (chaves da frota) |
| Alvo | um Raspberry Pi ligado ao PiKVM por HDMI e USB, **sem cartão SD** |
| Imagem | a imagem PagaLava a testar, e Raspberry Pi OS Lite para o caminho manual |
| Ficheiro de instalação | descarregado do dashboard para a lavandaria de teste (99) |

> **A alimentação do Pi é o único passo físico.** Um Raspberry Pi não tem linha
> de standby, por isso Wake-on-LAN não funciona e o ATX do PiKVM também não se
> aplica (é para o header de um PC). Sem uma tomada inteligente ou um relé na
> alimentação, ligar o Pi exige alguém presente.

## Parte 1 — Caminho da imagem (instalação simplificada)

```bash
cd tests/hardware
export KVM_HOST=pikvm-l01.local
export TARGET_HOST=rpiPagalava99.local
export TARGET_USER=pagalava
export TARGET_PASS='<palavra-passe do dashboard>'
export LAUNDRY_ID=99

./serve_image.sh ~/pagalava-images/pagalava-iot-1.8-arm64.img.xz
./prepare_boot.sh flashed ~/pagalava-images/pagalava-provisioning-laundry-99.txt
# ---> ligar o Pi <---
./verify_device.sh flashed
```

O `verify_device.sh` confirma o que só o hardware prova: o hostname passou a ser
o id do dispositivo, o ficheiro de instalação foi **apagado** do cartão, o `.env`
é um symlink em modo 600 e **não** contém a palavra-passe, o serviço está
ligado ao IoT Hub, o `config.json` chegou, e o `sudo` permite exatamente o
reinício do serviço e o reboot — e nada mais.

## Parte 2 — Caminho manual (instalação especializada)

```bash
./serve_image.sh ~/images/2024-11-19-raspios-bookworm-arm64-lite.img.xz
./prepare_boot.sh manual pagalava '<palavra-passe temporária>'
# ---> ligar o Pi <---
export TARGET_HOST=raspberrypi.local
export FIRMWARE_BRANCH=feat/a-tua-branch     # 'main' depois do merge

./run_manual_install.sh provisioning   # usa o ficheiro, sem prompt
./run_manual_install.sh interactive    # responde ao prompt, como um instalador
./verify_device.sh manual
```

**Corre os dois modos.** Ter um ficheiro de instalação salta o
`read -r IOT_CONNECTION_STRING` por completo, ou seja o caminho que **todos os
instaladores existentes usam** nunca seria testado. Foi assim que passou
despercebido durante uma ronda inteira.

## Armadilhas já encontradas

Cada uma destas custou tempo e nenhuma aponta para a sua própria causa:

- **Expandir a imagem antes de a servir.** O Raspberry Pi OS cresce o sistema de
  ficheiros para encher o cartão no primeiro arranque; um disco virtual tem
  exatamente o tamanho do ficheiro, portanto não há para onde crescer. O rootfs
  fica pequeno, enche durante o `apt`, e falha com *No space left on device* muito
  depois do arranque que causou o problema. O `serve_image.sh` já expande.
- **Nunca correr o instalador com `sudo`.** Instala em `$HOME` e escreve a
  unidade com o utilizador que o invoca, portanto `sudo bash setup_pagalava_iot.sh`
  instala em `/root` e deixa o serviço a correr como root. O script agora recusa.
- **`sudo` sem tty.** Um serviço não tem terminal, logo qualquer `sudo` que peça
  palavra-passe falha em silêncio. Numa instalação manual isto não se nota porque
  o Raspberry Pi OS dá `NOPASSWD: ALL` ao primeiro utilizador (via
  `010_pi-nopasswd`); na imagem PagaLava não existe. Foi por isto que o *reboot*
  por mensagem estava a falhar apenas nos dispositivos instalados por imagem.
- **A imagem tem de estar montada em modo escrita.** `--set-rw 1` diz que
  funcionou e não faz nada se o *store* estiver read-only, e a flag `ro` não muda
  enquanto houver um ficheiro ligado.
- **Ver o que se está a fazer.** Se alguém estiver a acompanhar pelo KVM, espelha
  o log para a consola — `sudo tail -f <log> > /dev/tty1`. Uma sessão SSH é
  invisível para quem está a olhar para o ecrã.

## Depois de passar

1. `bash tests/check_upgrade_from.sh <sha-antigo> HEAD` para cada versão ainda em
   produção (há dispositivos em 1.3 e 1.5).
2. Merge para `main` — a partir daí chega à frota.
3. Publicar a release no **GitHub** (os dispositivos clonam de lá, não do GitLab).

## Caminho para CI

Os scripts foram escritos para isto: sem prompts, configuração só por variáveis
de ambiente, e códigos de saída com significado — **0** passou, **1** uma
asserção falhou, **2** o ambiente está avariado. Um *job* deve tratar o 2 como
infraestrutura em baixo e não como código mau.

O que falta para automatizar por completo:

- **Alimentação remota do alvo.** É o único passo manual. Uma tomada inteligente
  ou um relé resolve — e relés são precisamente o que este projeto controla.
- **Um runner com acesso ao PiKVM**, com a chave SSH de root e as imagens em
  cache (transferir 2,6 GB por corrida é lento).
- **Segredos**: `TARGET_PASS` e o ficheiro de instalação são credenciais e têm de
  vir de variáveis protegidas do CI, nunca do repositório.

Sugestão de encadeamento, a correr só em MR para `main`:

```
build-image -> serve+prepare -> (power on) -> verify-flashed
                             -> serve+prepare -> (power on) -> manual-install -> verify-manual
```

Enquanto o passo de alimentação for manual, vale a pena mantê-lo como um *job*
`when: manual` no meio do pipeline, em vez de fingir que está automatizado.
