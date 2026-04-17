import queue
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox

import serial
import serial.tools.list_ports


class SerialWorker:
    def __init__(self, on_rx_line, on_log):
        self.on_rx_line = on_rx_line
        self.on_log = on_log

        self.ser = None
        self.rx_thread = None
        self.stop_event = threading.Event()

        self.tx_queue: "queue.Queue[str]" = queue.Queue()

    def is_open(self) -> bool:
        return self.ser is not None and self.ser.is_open

    def open(self, port: str, baudrate: int = 115200) -> None:
        if self.is_open():
            self.close()

        self.stop_event.clear()
        self.ser = serial.Serial(port=port, baudrate=baudrate, timeout=0.1)
        self.rx_thread = threading.Thread(target=self._worker_loop, daemon=True)
        self.rx_thread.start()
        self.on_log(f"[INFO] 串口已打开: {port} @ {baudrate}")

    def close(self) -> None:
        self.stop_event.set()

        if self.rx_thread and self.rx_thread.is_alive():
            self.rx_thread.join(timeout=0.5)

        if self.ser is not None:
            try:
                if self.ser.is_open:
                    self.ser.close()
            except Exception:
                pass

        self.ser = None
        self.rx_thread = None
        self.on_log("[INFO] 串口已关闭")

    def send_line(self, text: str) -> None:
        if not self.is_open():
            self.on_log("[WARN] 串口未打开，发送失败")
            return
        self.tx_queue.put(text)

    def _worker_loop(self) -> None:
        assert self.ser is not None
        rx_buf = bytearray()

        while not self.stop_event.is_set():
            try:
                # TX
                try:
                    while True:
                        line = self.tx_queue.get_nowait()
                        payload = (line + "\n").encode("ascii", errors="ignore")
                        self.ser.write(payload)
                        self.on_log(f"[TX] {line}")
                except queue.Empty:
                    pass

                # RX
                data = self.ser.read(256)
                if data:
                    rx_buf.extend(data)

                    while True:
                        lf_idx = rx_buf.find(b"\n")
                        if lf_idx < 0:
                            break

                        raw = rx_buf[:lf_idx]
                        del rx_buf[:lf_idx + 1]

                        raw = raw.rstrip(b"\r")
                        if not raw:
                            continue

                        try:
                            line = raw.decode("ascii", errors="ignore").strip()
                        except Exception:
                            line = ""
                        if line:
                            self.on_rx_line(line)

                time.sleep(0.01)

            except Exception as e:
                self.on_log(f"[ERR] 串口线程异常: {e}")
                break


class DemoGuiApp:
    MODES = [
        "COLORBAR",
        "NETGRID",
        "GRAY",
        "BWSQUARE",
        "RED",
        "GREEN",
    ]

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("SFP Demo GUI v1")
        self.root.geometry("980x640")

        self.serial_worker = SerialWorker(self._post_rx_line, self._post_log)

        self.ui_queue: "queue.Queue[tuple[str, str]]" = queue.Queue()

        self.connected = False
        self.link_up = False
        self.osd_on = False
        self.menu_index = 0
        self.active_mode = "COLORBAR"

        self.last_warn_link_down = False
        self.last_status_rx_time = 0.0

        self._build_ui()
        self._refresh_ports()
        self._update_widgets_from_state()

        self.root.after(50, self._drain_ui_queue)
        # self.root.after(500, self._periodic_status_poll)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        main = ttk.Frame(self.root, padding=10)
        main.pack(fill=tk.BOTH, expand=True)

        # top
        top = ttk.Frame(main)
        top.pack(fill=tk.X, pady=(0, 8))

        ttk.Label(top, text="串口号:").pack(side=tk.LEFT)
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(top, textvariable=self.port_var, width=20, state="readonly")
        self.port_combo.pack(side=tk.LEFT, padx=(6, 8))

        ttk.Button(top, text="刷新串口", command=self._refresh_ports).pack(side=tk.LEFT, padx=(0, 8))
        self.btn_connect = ttk.Button(top, text="打开串口", command=self._toggle_connect)
        self.btn_connect.pack(side=tk.LEFT, padx=(0, 16))

        ttk.Label(top, text="链路状态:").pack(side=tk.LEFT)
        self.link_status_var = tk.StringVar(value="DOWN")
        self.link_status_label = ttk.Label(top, textvariable=self.link_status_var, width=12)
        self.link_status_label.pack(side=tk.LEFT, padx=(6, 0))

        # center
        center = ttk.Frame(main)
        center.pack(fill=tk.BOTH, expand=True)

        left = ttk.LabelFrame(center, text="控制区", padding=10)
        left.pack(side=tk.LEFT, fill=tk.Y, padx=(0, 8))

        right = ttk.LabelFrame(center, text="日志", padding=10)
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        # OSD controls
        self.btn_osd = ttk.Button(left, text="OSD 打开", command=self._toggle_osd, width=18)
        self.btn_osd.pack(fill=tk.X, pady=(0, 8))

        nav_row = ttk.Frame(left)
        nav_row.pack(fill=tk.X, pady=(0, 8))

        self.btn_up = ttk.Button(nav_row, text="上", command=self._menu_up, width=8)
        self.btn_up.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_down = ttk.Button(nav_row, text="下", command=self._menu_down, width=8)
        self.btn_down.pack(side=tk.LEFT)

        action_row = ttk.Frame(left)
        action_row.pack(fill=tk.X, pady=(0, 8))

        ttk.Button(action_row, text="查询状态", command=lambda: self._send_cmd("STATUS?"), width=18).pack(fill=tk.X, pady=(0, 6))
        ttk.Button(action_row, text="复位", command=lambda: self._send_cmd("RESET"), width=18).pack(fill=tk.X)

        ttk.Label(left, text="菜单列表:").pack(anchor="w", pady=(8, 4))

        self.menu_listbox = tk.Listbox(left, height=len(self.MODES), exportselection=False)
        self.menu_listbox.pack(fill=tk.X)
        for item in self.MODES:
            self.menu_listbox.insert(tk.END, item)

        ttk.Label(left, text="当前生效模式:").pack(anchor="w", pady=(10, 4))
        self.active_mode_var = tk.StringVar(value="COLORBAR")
        ttk.Label(left, textvariable=self.active_mode_var).pack(anchor="w")

        # optional direct mode buttons
        direct_modes = ttk.LabelFrame(left, text="直接切模式", padding=8)
        direct_modes.pack(fill=tk.X, pady=(12, 0))

        for mode in self.MODES:
            ttk.Button(
                direct_modes,
                text=mode,
                command=lambda m=mode: self._send_cmd(f"MODE SET {m}")
            ).pack(fill=tk.X, pady=2)

        # log
        self.log_text = tk.Text(right, wrap=tk.WORD, state=tk.DISABLED)
        self.log_text.pack(fill=tk.BOTH, expand=True)

    # ------------------------------------------------------------------
    # Serial / threading bridge
    # ------------------------------------------------------------------
    def _post_rx_line(self, line: str) -> None:
        self.ui_queue.put(("rx", line))

    def _post_log(self, text: str) -> None:
        self.ui_queue.put(("log", text))

    def _drain_ui_queue(self) -> None:
        try:
            while True:
                kind, payload = self.ui_queue.get_nowait()
                if kind == "log":
                    self._append_log(payload)
                elif kind == "rx":
                    self._append_log(f"[RX] {payload}")
                    self._handle_rx_line(payload)
        except queue.Empty:
            pass

        self.root.after(50, self._drain_ui_queue)

    # ------------------------------------------------------------------
    # Port operations
    # ------------------------------------------------------------------
    def _refresh_ports(self) -> None:
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.port_combo["values"] = ports
        if ports and self.port_var.get() not in ports:
            self.port_var.set(ports[0])
        self._append_log("[INFO] 串口列表已刷新")

    def _toggle_connect(self) -> None:
        if not self.connected:
            port = self.port_var.get().strip()
            if not port:
                messagebox.showwarning("提示", "请先选择串口号")
                return
            try:
                self.serial_worker.open(port, 115200)
                self.connected = True
                self.btn_connect.config(text="关闭串口")
                self._append_log("[INFO] GUI 已连接串口")
                self._send_cmd("STATUS?")
            except Exception as e:
                messagebox.showerror("串口打开失败", str(e))
        else:
            self.serial_worker.close()
            self.connected = False
            self.link_up = False
            self.osd_on = False
            self.menu_index = 0
            self.active_mode = "COLORBAR"
            self.last_warn_link_down = False
            self.btn_connect.config(text="打开串口")
            self._update_widgets_from_state()

    def _send_cmd(self, cmd: str) -> None:
        if not self.connected:
            self._append_log("[WARN] 串口未连接")
            return
        self.serial_worker.send_line(cmd)

    # ------------------------------------------------------------------
    # GUI actions
    # ------------------------------------------------------------------
    def _toggle_osd(self) -> None:
        if not self.connected:
            return
        if self.osd_on:
            self._send_cmd("OSD OFF")
        else:
            self._send_cmd("OSD ON")

    def _menu_up(self) -> None:
        if not self.connected:
            return
        self._send_cmd("MENU UP")

    def _menu_down(self) -> None:
        if not self.connected:
            return
        self._send_cmd("MENU DOWN")

    # ------------------------------------------------------------------
    # RX line parsing
    # ------------------------------------------------------------------
    def _handle_rx_line(self, line: str) -> None:
        self.last_status_rx_time = time.time()

        if line.startswith("STAT "):
            self._parse_stat(line)
            return

        if line.startswith("WARN LINK DOWN"):
            self.link_up = False
            self.osd_on = False
            self.menu_index = 0
            self.active_mode = "COLORBAR"
            self._update_widgets_from_state()

            if not self.last_warn_link_down:
                self.last_warn_link_down = True
                messagebox.showwarning("SFP 告警", "检测到 SFP 链路断开")
            return

        if line.startswith("INFO LINK UP RESET"):
            self.last_warn_link_down = False
            self.link_up = True
            self.osd_on = False
            self.menu_index = 0
            self.active_mode = "COLORBAR"
            self._update_widgets_from_state()
            return

        if line.startswith("OK OSD ON"):
            self.osd_on = True
            self._update_widgets_from_state()
            return

        if line.startswith("OK OSD OFF"):
            self.osd_on = False
            self._update_widgets_from_state()
            return

        if line.startswith("OK MENU "):
            self._parse_ok_menu(line)
            return

        if line.startswith("OK MODE "):
            self._parse_ok_mode(line)
            return

        if line.startswith("OK RESET"):
            self.osd_on = False
            self.menu_index = 0
            self.active_mode = "COLORBAR"
            self._update_widgets_from_state()
            return

    def _parse_stat(self, line: str) -> None:
        # expected:
        # STAT LINK UP OSD ON MENU 2 MODE GRAY
        tokens = line.strip().split()
        try:
            # minimal validation
            # 0 STAT
            # 1 LINK
            # 2 UP/DOWN
            # 3 OSD
            # 4 ON/OFF
            # 5 MENU
            # 6 idx
            # 7 MODE
            # 8 name
            if len(tokens) < 9:
                return

            self.link_up = (tokens[2] == "UP")
            self.osd_on = (tokens[4] == "ON")
            self.menu_index = int(tokens[6])
            self.active_mode = tokens[8]

            if not self.link_up and not self.last_warn_link_down:
                self.last_warn_link_down = True
                messagebox.showwarning("SFP 告警", "检测到 SFP 链路断开")

            if self.link_up:
                self.last_warn_link_down = False

            self._update_widgets_from_state()
        except Exception as e:
            self._append_log(f"[WARN] STAT 解析失败: {e}")

    def _parse_ok_menu(self, line: str) -> None:
        # expected:
        # OK MENU 2 GRAY
        tokens = line.strip().split()
        try:
            if len(tokens) >= 4:
                self.menu_index = int(tokens[2])
                self.active_mode = tokens[3]
                self._update_widgets_from_state()
        except Exception as e:
            self._append_log(f"[WARN] OK MENU 解析失败: {e}")

    def _parse_ok_mode(self, line: str) -> None:
        # expected:
        # OK MODE 4 RED
        tokens = line.strip().split()
        try:
            if len(tokens) >= 4:
                self.menu_index = int(tokens[2])
                self.active_mode = tokens[3]
                self._update_widgets_from_state()
        except Exception as e:
            self._append_log(f"[WARN] OK MODE 解析失败: {e}")

    # ------------------------------------------------------------------
    # Periodic polling
    # ------------------------------------------------------------------
    def _periodic_status_poll(self) -> None:
        if self.connected:
            self._send_cmd("STATUS?")
        self.root.after(500, self._periodic_status_poll)

    # ------------------------------------------------------------------
    # UI update helpers
    # ------------------------------------------------------------------
    def _update_widgets_from_state(self) -> None:
        self.link_status_var.set("UP" if self.link_up else "DOWN")
        self.active_mode_var.set(self.active_mode)

        self.btn_osd.config(text="OSD 关闭" if self.osd_on else "OSD 打开")

        nav_enabled = self.connected and self.link_up and self.osd_on
        state = tk.NORMAL if nav_enabled else tk.DISABLED
        self.btn_up.config(state=state)
        self.btn_down.config(state=state)

        try:
            self.menu_listbox.selection_clear(0, tk.END)
            if 0 <= self.menu_index < len(self.MODES):
                self.menu_listbox.selection_set(self.menu_index)
                self.menu_listbox.see(self.menu_index)
        except Exception:
            pass

    def _append_log(self, text: str) -> None:
        self.log_text.config(state=tk.NORMAL)
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)
        self.log_text.config(state=tk.DISABLED)

    def _on_close(self) -> None:
        try:
            if self.connected:
                self.serial_worker.close()
        finally:
            self.root.destroy()


def main() -> None:
    root = tk.Tk()
    app = DemoGuiApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()