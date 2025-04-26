#!/usr/bin/env python3
# filepath: /home/pagalava/digipay-iot_src/diagnosticos_pagalava.py

"""
Ferramenta de Diagnóstico de Dispositivo IoT PagaLava

Este script realiza uma série de verificações no dispositivo IoT para garantir 
a configuração e conectividade adequadas:
1. Conectividade à Internet
2. Versão atual do software
3. Presença e integridade dos ficheiros necessários
4. Validade da string de conexão do IoT Hub
5. Correção do ficheiro de configuração (config.json)
6. Conectividade ao IoT Hub
"""

import os
import sys
import json
import time
import socket
import subprocess
import re
import logging
import argparse
from datetime import datetime
import requests
import uuid

from dotenv import load_dotenv
from azure.iot.device import IoTHubDeviceClient
from azure.iot.device import exceptions as iot_exceptions

# Configurar logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Definir os ficheiros que devem estar presentes no sistema
REQUIRED_FILES = [
    "ReceiveMessages.py",
    "relay_ops.py",
    "requirements.txt",
    "config.json",
    "version.json",
    "update_pagalava.sh",
    "get_journalctl.sh",
    "restart_service.sh",
    "stop_service.sh",
    "test.sh"
]

# Cores ASCII para saída no terminal
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

def header(title):
    """Imprime um cabeçalho formatado para uma secção"""
    print(f"\n{Colors.HEADER}{Colors.BOLD}==== {title} ===={Colors.ENDC}")

def success(message):
    """Imprime uma mensagem de sucesso"""
    print(f"{Colors.GREEN}✓ {message}{Colors.ENDC}")

def warning(message):
    """Imprime uma mensagem de aviso"""
    print(f"{Colors.YELLOW}⚠ {message}{Colors.ENDC}")

def error(message):
    """Imprime uma mensagem de erro"""
    print(f"{Colors.RED}✗ {message}{Colors.ENDC}")

def info(message):
    """Imprime uma mensagem informativa"""
    print(f"{Colors.BLUE}ℹ {message}{Colors.ENDC}")

def check_internet_connectivity():
    """Verifica se o dispositivo tem conectividade à Internet"""
    header("CONECTIVIDADE À INTERNET")
    
    # Método 1: Verificar resolução DNS
    try:
        socket.gethostbyname("www.microsoft.com")
        success("Resolução DNS a funcionar corretamente")
    except socket.gaierror:
        error("Falha na resolução DNS - não é possível resolver nomes de domínio")
        return False
    
    # Método 2: Teste de ping
    try:
        result = subprocess.run(
            ["ping", "-c", "3", "8.8.8.8"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0:
            ping_output = result.stdout.strip().split("\n")[-1]
            if "0% packet loss" in result.stdout:
                success(f"Teste de ping bem-sucedido: {ping_output}")
            else:
                warning(f"Teste de ping concluído com alguma perda de pacotes: {ping_output}")
        else:
            error("Falha no teste de ping")
    except (subprocess.TimeoutExpired, subprocess.SubprocessError) as e:
        error(f"Erro no teste de ping: {str(e)}")
    
    # Método 3: Pedido HTTP
    try:
        response = requests.get("https://azure.microsoft.com", timeout=10)
        if response.status_code == 200:
            success("Conectividade HTTPS a funcionar corretamente")
        else:
            warning(f"O pedido HTTPS retornou o código de estado: {response.status_code}")
    except requests.RequestException as e:
        error(f"Erro de conectividade HTTPS: {str(e)}")
        return False
    
    return True

def get_version():
    """Obtém a versão atual do software do version.json"""
    header("VERSÃO DO SOFTWARE")
    
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        version_file_path = os.path.join(script_dir, "version.json")
        
        if os.path.exists(version_file_path):
            with open(version_file_path, 'r') as file:
                version_data = json.load(file)
                version = version_data.get('version', 'Desconhecida')
                success(f"Versão atual do software: {version}")
                return version
        else:
            error(f"Ficheiro de versão não encontrado em {version_file_path}")
            return "Desconhecida"
    except Exception as e:
        error(f"Falha ao ler o ficheiro de versão: {str(e)}")
        return "Desconhecida"

def check_required_files():
    """Verifica se todos os ficheiros necessários estão presentes e não estão vazios"""
    header("FICHEIROS NECESSÁRIOS")
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    missing_files = []
    empty_files = []
    
    for filename in REQUIRED_FILES:
        file_path = os.path.join(script_dir, filename)
        if not os.path.exists(file_path):
            missing_files.append(filename)
        elif os.path.getsize(file_path) == 0:
            empty_files.append(filename)
    
    # Verificar todos os ficheiros Python no diretório
    for filename in os.listdir(script_dir):
        if filename.endswith('.py') and filename not in REQUIRED_FILES:
            file_path = os.path.join(script_dir, filename)
            if os.path.getsize(file_path) == 0:
                empty_files.append(filename)
    
    if not missing_files and not empty_files:
        success("Todos os ficheiros necessários estão presentes e não estão vazios")
        return True
    
    if missing_files:
        error(f"Ficheiros em falta: {', '.join(missing_files)}")
    
    if empty_files:
        error(f"Ficheiros vazios: {', '.join(empty_files)}")
    
    return False

def check_connection_string():
    """Verifica se a string de conexão do IoT Hub está definida e é válida"""
    header("STRING DE CONEXÃO IOT")
    
    # Primeiro tenta variável de ambiente
    iot_conn_string = os.getenv("IOT_CONNECTION_STRING")
    
    # Se não estiver no ambiente, tenta o ficheiro .env
    if not iot_conn_string:
        try:
            load_dotenv()
            iot_conn_string = os.getenv("IOT_CONNECTION_STRING")
        except Exception as e:
            error(f"Falha ao carregar o ficheiro .env: {str(e)}")
    
    if not iot_conn_string:
        error("IOT_CONNECTION_STRING não encontrada no ambiente ou no ficheiro .env")
        return False, None
    
    # Verificar formato da string de conexão
    required_parts = ["HostName", "DeviceId", "SharedAccessKey"]
    missing_parts = [part for part in required_parts if f"{part}=" not in iot_conn_string]
    
    if missing_parts:
        error(f"A string de conexão está a faltar partes necessárias: {', '.join(missing_parts)}")
        return False, None
    
    # Extrair e exibir informações (sem revelar a chave completa)
    hostname_match = re.search(r'HostName=([^;]+)', iot_conn_string)
    device_id_match = re.search(r'DeviceId=([^;]+)', iot_conn_string)
    key_match = re.search(r'SharedAccessKey=([^;]+)', iot_conn_string)
    
    if hostname_match and device_id_match and key_match:
        hostname = hostname_match.group(1)
        device_id = device_id_match.group(1)
        key = key_match.group(1)
        
        # Determinar ambiente com base no hostname
        env = "dev" if "IoTHub-dev" in hostname else "prod"
        
        success(f"O formato da string de conexão é válido")
        info(f"Ambiente: {env.upper()}")
        info(f"IoT Hub: {hostname}")
        info(f"ID do Dispositivo: {device_id}")
        info(f"Chave: {key[:3]}...{key[-3:]}")
        
        # Extrair informações do ambiente
        environment = {
            "env": env,
            "hostname": hostname,
            "device_id": device_id
        }
        
        return True, environment
    else:
        error("Falha ao analisar os componentes da string de conexão")
        return False, None

def check_config_json():
    """Verifica se config.json existe e tem a estrutura correta"""
    header("CONFIG.JSON")
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(script_dir, "config.json")
    
    if not os.path.exists(config_path):
        warning("Ficheiro config.json não encontrado")
        info("Isto é normal se o dispositivo ainda não foi configurado para máquinas específicas")
        info("Execute 'setup_pagalava_iot.sh' para configurar o dispositivo ou aguarde pela configuração remota")
        return True  # Retorna True pois isto não é um erro crítico
    
    try:
        with open(config_path, 'r') as file:
            config = json.load(file)
            
            if not config:
                warning("O config.json está vazio")
                info("Aguarde pela configuração remota do dispositivo")
                return True  # Também não é considerado erro crítico
            
            # Verificar o esquema esperado (v1.2)
            sample_machine_id = next(iter(config), None)
            
            if not sample_machine_id:
                warning("Nenhuma configuração de máquina encontrada em config.json")
                return True  # Dispositivo sem máquinas configuradas
            
            sample_config = config[sample_machine_id]
            required_fields = [
                'machine_id', 
                'relay_number', 
                'time_relay_ms', 
                'interval_between_impulses_ms', 
                'number_of_impulses_activation'
            ]
            
            missing_fields = [field for field in required_fields if field not in sample_config]
            
            if missing_fields:
                warning(f"O config.json está a faltar campos obrigatórios: {', '.join(missing_fields)}")
                warning("Isto pode indicar uma versão de esquema desatualizada")
                return True  # Permitir versões diferentes de schema
            
            # Mostrar resumo das máquinas configuradas
            machine_count = len(config)
            success(f"O config.json é válido (versão do esquema 1.2)")
            info(f"Máquinas configuradas: {machine_count}")
            
            # Exibir todas as configurações de máquinas
            header("LISTAGEM DE MÁQUINAS CONFIGURADAS")
            for machine_id, machine_config in config.items():
                info(f"Máquina {machine_id}: relé {machine_config['relay_number']}, " +
                     f"tempo {machine_config['time_relay_ms']}ms, " +
                     f"impulsos {machine_config['number_of_impulses_activation']}")
            
            return True
            
    except json.JSONDecodeError:
        error("O config.json não é um JSON válido")
        return False  # Este é um erro crítico, pois indica corrupção
    except Exception as e:
        error(f"Erro ao analisar config.json: {str(e)}")
        return False  # Erro ao processar o arquivo é crítico

def check_iot_hub_connection_via_cloud(connection_string):
    """
    Verifica a conectividade ao IoT Hub enviando uma mensagem para a API 
    e esperando que o dispositivo a receba e escreva um ficheiro.
    """
    header("CONECTIVIDADE AO IOT HUB")
    
    # Verificar primeiro se o serviço está em execução
    try:
        service_status = subprocess.run(
            ["systemctl", "is-active", "receive_messages.service"],
            capture_output=True, text=True
        ).stdout.strip()
        
        if service_status != "active":
            warning(f"O serviço receive_messages não está ativo (estado: {service_status})")
            warning("A conexão do IoT Hub não pode ser verificada sem o serviço em execução")
            return False
    except Exception as e:
        error(f"Erro ao verificar o estado do serviço: {str(e)}")
        return False
    
    # Extrair informações da string de conexão
    device_id_match = re.search(r'DeviceId=([^;]+)', connection_string)
    hostname_match = re.search(r'HostName=([^;]+)', connection_string)
    
    if not device_id_match or not hostname_match:
        error("Não foi possível extrair o ID do dispositivo ou hostname da string de conexão")
        return False
    
    device_id = device_id_match.group(1)
    hostname = hostname_match.group(1)
    
    # Gerar código de verificação único
    verification_code = str(uuid.uuid4())
    info(f"Código de verificação gerado: {verification_code[:8]}...")
    
    # Determinar o ambiente e URL da API
    env = "dev" if "IoTHub-dev" in hostname else "prod"
    api_url = f"https://digipay2-dashboard-{env if env == 'dev' else ''}.azurewebsites.net/api/diagnostics/verify_device"
    
    # Dados para enviar à API
    payload = {
        "device_id": device_id,
        "verification_code": verification_code
    }
    
    info(f"A enviar pedido de diagnóstico para: {api_url}")
    
    try:
        # Enviar pedido para a API
        response = requests.post(api_url, json=payload, timeout=15)
        
        if response.status_code != 200:
            error(f"Falha ao enviar pedido de diagnóstico. Código de estado: {response.status_code}")
            if response.text:
                error(f"Resposta: {response.text}")
            return False
        
        info("Pedido de diagnóstico enviado com sucesso. A aguardar resposta do dispositivo...")
        
        # Caminho para o ficheiro de verificação
        script_dir = os.path.dirname(os.path.abspath(__file__))
        diagnostic_dir = os.path.join(script_dir, "diagnostics")
        verification_file = os.path.join(diagnostic_dir, "verification_code.txt")
        
        # Aguardar até 60 segundos pelo ficheiro de verificação
        max_wait_time = 60
        start_time = time.time()
        
        while (time.time() - start_time) < max_wait_time:
            if os.path.exists(verification_file):
                try:
                    with open(verification_file, 'r') as file:
                        received_code = file.read().strip()
                    
                    # Verificar se o código recebido corresponde ao enviado
                    if received_code == verification_code:
                        success("Código de verificação recebido corretamente!")
                        success("Comunicação bidirecional com o IoT Hub confirmada")
                        
                        # Limpar ficheiro de verificação
                        os.remove(verification_file)
                        return True
                    else:
                        error(f"Código de verificação não corresponde! Esperado: {verification_code}, Recebido: {received_code}")
                        os.remove(verification_file)
                        return False
                except Exception as e:
                    error(f"Erro ao ler ficheiro de verificação: {str(e)}")
                    return False
            
            # Aguardar 2 segundos antes de verificar novamente
            time.sleep(2)
            info(f"A aguardar resposta... {int(time.time() - start_time)}s/{max_wait_time}s")
        
        error(f"Timeout após {max_wait_time} segundos. Nenhuma resposta recebida do IoT Hub.")
        return False
        
    except requests.RequestException as e:
        error(f"Erro ao comunicar com a API: {str(e)}")
        return False
    except Exception as e:
        error(f"Erro inesperado durante verificação: {str(e)}")
        return False

def check_service_status_only():
    """Verifica apenas o estado do serviço, sem tentar conexão direta ao IoT Hub"""
    header("SERVIÇO IOT HUB")
    
    try:
        # Verificar se o serviço está em execução
        service_status = subprocess.run(
            ["systemctl", "is-active", "receive_messages.service"],
            capture_output=True, text=True
        ).stdout.strip()
        
        if service_status == "active":
            success("Serviço receive_messages está ativo")
            
            # Verificar logs do serviço para confirmar conectividade
            try:
                # Obter os logs mais recentes, limitados a 50 linhas
                recent_logs = subprocess.run(
                    ["journalctl", "-u", "receive_messages.service", "-n", "50", "--no-pager"],
                    capture_output=True, text=True, timeout=5
                ).stdout
                
                # Verificar padrões nos logs que indicam conexão bem-sucedida
                if "Conectado com sucesso ao IoT Hub" in recent_logs or "Connected to IoT Hub" in recent_logs:
                    success("Os logs indicam que o serviço está conectado ao IoT Hub")
                    return True
                elif "Waiting for message" in recent_logs or "Aguardando mensagem" in recent_logs:
                    success("Serviço está aguardando mensagens do IoT Hub")
                    return True
                elif "Error" in recent_logs or "Exception" in recent_logs or "Erro" in recent_logs:
                    warning("Os logs mostram possíveis erros no serviço")
                    info("Verifique os logs completos com: journalctl -u receive_messages.service")
                    return False
                else:
                    info("Serviço está ativo, mas não foi possível confirmar o estado da conexão pelos logs")
                    info("Verifique os logs completos com: journalctl -u receive_messages.service")
                    return True  # Assumir que está ok se o serviço estiver ativo
            except Exception as e:
                warning(f"Não foi possível analisar os logs do serviço: {str(e)}")
                info("Serviço está ativo, mas não foi possível verificar os logs")
                return True  # Assumir que está ok se o serviço estiver ativo
        else:
            error(f"Serviço receive_messages não está ativo (estado: {service_status})")
            info("Para iniciar o serviço execute: sudo systemctl start receive_messages.service")
            return False
            
    except Exception as e:
        error(f"Erro ao verificar o estado do serviço: {str(e)}")
        return False

def check_service_and_connectivity(connection_string):
    """
    Verifica o estado do serviço IoT e tenta diagnóstico direto se o serviço não estiver em execução
    """
    header("SERVIÇO IOT HUB")
    
    try:
        # Verificar se o serviço está em execução
        service_status = subprocess.run(
            ["systemctl", "is-active", "receive_messages.service"],
            capture_output=True, text=True
        ).stdout.strip()
        
        if service_status == "active":
            success("Serviço receive_messages está ativo")
            
            # Verificar logs do serviço para confirmar conectividade
            try:
                # Obter os logs mais recentes, limitados a 50 linhas
                recent_logs = subprocess.run(
                    ["journalctl", "-u", "receive_messages.service", "-n", "50", "--no-pager"],
                    capture_output=True, text=True, timeout=5
                ).stdout
                
                # Verificar padrões nos logs que indicam conexão bem-sucedida
                if "Conectado com sucesso ao IoT Hub" in recent_logs or "Connected to IoT Hub" in recent_logs:
                    success("Os logs indicam que o serviço está conectado ao IoT Hub")
                    return True
                elif "Waiting for message" in recent_logs or "Aguardando mensagem" in recent_logs:
                    success("Serviço está aguardando mensagens do IoT Hub")
                    return True
                elif "Error" in recent_logs or "Exception" in recent_logs or "Erro" in recent_logs:
                    warning("Os logs mostram possíveis erros no serviço")
                    info("Verifique os logs completos com: journalctl -u receive_messages.service")
                    # Não retornamos False aqui, vamos verificar via mensagem diagnóstica
                else:
                    info("Serviço está ativo, mas não foi possível confirmar o estado da conexão pelos logs")
                    info("Verificando com teste de diagnóstico...")
            except Exception as e:
                warning(f"Não foi possível analisar os logs do serviço: {str(e)}")
                info("Tentando verificação alternativa...")
        else:
            warning(f"Serviço receive_messages não está ativo (estado: {service_status})")
            info("Para iniciar o serviço execute: sudo systemctl start receive_messages.service")
            info("Tentando verificação direta da conectividade...")
            
        # Em qualquer caso, tentar um teste de diagnóstico enviando mensagem
        return check_iot_hub_connection_via_cloud(connection_string)
            
    except Exception as e:
        warning(f"Erro ao verificar o estado do serviço: {str(e)}")
        info("Tentando verificação direta da conectividade...")
        return check_iot_hub_connection_via_cloud(connection_string)

def create_quick_test_report(results):
    """Criar um relatório resumido de teste rápido"""
    header("RESUMO DO DIAGNÓSTICO")
    
    all_passed = all(results.values())
    
    if all_passed:
        success("TODAS AS VERIFICAÇÕES PASSARAM - O dispositivo está corretamente configurado e online")
    else:
        failed_tests = [test for test, result in results.items() if not result]
        error(f"ALGUMAS VERIFICAÇÕES FALHARAM: {', '.join(failed_tests)}")
        print("\nRecomendações:")
        
        if not results.get("internet", True):
            print("- Verifique as configurações de rede e a conectividade à Internet")
            print("- Verifique se a conexão Wi-Fi ou Ethernet está a funcionar")
        
        if not results.get("files", True):
            print("- Restaure os ficheiros em falta puxando do repositório")
            print("- Execute o script update_pagalava.sh para restaurar ficheiros")
        
        if not results.get("connection_string", True):
            print("- Verifique se o ficheiro .env contém a IOT_CONNECTION_STRING correta")
            print("- Execute setup_pagalava_iot.sh para reconfigurar a string de conexão")
        
        if not results.get("config", True):
            print("- Verifique o formato e conteúdo do config.json")
            print("- Solicite uma nova configuração ao servidor")
        
        if not results.get("iot_hub", True):
            print("- Verifique a conectividade à Internet")
            print("- Verifique se a string de conexão está correta")
            print("- Verifique se o dispositivo está registado no IoT Hub")
    
    # Obter timestamp atual
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\nDiagnóstico concluído em: {timestamp}")

def main():
    """Função principal que executa todos os diagnósticos"""
    parser = argparse.ArgumentParser(description='Ferramenta de Diagnóstico de Dispositivo IoT PagaLava')
    parser.add_argument('--verbose', '-v', action='store_true', help='Ativar saída detalhada')
    args = parser.parse_args()
    
    if args.verbose:
        logger.setLevel(logging.DEBUG)
    
    print(f"{Colors.BOLD}FERRAMENTA DE DIAGNÓSTICO DE DISPOSITIVO IOT DIGIPAY{Colors.ENDC}")
    print(f"A executar diagnósticos em {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    # Executar todas as verificações
    internet_ok = check_internet_connectivity()
    version = get_version()
    files_ok = check_required_files()
    conn_string_ok, env_info = check_connection_string()
    config_ok = check_config_json()  # Agora retorna True mesmo sem config.json
    
    # Verificar conectividade IoT, não apenas estado do serviço
    iot_service_ok = False
    if internet_ok and conn_string_ok:
        connection_string = os.getenv("IOT_CONNECTION_STRING")
        iot_service_ok = check_service_and_connectivity(connection_string)
    else:
        warning("A saltar a verificação do serviço IoT devido a pré-requisitos falhados")
    
    # Recolher resultados
    results = {
        "internet": internet_ok,
        "files": files_ok,
        "connection_string": conn_string_ok,
        "config": config_ok,
        "iot_hub": iot_service_ok
    }
    
    create_quick_test_report(results)
    return 0 if all(results.values()) else 1

if __name__ == "__main__":
    sys.exit(main())