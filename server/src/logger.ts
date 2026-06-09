import pino from 'pino';

import type { Config } from './config.js';

export type Logger = pino.Logger;

export function createLogger(config: Config): Logger {
  return pino({
    level: config.logLevel,
    // Clipboard payloads (`ct`/`nonce`) are never passed to the logger by design;
    // this redaction is belt-and-suspenders in case a message object ever leaks in.
    redact: {
      paths: ['ct', 'nonce', '*.ct', '*.nonce'],
      censor: '[redacted]',
    },
    transport: config.isProd
      ? undefined
      : {
          target: 'pino-pretty',
          options: { colorize: true, translateTime: 'SYS:HH:MM:ss', ignore: 'pid,hostname' },
        },
  });
}
