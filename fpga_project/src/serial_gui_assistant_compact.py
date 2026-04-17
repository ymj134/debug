import queue
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk
from tkinter.scrolledtext import ScrolledText

try:
    import serial
    import serial.tools.list_ports
except ImportError as exc:
    raise SystemExit("Missing dependency: pyserial\nInstall it with: pip install pyserial") from exc


PARITY_MAP = {
    "N": serial.PARITY_NONE,
    "E": serial.PARITY_EVEN,
    "O": serial.PARITY_ODD,
    "M": serial.PARITY_MARK,
    "S": serial.PARITY_SPACE,
}

BYTESIZE_MAP = {
    "5": serial.FIVEBITS,
    "6": serial.SIXBITS,
    "7": serial.SEVENBITS,
    "8": serial.EIGHTBITS,
}

STOPBITS_MAP = {
    "1": serial.STOPBITS_ONE,
    "1.5": serial.STOPBITS_ONE_POINT_FIVE,
    "2": serial.STOPBITS_TWO,
}

LINE_ENDINGS = {
    "None": b"",
    "CR": b"\r",
    "LF": b"\n",
    "CRLF": b"\r\n",
}

QUICK_CMDS = ["0", "1", "T", "A", "B", "C", "D", "E", "F", "S"]


class SerialAssistantCompact:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Serial Assistant Compact")
        self.root.geometry("920x600")
        self.root.minsize(860, 520)

        self.ser = None
        self.running = False
        self.reader_thread = None
        self.rx_queue: queue.Queue[tuple[str, object, float]] = queue.Queue()

        self.rx_count = 0
        self.tx_count = 0

        self.port_var = tk.StringVar()
        self.baud_var = tk.StringVar(value="115200")
        self.bytesize_var = tk.StringVar(value="8")
        self.parity_var = tk.StringVar(value="N")
        self.stopbits_var = tk.StringVar(value="1")
        self.encoding_var = tk.StringVar(value="ascii")
        self.line_ending_var = tk.StringVar(value="None")

        self.show_hex_var = tk.BooleanVar(value=True)
        self.hex_send_var = tk.BooleanVar(value=False)
        self.timestamp_var = tk.BooleanVar(value=True)
        self.autoscroll_var = tk.BooleanVar(value=True)
        self.uppercase_var = tk.BooleanVar(value=False)
        self.dtr_var = tk.BooleanVar(value=False)
        self.rts_var = tk.BooleanVar(value=False)

        self._build_ui()
        self.refresh_ports()
        self.root.after(40, self.process_queue)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def _build_ui(self) -> None:
        top = ttk.Frame(self.root, padding=6)
        top.pack(fill="x")

        ttk.Label(top, text="Port").grid(row=0, column=0, sticky="w")
        self.port_combo = ttk.Combobox(top, textvariable=self.port_var, width=14, state="readonly")
        self.port_combo.grid(row=0, column=1, padx=(4, 8), sticky="w")
        ttk.Button(top, text="Refresh", width=8, command=self.refresh_ports).grid(row=0, column=2, padx=(0, 10))

        ttk.Label(top, text="Baud").grid(row=0, column=3, sticky="w")
        ttk.Combobox(top, textvariable=self.baud_var, width=10,
                     values=["9600", "19200", "38400", "57600", "115200", "230400", "460800", "921600"]).grid(row=0, column=4, padx=(4, 10), sticky="w")

        ttk.Label(top, text="Data").grid(row=0, column=5, sticky="w")
        ttk.Combobox(top, textvariable=self.bytesize_var, width=4, values=["5", "6", "7", "8"], state="readonly").grid(row=0, column=6, padx=(4, 8), sticky="w")

        ttk.Label(top, text="Parity").grid(row=0, column=7, sticky="w")
        ttk.Combobox(top, textvariable=self.parity_var, width=4, values=["N", "E", "O", "M", "S"], state="readonly").grid(row=0, column=8, padx=(4, 8), sticky="w")

        ttk.Label(top, text="Stop").grid(row=0, column=9, sticky="w")
        ttk.Combobox(top, textvariable=self.stopbits_var, width=4, values=["1", "1.5", "2"], state="readonly").grid(row=0, column=10, padx=(4, 10), sticky="w")

        self.open_btn = ttk.Button(top, text="Open", width=8, command=self.toggle_port)
        self.open_btn.grid(row=0, column=11, padx=(2, 0), sticky="e")

        ttk.Label(top, text="Encoding").grid(row=1, column=0, pady=(6, 0), sticky="w")
        ttk.Combobox(top, textvariable=self.encoding_var, width=10,
                     values=["ascii", "utf-8", "gbk", "latin-1"], state="readonly").grid(row=1, column=1, padx=(4, 8), pady=(6, 0), sticky="w")

        ttk.Label(top, text="LineEnd").grid(row=1, column=3, pady=(6, 0), sticky="w")
        ttk.Combobox(top, textvariable=self.line_ending_var, width=7,
                     values=list(LINE_ENDINGS.keys()), state="readonly").grid(row=1, column=4, padx=(4, 8), pady=(6, 0), sticky="w")

        ttk.Checkbutton(top, text="HEX RX", variable=self.show_hex_var).grid(row=1, column=5, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="HEX TX", variable=self.hex_send_var).grid(row=1, column=6, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="Timestamp", variable=self.timestamp_var).grid(row=1, column=7, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="AutoScroll", variable=self.autoscroll_var).grid(row=1, column=8, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="UPPER", variable=self.uppercase_var).grid(row=1, column=9, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="DTR=1", variable=self.dtr_var).grid(row=1, column=10, pady=(6, 0), sticky="w")
        ttk.Checkbutton(top, text="RTS=1", variable=self.rts_var).grid(row=1, column=11, pady=(6, 0), sticky="w")

        middle = ttk.Frame(self.root, padding=(6, 0, 6, 0))
        middle.pack(fill="both", expand=True)

        log_box = ttk.LabelFrame(middle, text="Log")
        log_box.pack(fill="both", expand=True)

        toolbar = ttk.Frame(log_box)
        toolbar.pack(fill="x", padx=6, pady=4)
        ttk.Button(toolbar, text="Clear Log", command=self.clear_log).pack(side="left")
        ttk.Button(toolbar, text="Send Input", command=self.send_data).pack(side="left", padx=(8, 0))
        self.status_label = ttk.Label(toolbar, text="RX: 0 bytes    TX: 0 bytes")
        self.status_label.pack(side="right")

        self.log_text = ScrolledText(log_box, wrap="word", height=18)
        self.log_text.pack(fill="both", expand=True, padx=6, pady=(0, 6))
        self.log_text.tag_config("rx", foreground="#0044cc")
        self.log_text.tag_config("tx", foreground="#008000")
        self.log_text.tag_config("sys", foreground="#666666")
        self.log_text.tag_config("err", foreground="#cc0000")

        bottom = ttk.Frame(self.root, padding=6)
        bottom.pack(fill="x")

        quick_box = ttk.LabelFrame(bottom, text="Quick FPGA Commands")
        quick_box.pack(fill="x", pady=(0, 6))

        for idx, cmd in enumerate(QUICK_CMDS):
            ttk.Button(
                quick_box,
                text=cmd,
                width=4,
                command=lambda c=cmd: self.send_quick_text(c),
            ).grid(row=0, column=idx, padx=3, pady=6)

        note = ttk.Label(
            quick_box,
            text="建议先用这些按钮发大写命令，避免小写/回车影响 FPGA 识别。",
        )
        note.grid(row=0, column=len(QUICK_CMDS), padx=(12, 0), sticky="w")

        send_box = ttk.LabelFrame(bottom, text="Manual Send")
        send_box.pack(fill="x")

        entry_row = ttk.Frame(send_box)
        entry_row.pack(fill="x", padx=6, pady=6)

        self.input_var = tk.StringVar()
        self.input_entry = ttk.Entry(entry_row, textvariable=self.input_var)
        self.input_entry.pack(side="left", fill="x", expand=True)
        self.input_entry.bind("<Return>", lambda _e: self.send_data())

        ttk.Button(entry_row, text="Send", width=8, command=self.send_data).pack(side="left", padx=(8, 0))
        ttk.Button(entry_row, text="Clear", width=8, command=lambda: self.input_var.set("")).pack(side="left", padx=(6, 0))

        hint = ttk.Label(
            send_box,
            text="Text 模式直接按编码发；HEX 模式示例：53 或 41 42 43。默认 LineEnd= None。",
        )
        hint.pack(anchor="w", padx=6, pady=(0, 6))

    def refresh_ports(self) -> None:
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.port_combo["values"] = ports
        if ports and (not self.port_var.get() or self.port_var.get() not in ports):
            self.port_var.set(ports[0])
        elif not ports:
            self.port_var.set("")

    def toggle_port(self) -> None:
        if self.ser and self.ser.is_open:
            self.close_port()
        else:
            self.open_port()

    def open_port(self) -> None:
        port = self.port_var.get().strip()
        if not port:
            messagebox.showwarning("Warning", "Please select a serial port.")
            return

        try:
            ser = serial.Serial(
                port=port,
                baudrate=int(self.baud_var.get()),
                bytesize=BYTESIZE_MAP[self.bytesize_var.get()],
                parity=PARITY_MAP[self.parity_var.get()],
                stopbits=STOPBITS_MAP[self.stopbits_var.get()],
                timeout=0.05,
                xonxoff=False,
                rtscts=False,
                dsrdtr=False,
            )
            try:
                ser.dtr = self.dtr_var.get()
            except Exception:
                pass
            try:
                ser.rts = self.rts_var.get()
            except Exception:
                pass
        except Exception as exc:
            messagebox.showerror("Open failed", str(exc))
            return

        self.ser = ser
        self.running = True
        self.reader_thread = threading.Thread(target=self.read_loop, daemon=True)
        self.reader_thread.start()
        self.open_btn.config(text="Close")
        self.write_log(f"[SYS] Opened {port}\n", "sys")

    def close_port(self) -> None:
        self.running = False
        if self.ser is not None:
            try:
                if self.ser.is_open:
                    self.ser.close()
            except Exception:
                pass
        self.ser = None
        self.open_btn.config(text="Open")
        self.write_log("[SYS] Port closed\n", "sys")

    def read_loop(self) -> None:
        while self.running and self.ser and self.ser.is_open:
            try:
                waiting = self.ser.in_waiting
                data = self.ser.read(waiting or 1)
                if data:
                    self.rx_queue.put(("rx", data, time.time()))
            except Exception as exc:
                self.rx_queue.put(("err", str(exc), time.time()))
                break
        self.running = False

    def process_queue(self) -> None:
        while not self.rx_queue.empty():
            kind, payload, ts = self.rx_queue.get_nowait()
            if kind == "rx":
                data = bytes(payload)
                self.rx_count += len(data)
                self.write_packet("RX", data, "rx", ts)
            elif kind == "err":
                self.write_log(f"[ERR] {payload}\n", "err")
                self.open_btn.config(text="Open")
        self.update_status()
        self.root.after(40, self.process_queue)

    def _time_prefix(self, ts: float) -> str:
        if not self.timestamp_var.get():
            return ""
        return time.strftime("[%H:%M:%S] ", time.localtime(ts))

    def update_status(self) -> None:
        self.status_label.config(text=f"RX: {self.rx_count} bytes    TX: {self.tx_count} bytes")

    def format_bytes(self, data: bytes) -> str:
        encoding = self.encoding_var.get()
        try:
            text = data.decode(encoding, errors="backslashreplace")
        except Exception:
            text = data.decode("latin-1", errors="backslashreplace")

        if self.show_hex_var.get():
            return f"{' '.join(f'{b:02X}' for b in data)}    |    {text}"
        return text

    def write_packet(self, direction: str, data: bytes, tag: str, ts: float | None = None) -> None:
        if ts is None:
            ts = time.time()
        line = f"{self._time_prefix(ts)}{direction}: {self.format_bytes(data)}"
        if not line.endswith("\n"):
            line += "\n"
        self.write_log(line, tag)

    def write_log(self, text: str, tag: str) -> None:
        self.log_text.insert("end", text, tag)
        if self.autoscroll_var.get():
            self.log_text.see("end")

    def clear_log(self) -> None:
        self.log_text.delete("1.0", "end")
        self.rx_count = 0
        self.tx_count = 0
        self.update_status()

    def build_payload(self, raw: str) -> bytes:
        if self.uppercase_var.get() and not self.hex_send_var.get():
            raw = raw.upper()

        if self.hex_send_var.get():
            try:
                payload = bytes.fromhex(raw.strip()) if raw.strip() else b""
            except ValueError as exc:
                raise ValueError("HEX 格式错误，示例：53 或 41 42 43") from exc
        else:
            payload = raw.encode(self.encoding_var.get(), errors="replace")

        payload += LINE_ENDINGS[self.line_ending_var.get()]
        return payload

    def send_quick_text(self, text: str) -> None:
        if not self.ser or not self.ser.is_open:
            messagebox.showwarning("Warning", "Serial port is not open.")
            return
        try:
            payload = text.encode("ascii")
            written = self.ser.write(payload)
            self.ser.flush()
        except Exception as exc:
            messagebox.showerror("Send failed", str(exc))
            return
        self.tx_count += written
        self.update_status()
        self.write_packet("TX", payload, "tx", time.time())

    def send_data(self) -> None:
        if not self.ser or not self.ser.is_open:
            messagebox.showwarning("Warning", "Serial port is not open.")
            return

        raw = self.input_var.get()
        try:
            payload = self.build_payload(raw)
        except Exception as exc:
            messagebox.showerror("Send failed", str(exc))
            return

        if not payload:
            return

        try:
            written = self.ser.write(payload)
            self.ser.flush()
        except Exception as exc:
            messagebox.showerror("Send failed", str(exc))
            return

        self.tx_count += written
        self.update_status()
        self.write_packet("TX", payload, "tx", time.time())

    def on_close(self) -> None:
        self.close_port()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    style = ttk.Style()
    try:
        style.theme_use("clam")
    except Exception:
        pass
    SerialAssistantCompact(root)
    root.mainloop()


if __name__ == "__main__":
    main()
