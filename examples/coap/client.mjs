import { createSocket } from 'node:dgram';

// A bounded, single-request loopback demonstration client. Full CoAP peer
// interoperability is checked separately with aiocoap.
export async function sendMeasurement({ port, payload, source, key, format = 110, mid = 10, timeout = 2000 }) {
  const identifier = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !Buffer.isBuffer(payload) || payload.length > 8192 ||
      ![110, 112].includes(format) || !Number.isInteger(mid) || mid < 0 || mid > 65535 ||
      !Number.isInteger(timeout) || timeout < 1 || timeout > 10000 ||
      ((source !== undefined || key !== undefined) && (!identifier(source) || !identifier(key)))) throw new Error('Invalid request');
  let previous = 0;
  function option(number, value) {
    const delta = number - previous;
    previous = number;
    const length = value.length;
    const head = length < 13 ? Buffer.from([delta << 4 | length]) : Buffer.from([delta << 4 | 13, length - 13]);
    return Buffer.concat([head, value]);
  }
  const options = [option(11, Buffer.from('ingest')), option(12, Buffer.from([format]))];
  if (source !== undefined) options.push(option(15, Buffer.from(`source=${source}`)), option(15, Buffer.from(`key=${key}`)));
  const wire = Buffer.concat([Buffer.from([0x41, 2, mid >> 8, mid & 255, 1]), ...options,
    ...(payload.length ? [Buffer.from([255]), payload] : [])]);
  const socket = createSocket('udp4');
  let timer;
  let emptyAck = false;
  try {
    return await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('CoAP response timeout')), timeout);
      socket.on('error', reject);
      socket.on('message', (message, remote) => {
        if (remote.address !== '127.0.0.1' || remote.port !== port || message.length < 4 || message[0] >> 6 !== 1) return;
        const type = message[0] >> 4 & 3, code = message[1], responseMid = message.readUInt16BE(2);
        if (code === 0 && type === 2 && responseMid === mid && message.length === 4) { emptyAck = true; return; }
        if (code === 0 && type === 3 && responseMid === mid) { reject(new Error('CoAP reset')); return; }
        if (code === 0 || ![0, 1, 2].includes(type) || (type === 2 && responseMid !== mid) ||
            (message[0] & 15) !== 1 || message.length < 5 || message[4] !== 1) return;
        const result = { code, emptyAck, responseHex: message.toString('hex') };
        if (type === 0) socket.send(Buffer.from([0x60, 0, message[2], message[3]]), port, '127.0.0.1', error => { if (error) reject(error); else resolve(result); });
        else resolve(result);
      });
      socket.bind(0, '127.0.0.1', () => socket.send(wire, port, '127.0.0.1', error => { if (error) reject(error); }));
    });
  } finally {
    clearTimeout(timer);
    try { socket.close(); } catch { /* Binding may have failed. */ }
  }
}
