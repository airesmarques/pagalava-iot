# Instalação por cartão SD

Detalhes do ficheiro de instalação e da imagem PagaLava. As instruções passo a passo
estão na dashboard, em [gerir.pagalava.pt](https://gerir.pagalava.pt).

[← Voltar à página principal](../readme.md)

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
- **Instalação normal:** siga a [Instalação Manual (método anterior)](./instalacao_legacy.md). Os scripts de
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
