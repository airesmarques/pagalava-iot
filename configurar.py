#!/usr/bin/env python3
"""
Ficheiro: configurar.py

Aplicação de terminal (TUI, baseada em textual) para gerir os ambientes locais
do dispositivo IoT (ficheiros .env) e monitorar o estado dos relés.

Lista os ambientes candidatos (.env.<sufixo>) que estão junto a este script,
mostra os detalhes de cada um (DeviceId, dev/prod, chave de acesso mascarada),
marca o ambiente activo e permite trocá-lo.

O ambiente activo é aquilo para onde o ".env" aponta. São suportados (e
preservados automaticamente) dois formatos:
  * ".env" é um symlink (ex.: .env -> .env.1)  -> a troca reaponta o symlink.
  * ".env" é um ficheiro normal                 -> a troca copia o ficheiro
                                                  escolhido para .env (com backup
                                                  em .env.bak).
Após a troca, o serviço receive_messages.service é reiniciado para que a mudança
seja imediata, sem reiniciar o sistema operativo.

A aba "Relés" mostra o estado dos relés em tempo real (se relay_ops estiver
disponível) e um histórico de activações desde que o TUI foi aberto.

Executar a partir da pasta do projeto, com o ambiente virtual:

    .venv/bin/python configurar.py          # abrir a interface (TUI)
    .venv/bin/python configurar.py --listar  # listar os ambientes (sem interface)

Dependências externas: textual, e opcionalmente relay_ops/RPi.GPIO para monitorar relés.
"""
import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)

# Pasta que contém este script (e os ficheiros .env ao lado dele).
REPO_DIR = Path(__file__).resolve().parent
ACTIVE_ENV = REPO_DIR / ".env"
BACKUP_ENV = REPO_DIR / ".env.bak"
SWITCH_TMP = REPO_DIR / ".env.__switch__"
CONFIG_JSON = REPO_DIR / "config.json"
SERVICE_NAME = "receive_messages.service"
CONNECTION_KEY = "IOT_CONNECTION_STRING"
RESTART_TIMEOUT_S = 60

# Sufixos (a parte a seguir a ".env.") que não são ambientes seleccionáveis.
_IGNORED_SUFFIXES = {"bak", "tmp", "sample", "example"}


# ============================================================================
# CONNECTION STATUS
# ============================================================================

def get_service_status() -> tuple[bool, str]:
    """
    Check if receive_messages.service is running.
    Returns: (is_running: bool, status_text: str)
    """
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SERVICE_NAME],
            capture_output=True,
            text=True,
            timeout=5
        )
        is_active = result.returncode == 0
        status = result.stdout.strip()
        return is_active, status
    except Exception as e:
        logging.warning("Failed to check service status: %s", e)
        return False, "unknown"


def format_connection_indicator(is_connected: bool) -> str:
    """Format connection status as a colored indicator."""
    if is_connected:
        return "[green]● Conectado[/green]"
    else:
        return "[red]● Desconectado[/red]"


# ============================================================================
# RELAY MONITORING
# ============================================================================

@dataclass
class RelayEvent:
    """Um evento de activação de relé."""
    relay_number: int
    machine_id: str
    activated_at: datetime
    duration_ms: int


class RelayMonitor:
    """Monitor de estado dos relés em tempo real."""

    def __init__(self, config_path: Path = CONFIG_JSON):
        self.config_path = config_path
        self.relay_map: dict[int, str] = {}  # relay_number -> machine_id
        self.active: set[int] = set()  # relay numbers currently on
        self.history: list[RelayEvent] = []
        self._lock = threading.Lock()
        self._timers: dict[int, threading.Timer] = {}  # relay deactivation timers
        self._load_config()

    def _load_config(self):
        """Carrega a configuração de relés a partir de config.json."""
        try:
            with open(self.config_path, 'r') as f:
                config = json.load(f)
            self.relay_map.clear()
            for machine_id_str, machine_config in config.items():
                if isinstance(machine_config, dict):
                    relay_number = int(machine_config.get('relay_number', 0))
                    if relay_number > 0:
                        self.relay_map[relay_number] = machine_id_str
            logging.info("RelayMonitor: carregou %d relés de config.json", len(self.relay_map))
        except Exception as e:
            logging.warning("RelayMonitor: falha ao carregar config.json: %s", e)

    def on_activate(self, relay_number: int, duration_ms: int):
        """Registar activação de um relé."""
        with self._lock:
            machine_id = self.relay_map.get(relay_number, "?")
            event = RelayEvent(relay_number, machine_id, datetime.now(), duration_ms)
            self.history.append(event)
            self.active.add(relay_number)

            # Agendar desactivação após duration_ms
            if relay_number in self._timers:
                self._timers[relay_number].cancel()
            timer = threading.Timer(duration_ms / 1000.0, self._deactivate, args=(relay_number,))
            timer.daemon = True
            timer.start()
            self._timers[relay_number] = timer

    def _deactivate(self, relay_number: int):
        """Desactivar um relé após timeout."""
        with self._lock:
            self.active.discard(relay_number)
            if relay_number in self._timers:
                del self._timers[relay_number]

    def refresh_config(self):
        """Re-carregar config.json (chamado quando o utilizador pressiona R)."""
        self._load_config()

    def get_active_relays(self) -> set[int]:
        """Devolve conjunto de relés actualmente activos."""
        with self._lock:
            return self.active.copy()

    def get_recent_history(self, n: int = 30) -> list[RelayEvent]:
        """Devolve os últimos N eventos de activação."""
        with self._lock:
            return list(reversed(self.history[-n:]))


# ============================================================================
# ENVIRONMENT MANAGEMENT (original code)
# ============================================================================

@dataclass
class EnvInfo:
    """Detalhes de um ficheiro de ambiente candidato."""

    path: Path
    name: str  # o sufixo a seguir a ".env." (ex.: "1", "prod.02")
    connection_string: str
    device_id: str
    host: str
    env_type: str  # "dev" ou "prod"
    is_active: bool = False

    @property
    def masked_connection(self) -> str:
        return _mask_connection_string(self.connection_string)


def _read_connection_string(path: Path) -> str:
    """Devolve o valor de IOT_CONNECTION_STRING de um ficheiro .env, ou ""."""
    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            if key.strip() == CONNECTION_KEY:
                value = value.strip()
                # Remover um par de aspas envolventes, se existir.
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                return value.strip()
    except OSError as exc:
        logging.error("Falha ao ler %s: %s", path, exc)
    return ""


def _extract(pattern: str, text: str, default: str) -> str:
    match = re.search(pattern, text)
    return match.group(1) if match else default


def _device_id(connection_string: str) -> str:
    return _extract(r"DeviceId=([^;]+)", connection_string, "dispositivo_desconhecido")


def _host(connection_string: str) -> str:
    return _extract(r"HostName=([^;]+)", connection_string, "host_desconhecido")


def _env_type(connection_string: str) -> str:
    """Igual a ReceiveMessages.determine_environment(): host com IoTHub-dev -> dev."""
    host = _host(connection_string)
    return "dev" if "IoTHub-dev" in host else "prod"


def _mask_connection_string(connection_string: str) -> str:
    """Mascara o valor da SharedAccessKey, mantendo o resto legível."""
    if not connection_string:
        return "(vazio)"

    def _mask_key(match: "re.Match") -> str:
        key = match.group(1)
        if len(key) <= 8:
            visible = "*" * len(key)
        else:
            visible = "%s...%s" % (key[:4], key[-4:])
        return "SharedAccessKey=" + visible

    return re.sub(r"SharedAccessKey=([^;]+)", _mask_key, connection_string)


def _is_candidate(path: Path) -> bool:
    name = path.name
    if not name.startswith(".env."):
        return False
    suffix = name[len(".env."):]
    if not suffix or suffix.startswith("__"):
        return False
    if suffix in _IGNORED_SUFFIXES:
        return False
    if suffix.endswith((".tmp", ".bak", ".swp")):
        return False
    return True


def _active_target_name() -> Optional[str]:
    """Se .env for um symlink, devolve o nome para onde aponta (ex.: '.env.1')."""
    if ACTIVE_ENV.is_symlink():
        try:
            return os.path.basename(os.readlink(ACTIVE_ENV))
        except OSError:
            return None
    return None


def discover_envs() -> List[EnvInfo]:
    """Encontra e analisa cada ficheiro candidato .env.<sufixo> junto ao script."""
    active_target = _active_target_name()
    active_connection = _read_connection_string(ACTIVE_ENV) if ACTIVE_ENV.exists() else ""
    envs: List[EnvInfo] = []
    for path in sorted(REPO_DIR.glob(".env.*")):
        if not path.is_file() or not _is_candidate(path):
            continue
        connection = _read_connection_string(path)
        if active_target is not None:
            # Formato symlink: o ambiente activo é o destino do symlink (por nome).
            is_active = path.name == active_target
        else:
            # Formato ficheiro: comparar por conteúdo.
            is_active = bool(connection) and connection == active_connection
        envs.append(
            EnvInfo(
                path=path,
                name=path.name[len(".env."):],
                connection_string=connection,
                device_id=_device_id(connection),
                host=_host(connection),
                env_type=_env_type(connection),
                is_active=is_active,
            )
        )
    return envs


def active_summary() -> str:
    """Descrição numa linha do ambiente .env actualmente activo."""
    if not ACTIVE_ENV.exists() and not ACTIVE_ENV.is_symlink():
        return "sem .env"
    connection = _read_connection_string(ACTIVE_ENV)
    device = _device_id(connection) if connection else "desconhecido"
    suffix = "  ->  %s" % _active_target_name() if _active_target_name() else ""
    if not connection:
        return ".env vazio/inválido%s" % suffix
    return "%s (%s)%s" % (device, _env_type(connection), suffix)


@dataclass
class ApplyResult:
    ok: bool
    env_name: str
    device_id: str
    messages: List[str] = field(default_factory=list)



def parse_connection_string(conn_str: str) -> dict:
    """
    Parse Azure IoT Hub connection string to extract device info.
    Returns dict with: device_id, host, env_type (dev/prod)
    """
    try:
        parts = {}
        for part in conn_str.split(';'):
            if '=' in part:
                key, value = part.split('=', 1)
                parts[key.strip()] = value.strip()
        
        device_id = parts.get('DeviceId', '')
        host = parts.get('HostName', '')
        
        if not device_id or not host:
            return None
        
        # Determine if dev or prod based on hostname
        env_type = 'dev' if 'IoTHub-dev' in host else 'prod'
        
        return {
            'device_id': device_id,
            'host': host,
            'env_type': env_type
        }
    except Exception:
        return None


def create_new_environment(conn_str: str) -> tuple[bool, str, str]:
    """
    Create a new .env file from a connection string.
    Returns: (success: bool, message: str, env_name: str or None)
    """
    parsed = parse_connection_string(conn_str)
    if not parsed:
        return False, "Ligação inválida: não foi possível analisar a string", None
    
    # Generate environment name from device_id
    env_name = parsed['device_id'].lower()
    env_path = REPO_DIR / f".env.{env_name}"
    
    # Check if already exists
    if env_path.exists():
        return False, f"Ambiente .env.{env_name} já existe", None
    
    try:
        env_path.write_text(f"IOT_CONNECTION_STRING={conn_str}\n", encoding='utf-8')
        env_path.chmod(0o600)
        return True, f"Novo ambiente criado: .env.{env_name}", env_name
    except Exception as e:
        return False, f"Erro ao criar ficheiro: {e}", None


def _switch_symlink(env: EnvInfo, messages: List[str]) -> bool:
    """Reaponta .env -> .env.<nome> de forma atómica. Devolve True em sucesso."""
    previous = _active_target_name()
    try:
        if SWITCH_TMP.is_symlink() or SWITCH_TMP.exists():
            SWITCH_TMP.unlink()
        os.symlink(env.path.name, SWITCH_TMP)  # destino relativo, ex.: ".env.1"
        os.replace(str(SWITCH_TMP), str(ACTIVE_ENV))
    except OSError as exc:
        logging.error("Falha ao actualizar o symlink .env: %s", exc)
        messages.append("ERRO: falha ao actualizar o symlink .env (%s)" % exc)
        try:
            if SWITCH_TMP.is_symlink():
                SWITCH_TMP.unlink()
        except OSError:
            pass
        return False
    if previous and previous != env.path.name:
        messages.append("Symlink .env reapontado: %s -> .env.%s" % (previous, env.name))
    else:
        messages.append("Symlink .env criado: -> .env.%s" % env.name)
    return True


def _switch_file(env: EnvInfo, messages: List[str]) -> bool:
    """Copia .env.<nome> para .env de forma atómica (com backup). True em sucesso."""
    try:
        if ACTIVE_ENV.exists():
            shutil.copy2(ACTIVE_ENV, BACKUP_ENV)
            messages.append("Backup do .env anterior em .env.bak")
    except OSError as exc:
        logging.warning("Não foi possível fazer backup do .env: %s", exc)
        messages.append("Aviso: não foi possível fazer backup do .env (%s)" % exc)
    try:
        data = env.path.read_bytes()
        fd, tmp_path = tempfile.mkstemp(dir=str(REPO_DIR), prefix=".env.", suffix=".tmp")
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, str(ACTIVE_ENV))
        messages.append("Escrito .env.%s em .env" % env.name)
        return True
    except OSError as exc:
        logging.error("Falha ao escrever .env: %s", exc)
        messages.append("ERRO: falha ao escrever .env (%s)" % exc)
        return False


def apply_environment(env: EnvInfo) -> ApplyResult:
    """Troca o .env activo para `env` e reinicia o serviço.

    A troca preserva o formato existente: um .env em symlink é reapontado; um .env
    em ficheiro normal é copiado. Se o reinício falhar, o .env já foi trocado, por
    isso um reinício manual posterior ainda aplica a mudança.
    """
    messages: List[str] = []

    # 1. Trocar o .env, preservando o formato (symlink vs ficheiro). Um .env em
    #    falta assume o formato symlink (convenção usada nos checkouts dev/dispositivo).
    use_symlink = ACTIVE_ENV.is_symlink() or not ACTIVE_ENV.exists()
    switched = _switch_symlink(env, messages) if use_symlink else _switch_file(env, messages)
    if not switched:
        return ApplyResult(False, env.name, env.device_id, messages)

    # 2. Reiniciar o serviço para a nova connection string ficar activa já.
    try:
        proc = subprocess.run(
            ["sudo", "systemctl", "restart", SERVICE_NAME],
            capture_output=True,
            text=True,
            timeout=RESTART_TIMEOUT_S,
        )
    except FileNotFoundError as exc:
        messages.append("ERRO: não foi possível executar systemctl (%s)" % exc)
        return ApplyResult(False, env.name, env.device_id, messages)
    except subprocess.TimeoutExpired:
        messages.append("ERRO: reinício do serviço excedeu o tempo limite (%ds)" % RESTART_TIMEOUT_S)
        return ApplyResult(False, env.name, env.device_id, messages)

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        messages.append("ERRO: reinício falhou (rc=%d): %s" % (proc.returncode, detail))
        messages.append("O .env foi alterado; reinicie o serviço manualmente para aplicar.")
        return ApplyResult(False, env.name, env.device_id, messages)

    messages.append("Serviço %s reiniciado" % SERVICE_NAME)

    # 3. Confirmar que o serviço está activo.
    try:
        check = subprocess.run(
            ["systemctl", "is-active", SERVICE_NAME],
            capture_output=True,
            text=True,
            timeout=15,
        )
        state = (check.stdout or check.stderr or "").strip()
        messages.append("Estado do serviço: %s" % state)
        ok = state == "active"
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        messages.append("Não foi possível verificar o estado do serviço (%s)" % exc)
        ok = True  # o comando de reinício em si teve sucesso

    return ApplyResult(ok, env.name, env.device_id, messages)


# ============================================================================
# TUI
# ============================================================================

try:
    from textual import work
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Container, Horizontal, Vertical
    from textual.screen import ModalScreen
    from textual.widgets import Button, DataTable, Footer, Header, Input, Static, TabbedContent, TabPane
    _TEXTUAL_AVAILABLE = True
except ImportError:
    _TEXTUAL_AVAILABLE = False


if _TEXTUAL_AVAILABLE:

    class NewEnvironmentScreen(ModalScreen):
        """Tela para criar um novo ambiente a partir de uma ligação."""

        BINDINGS = [
            Binding("escape", "cancel", "Cancelar"),
        ]

        def compose(self) -> ComposeResult:
            with Container(id="new-env-box"):
                yield Static("Criar novo ambiente", id="new-env-title")
                yield Static(
                    "Cole a string de ligação do IoT Hub:",
                    id="new-env-label"
                )
                yield Input(
                    placeholder="HostName=...;DeviceId=...;SharedAccessKey=...",
                    id="conn-string-input"
                )
                with Horizontal(id="new-env-buttons"):
                    yield Button("Criar (enter)", variant="primary", id="create")
                    yield Button("Cancelar (esc)", variant="default", id="cancel")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "create":
                input_widget = self.query_one("#conn-string-input", Input)
                conn_str = input_widget.value.strip()
                self.dismiss(conn_str if conn_str else None)
            else:
                self.dismiss(None)

        def action_cancel(self) -> None:
            self.dismiss(None)

    class ConfirmScreen(ModalScreen):
        """Confirmação Sim/Não antes de trocar de ambiente."""

        BINDINGS = [
            Binding("s,y", "confirm", "Sim"),
            Binding("n,escape", "cancel", "Não"),
        ]

        def __init__(self, env: EnvInfo) -> None:
            super().__init__()
            self._env = env

        def compose(self) -> ComposeResult:
            with Container(id="confirm-box"):
                yield Static(
                    "Mudar o ambiente activo para:\n\n"
                    "  Dispositivo:  [b]%s[/b]\n"
                    "  Ambiente:     [b]%s[/b]\n"
                    "  Ficheiro:     .env.%s\n\n"
                    "Isto actualiza o [b].env[/b] e reinicia o [b]%s[/b], "
                    "interrompendo brevemente a ligação IoT."
                    % (self._env.device_id, self._env.env_type, self._env.name, SERVICE_NAME),
                    id="confirm-text",
                )
                with Horizontal(id="confirm-buttons"):
                    yield Button("Sim, mudar (s)", variant="warning", id="yes")
                    yield Button("Cancelar (n)", variant="primary", id="no")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            self.dismiss(event.button.id == "yes")

        def action_confirm(self) -> None:
            self.dismiss(True)

        def action_cancel(self) -> None:
            self.dismiss(False)

    class ResultScreen(ModalScreen):
        """Mostra o resultado de uma operação de troca."""

        BINDINGS = [Binding("enter,escape,space", "close", "Fechar")]

        def __init__(self, result: ApplyResult) -> None:
            super().__init__()
            self._result = result

        def compose(self) -> ComposeResult:
            if self._result.ok:
                title = "[b green]Mudado para %s (.env.%s)[/b green]" % (
                    self._result.device_id,
                    self._result.env_name,
                )
            else:
                title = "[b red]Mudança incompleta[/b red]"
            body = "\n".join("  • %s" % m for m in self._result.messages)
            with Container(id="result-box"):
                yield Static(title, id="result-title")
                yield Static(body, id="result-body")
                yield Button("OK (enter)", variant="primary", id="ok")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            self.dismiss(None)

        def action_close(self) -> None:
            self.dismiss(None)

    class StatusBar(Static):
        """Barra de estado mostrando conexão."""

        def render(self) -> str:
            is_connected, status = get_service_status()
            indicator = format_connection_indicator(is_connected)
            return f"{indicator}"

        def on_mount(self) -> None:
            """Actualizar status a cada 2 segundos."""
            self.set_interval(2.0, self.refresh)

    class EnvTab(Static):
        """Aba de gestão de ambientes (.env)."""

        def compose(self) -> ComposeResult:
            yield Static(id="active-bar")
            with Horizontal(id="main"):
                with Vertical(id="table-pane"):
                    yield DataTable(id="env-table", cursor_type="row", zebra_stripes=True)
                with Vertical(id="detail-pane"):
                    yield Static("", id="detail-title")
                    yield Static("", id="detail-body")

        def on_mount(self) -> None:
            table = self.query_one(DataTable)
            table.add_columns("", "Ficheiro", "Dispositivo", "Amb.")
            self._reload()

        def _reload(self) -> None:
            envs = discover_envs()
            table = self.query_one(DataTable)
            saved_row = table.cursor_row
            table.clear()
            for info in envs:
                marker = "[green]●[/green]" if info.is_active else " "
                table.add_row(marker, ".env.%s" % info.name, info.device_id, info.env_type)
            self.query_one("#active-bar", Static).update(
                "Ambiente activo: [b]%s[/b]    Serviço: %s"
                % (active_summary(), SERVICE_NAME)
            )
            if envs:
                row = saved_row if 0 <= saved_row < len(envs) else 0
                table.move_cursor(row=row)
                self._show_detail(row, envs)
            else:
                self.query_one("#detail-title", Static).update("Nenhum ambiente .env.* encontrado")
                self.query_one("#detail-body", Static).update(
                    "Coloque ficheiros .env.<id> junto a este script."
                )

        def _show_detail(self, row: int, envs: list) -> None:
            if not (0 <= row < len(envs)):
                return
            info = envs[row]
            active = " [green](activo)[/green]" if info.is_active else ""
            self.query_one("#detail-title", Static).update(".env.%s%s" % (info.name, active))
            self.query_one("#detail-body", Static).update(
                "Dispositivo:  [b]%s[/b]\n"
                "Ambiente:     [b]%s[/b]\n"
                "Host:         %s\n\n"
                "Connection string (chave mascarada):\n%s"
                % (info.device_id, info.env_type, info.host, info.masked_connection)
            )

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            envs = discover_envs()
            self._show_detail(event.cursor_row, envs)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            self.app.action_apply()

    class RelayTab(Static):
        """Aba de monitoramento de relés."""

        def __init__(self, monitor: RelayMonitor, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.monitor = monitor

        def compose(self) -> ComposeResult:
            yield Static("", id="relay-active-bar")
            with Horizontal(id="relay-main"):
                with Vertical(id="relay-status-pane"):
                    yield DataTable(id="relay-status-table", cursor_type="row", zebra_stripes=True)
                with Vertical(id="relay-history-pane"):
                    yield Static("Histórico (desde abertura):", id="relay-history-title")
                    yield DataTable(id="relay-history-table", cursor_type="row")

        def on_mount(self) -> None:
            # Tabela de estado dos relés
            status_table = self.query_one("#relay-status-table", DataTable)
            status_table.add_columns("Relé", "Máquina", "Estado")

            # Tabela de histórico
            hist_table = self.query_one("#relay-history-table", DataTable)
            hist_table.add_columns("Hora", "Relé", "Máquina")

            self._refresh_display()
            self.set_interval(0.2, self._refresh_display)

        def _refresh_display(self) -> None:
            """Actualizar displays de relés activos e histórico."""
            # Barra de relés activos
            active = self.monitor.get_active_relays()
            if not self.monitor.relay_map:
                active_text = "Sem config.json ou nenhum relé configurado"
            elif not active:
                active_text = "Relés inactivos"
            else:
                active_list = " ".join("[green]●[/green] %d" % r for r in sorted(active))
                active_text = "Relés activos: " + active_list

            self.query_one("#relay-active-bar", Static).update(active_text)

            # Tabela de estado
            status_table = self.query_one("#relay-status-table", DataTable)
            status_table.clear()
            for relay_num in sorted(self.monitor.relay_map.keys()):
                machine_id = self.monitor.relay_map[relay_num]
                is_active = relay_num in active
                state = "[green]● ACTIVO[/green]" if is_active else "○ inactivo"
                status_table.add_row(str(relay_num), machine_id, state)

            # Tabela de histórico
            hist_table = self.query_one("#relay-history-table", DataTable)
            hist_table.clear()
            for event in self.monitor.get_recent_history(30):
                time_str = event.activated_at.strftime("%H:%M:%S.%f")[:-3]
                hist_table.add_row(time_str, str(event.relay_number), event.machine_id)

    class EnvManagerApp(App):
        """Aplicação principal: gestão de ambientes + monitoramento de relés."""

        TITLE = "Digipay IoT - Gestão de Ambientes & Relés"

        CSS = """
        Screen { layout: vertical; }
        #active-bar, #relay-active-bar {
            height: 2;
            padding: 0 2;
            background: $boost;
            border-bottom: solid $primary;
        }
        #main, #relay-main { height: 1fr; }
        #table-pane, #relay-status-pane { width: 2fr; border-right: solid $primary; }
        #detail-pane, #relay-history-pane { width: 3fr; padding: 1 2; }
        DataTable { height: 1fr; }
        #detail-title, #relay-history-title { text-style: bold; padding-bottom: 1; }
        #confirm-box, #result-box {
            width: 72; height: auto; padding: 1 2;
            border: thick $warning; background: $surface;
        }
        #result-box { border: thick $primary; }
        #confirm-buttons { height: auto; padding-top: 1; }
        #confirm-buttons Button, #result-box Button { margin: 1 1 0 0; }
        ModalScreen { align: center middle; }
        TabbedContent { height: 1fr; }
        """

        BINDINGS = [
            Binding("a,enter", "apply", "Aplicar", show=False),
            Binding("r", "refresh", "Actualizar", show=False),
            Binding("n", "new", "Novo", show=False),
            Binding("q", "quit", "Sair"),
        ]

        def __init__(self, monitor: RelayMonitor = None):
            super().__init__()
            self.monitor = monitor or RelayMonitor()

        def compose(self) -> ComposeResult:
            yield Header()
            yield StatusBar()
            with TabbedContent("Ambientes", "Relés"):
                with TabPane("Ambientes", id="tab-ambientes"):
                    yield EnvTab()
                with TabPane("Relés", id="tab-reles"):
                    yield RelayTab(self.monitor)
            yield Footer()

        def action_apply(self) -> None:
            """Aplicar ambiente (apenas na aba Ambientes)."""
            # Get the active tab pane
            tabbed = self.query_one(TabbedContent)
            if tabbed.active != "tab-ambientes":
                return
            env_tab = self.query_one(EnvTab)
            table = env_tab.query_one(DataTable)
            envs = discover_envs()
            row = table.cursor_row
            if 0 <= row < len(envs):
                env = envs[row]
                def _after_confirm(confirmed: Optional[bool]) -> None:
                    if confirmed:
                        env_tab._do_apply(env)
                self.push_screen(ConfirmScreen(env), _after_confirm)

        def action_refresh(self) -> None:
            """Actualizar (comportamento depende da aba)."""
            tabbed = self.query_one(TabbedContent)
            if tabbed.active == "tab-ambientes":
                env_tab = self.query_one(EnvTab)
                env_tab._reload()
                self.notify("Ambientes actualizados")
            elif tabbed.active == "tab-reles":
                self.monitor.refresh_config()
                relay_tab = self.query_one(RelayTab)
                relay_tab._refresh_display()
                self.notify("Relés actualizados")

        def action_new(self) -> None:
            """Criar novo ambiente a partir de uma ligação."""
            tabbed = self.query_one(TabbedContent)
            if tabbed.active != "tab-ambientes":
                self.notify("Use a aba Ambientes para criar novo ambiente")
                return
            
            def _after_input(conn_str: str) -> None:
                if conn_str:
                    success, msg, env_name = create_new_environment(conn_str)
                    if success:
                        self.notify(msg)
                        env_tab = self.query_one(EnvTab)
                        env_tab._reload()
                    else:
                        self.app.push_screen(
                            ResultScreen(
                                ApplyResult(False, "Erro", "", [msg])
                            )
                        )
            
            self.push_screen(NewEnvironmentScreen(), _after_input)


    class EnvTab_Extended(EnvTab):
        """Extensão de EnvTab com suporte para threads de apply."""

        @work(thread=True, exclusive=True)
        def _do_apply(self, env: EnvInfo) -> None:
            self.app.call_from_thread(self.notify, "A mudar para %s..." % env.device_id)
            result = apply_environment(env)
            self.app.call_from_thread(self._apply_finished, result)

        def _apply_finished(self, result: ApplyResult) -> None:
            self._reload()
            self.push_screen(ResultScreen(result))

    # Monkey-patch para adicionar os métodos de apply
    EnvTab._do_apply = EnvTab_Extended._do_apply
    EnvTab._apply_finished = EnvTab_Extended._apply_finished
    EnvTab.notify = lambda self, msg: self.app.notify(msg)
    EnvTab.push_screen = lambda self, screen: self.app.push_screen(screen)


def _print_list() -> None:
    """Listagem em texto simples, para uso sem terminal e verificação rápida."""
    envs = discover_envs()
    print("Ambiente activo: %s" % active_summary())
    print("Serviço:         %s" % SERVICE_NAME)
    print("")
    if not envs:
        print("Nenhum ambiente .env.* encontrado em %s" % REPO_DIR)
        return
    print("%-1s %-14s %-18s %-5s" % ("", "Ficheiro", "Dispositivo", "Amb."))
    for info in envs:
        marker = "*" if info.is_active else " "
        print("%-1s %-14s %-18s %-5s" % (marker, ".env." + info.name, info.device_id, info.env_type))
    print("\n(* = activo)")


def _wrap_relay_ops(monitor: RelayMonitor):
    """Envolve as funções relay_ops para reportar activações ao monitor."""
    try:
        import relay_ops as _relay_ops

        def _make_wrapper(original_fn):
            def wrapper(machine_id: int, number_of_impulses: int = 1):
                result = original_fn(machine_id, number_of_impulses)
                try:
                    mapping = _relay_ops.load_relay_mapping_v1_2()
                    entry = mapping.get(machine_id)
                    if entry:
                        monitor.on_activate(int(entry['relay_number']), int(entry['time_relay_ms']))
                except Exception:
                    pass  # Nunca deixar que o monitoramento quebre o serviço
                return result
            return wrapper

        _relay_ops.activate_machine_v1_0 = _make_wrapper(_relay_ops.activate_machine_v1_0)
        _relay_ops.activate_machine_v1_1 = _make_wrapper(_relay_ops.activate_machine_v1_1)
        _relay_ops.activate_machine_v1_2 = _make_wrapper(_relay_ops.activate_machine_v1_2)
        logging.info("RelayOps wrapping: sucesso")
    except ImportError:
        logging.warning("RelayOps não disponível; monitoramento desactivado")
    except Exception as e:
        logging.warning("Falha ao envolver relay_ops: %s", e)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Gerir os ambientes do Digipay IoT (ficheiros .env)."
    )
    parser.add_argument(
        "--listar",
        action="store_true",
        help="Listar os ambientes em texto simples e sair (sem interface).",
    )
    args = parser.parse_args()

    if args.listar:
        _print_list()
        return

    if not _TEXTUAL_AVAILABLE:
        logging.info("textual não encontrado; a instalar...")
        try:
            venv_pip = os.path.join(os.path.dirname(sys.executable), "pip")
            subprocess.run(
                [venv_pip, "install", "textual==8.2.7"],
                check=True,
            )
            logging.info("textual instalado com sucesso; a reiniciar...")
            os.execvp(sys.executable, [sys.executable, __file__] + sys.argv[1:])
        except subprocess.CalledProcessError:
            raise SystemExit(
                "Falha ao instalar textual. "
                "Instale manualmente com: .venv/bin/pip install textual==8.2.7"
            )

    monitor = RelayMonitor()
    _wrap_relay_ops(monitor)

    app = EnvManagerApp(monitor)
    app.run()


if __name__ == "__main__":
    main()
