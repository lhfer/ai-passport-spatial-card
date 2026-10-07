/** Tiny prefixed console logger (timestamps, levels) shared by all hub modules. */

export interface Logger {
  debug(msg: string, ...args: unknown[]): void;
  info(msg: string, ...args: unknown[]): void;
  warn(msg: string, ...args: unknown[]): void;
  error(msg: string, ...args: unknown[]): void;
  child(prefix: string): Logger;
}

function stamp(): string {
  return new Date().toISOString().slice(11, 19);
}

export function createLogger(prefix: string, sink: Pick<Console, 'log' | 'warn' | 'error'> = console, verbose = process.env['HUB_DEBUG'] === '1'): Logger {
  const tag = prefix ? `[${prefix}]` : '';
  return {
    debug: (msg, ...args) => {
      if (verbose) sink.log(`${stamp()} ${tag} ${msg}`, ...args);
    },
    info: (msg, ...args) => sink.log(`${stamp()} ${tag} ${msg}`, ...args),
    warn: (msg, ...args) => sink.warn(`${stamp()} ${tag} ${msg}`, ...args),
    error: (msg, ...args) => sink.error(`${stamp()} ${tag} ${msg}`, ...args),
    child: (p) => createLogger(prefix ? `${prefix}:${p}` : p, sink, verbose),
  };
}

export const silentLogger: Logger = {
  debug: () => {},
  info: () => {},
  warn: () => {},
  error: () => {},
  child: () => silentLogger,
};
