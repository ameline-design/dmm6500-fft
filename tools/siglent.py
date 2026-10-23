#!/usr/bin/env python3
"""Minimal SCPI driver for the Siglent SDG2122X arbitrary waveform generator.

Channel 1 output is wired to the DMM6500 front INPUT terminals, so this is used
to produce known test signals for validating the FFT app.

NOTE: this driver deliberately exposes only waveform/output control. It issues no
calibration commands of any kind.
"""
import socket
import time

SDG_IP = '10.0.1.79'
SDG_PORT = 5025


class SDG:
    def __init__(self, ip=SDG_IP, port=SDG_PORT, timeout=10):
        self.s = socket.socket()
        self.s.settimeout(timeout)
        self.s.connect((ip, port))

    def write(self, cmd):
        self.s.sendall((cmd + '\n').encode())
        time.sleep(0.12)

    def query(self, cmd, timeout=6):
        self.s.settimeout(timeout)
        self.s.sendall((cmd + '\n').encode())
        try:
            return self.s.recv(8192).decode(errors='replace').strip()
        except socket.timeout:
            return '<timeout>'

    def idn(self):
        return self.query('*IDN?')

    def sine(self, freq_hz, ampl_vpp, offset_v=0.0, ch=1, phase_deg=0.0):
        """Configure a channel for a sine wave. Amplitude is peak-to-peak volts."""
        self.write(f'C{ch}:BSWV WVTP,SINE,FRQ,{freq_hz},AMP,{ampl_vpp},'
                   f'OFST,{offset_v},PHSE,{phase_deg}')

    def square(self, freq_hz, ampl_vpp, offset_v=0.0, duty=50.0, ch=1):
        self.write(f'C{ch}:BSWV WVTP,SQUARE,FRQ,{freq_hz},AMP,{ampl_vpp},'
                   f'OFST,{offset_v},DUTY,{duty}')

    def output(self, on=True, ch=1, load='HZ'):
        """Enable/disable a channel output. load='HZ' (high-Z) suits the DMM's 10 MOhm input."""
        self.write(f'C{ch}:OUTP {"ON" if on else "OFF"},LOAD,{load}')

    def state(self, ch=1):
        return {'bswv': self.query(f'C{ch}:BSWV?'),
                'outp': self.query(f'C{ch}:OUTP?')}

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


if __name__ == '__main__':
    g = SDG()
    print('IDN :', g.idn())
    print('CH1 :', g.state(1))
    g.close()
