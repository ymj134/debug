import serial
import time

ser = serial.Serial('COM27', 115200, timeout=1)
time.sleep(0.2)

tx = bytes.fromhex('55 AA 00 FF 11 22 33 44')
ser.reset_input_buffer()
ser.write(tx)
time.sleep(0.2)
rx = ser.read(64)

print('TX:', tx.hex(' '))
print('RX:', rx.hex(' '))