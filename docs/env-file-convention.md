# Convenção dos ficheiros `.env`

Este documento existe porque a instalação simplificada mudou a forma como o
`.env` é criado, e à primeira vista parece ter abandonado a convenção. Não
abandonou — mas a distinção não era óbvia e vale a pena ficar escrita.

## O que o `.env` significa

O `.env` guarda **a identidade de ambiente do dispositivo**: a que IoT Hub e a
que backend é que ele fala. Nada mais.

Todos os consumidores leem exactamente uma chave:

| Consumidor | Lê |
|---|---|
| `configurar.py` | `IOT_CONNECTION_STRING` (constante `CONNECTION_KEY`) |
| `diagnosticos_pagalava.py` | `IOT_CONNECTION_STRING` |
| `ReceiveMessages.py` | `IOT_CONNECTION_STRING` (via `load_dotenv(override=True)`) |

Foi essa a decisão tomada em `configurar-bootstrap-migration.md`: tirar a
connection string da linha `Environment=` do systemd e pô-la no `.env`, para
que o `configurar.py` possa gerir vários ambientes e trocar entre eles.

**Essa decisão mantém-se.** A connection string continua a viver no `.env`, e
continua a ser a única fonte de verdade.

## A forma que o `configurar.py` precisa

O `configurar.py` descobre ambientes por *glob* de `.env.<sufixo>` e troca
reapontando o symlink `.env`. Um `.env` simples, sem irmãos, deixa o
dispositivo sem nada para onde trocar.

Por isso o primeiro arranque escreve:

```
.env -> .env.dev        (symlink)
.env.dev                (modo 600, dono pagalava)
```

O nome do ambiente vem da própria connection string (`IoTHub-dev` no hostname),
igual ao que `determine_environment()` faz em `ReceiveMessages.py`.

Um dispositivo instalado pela via simplificada fica assim gerível pelo
`configurar.py` exactamente como um instalado à mão.

### O backup tem de ser `.env.bak`

Ao reprovisionar, o `.env` anterior é guardado como `.env.bak`.

Tem de ser esse nome. O `configurar.py` ignora exactamente
`{bak, tmp, sample, example}` — qualquer outro sufixo (`.env.previous`, por
exemplo) aparece como **ambiente seleccionável**, ainda com a connection string
da lavandaria anterior. Trocar para ele faria o dispositivo passar-se por essa
lavandaria.

## O que NÃO vai para o `.env`

O ficheiro de instalação é um **formato de transporte**, não um ficheiro de
ambiente. Traz duas coisas, com destinos diferentes:

```
IOT_CONNECTION_STRING="..."   -> .env.<ambiente>
PAGALAVA_PASSWORD="..."       -> chpasswd, e depois esquecida
```

A palavra-passe SSH não entra no `.env`, por três razões:

1. **Não é específica do ambiente.** O dispositivo tem uma palavra-passe de
   sistema, independentemente do hub a que fala. No `.env` teria de ser
   duplicada em cada `.env.<sufixo>`, e uma troca de ambiente perdia-a
   silenciosamente — trancando o acesso ao dispositivo só por mudar de hub.
2. **O `.env` é carregado para o ambiente do processo** (`load_dotenv`), onde
   uma palavra-passe não tem utilidade nenhuma.
3. **É escrita uma vez.** Depois do `chpasswd`, o `/etc/shadow` é a fonte de
   verdade; uma cópia no `.env` seria um duplicado que fica desactualizado.

## Regra prática

> `.env` = a que ambiente o dispositivo pertence.
> Ficheiro de instalação = transporte, consumido e apagado no primeiro arranque.

Se aparecer uma chave nova, a pergunta é: *isto muda quando o dispositivo muda
de ambiente?* Se sim, vai para o `.env.<sufixo>`. Se não, tem outro destino.
