# Configuração de WiFi no Raspberry Pi

Este guia explica como configurar a conexão WiFi no Raspberry Pi utilizando o arquivo `wpa_supplicant.conf`.

## Importante

Para sistemas PagaLava em produção, recomenda-se usar **apenas Ethernet** para maior estabilidade. A configuração WiFi é útil apenas para situações de desenvolvimento ou configuração inicial.

## Método 1: Configuração via Terminal

1. Aceda ao terminal do Raspberry Pi (por SSH ou diretamente)
2. Edite o arquivo de configuração WiFi com o seguinte comando:

```bash
sudo nano /etc/wpa_supplicant/wpa_supplicant.conf
```
3. Adicione a seguinte configuração, substituindo NOME_DA_REDE e PASSWORD pelos valores da sua rede:

```markdown
country=PT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="NOME_DA_REDE"
    psk="PASSWORD"
    key_mgmt=WPA-PSK
}
```

4. Guarde o arquivo (Ctrl+O, depois Enter) e saia do editor (Ctrl+X)
5. Reinicie o serviço WiFi:
```markdown

sudo wpa_cli -i wlan0 reconfigure
```

## Método 2: Pré-configuração no Cartão SD
Para configurar o WiFi antes do primeiro arranque:

1. Após gravar a imagem do Raspberry Pi OS no cartão SD, não remova o cartão
2. Navegue até à partição "boot" do cartão SD
3. Crie um novo arquivo chamado wpa_supplicant.conf com o seguinte conteúdo:

```markdown
country=PT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="NOME_DA_REDE"
    psk="PASSWORD"
    key_mgmt=WPA-PSK
}
```
4. Guarde o arquivo e ejete o cartão SD com segurança
5. Quando o Raspberry Pi iniciar pela primeira vez, ele copiará automaticamente este arquivo para o local correto e conectar-se-á à rede WiFi