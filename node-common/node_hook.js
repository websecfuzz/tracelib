/*
 * node_hook.js — Node.js preload module loaded via NODE_OPTIONS=--require.
 *
 *   1. Echoes the configured request-id header (default X-REQUEST-ID) on
 *      every HTTP response so TraceLib — which scans write/writev syscalls
 *      for that header — can demultiplex coverage per request.
 *   2. Calls v8.takeCoverage() on SIGUSR2 and, when configured, periodically,
 *      so c8 can report coverage without stopping the application.
 *
 * Both behaviours are safe no-ops if the underlying API is unavailable
 * (old Node, non-HTTP server, etc.) so this module can be preloaded
 * unconditionally.
 *
 * Environment variables:
 *   TRACELIB_HEADER          header name to echo (default X-REQUEST-ID)
 *   TRACELIB_COVERAGE_INTERVAL_MS  flush cadence in ms (default 5000; 0 disables)
 */

'use strict';

const http = require('node:http');
const https = require('node:https');

const HEADER_NAME = process.env.TRACELIB_HEADER || 'X-REQUEST-ID';
const HEADER_KEY_LC = HEADER_NAME.toLowerCase();
const SAFE_CHARS = /[^A-Za-z0-9_-]/g;
const TAKE_COVERAGE_ON_RESPONSE = process.env.TRACELIB_COVERAGE_TAKE_ON_RESPONSE === '1';
let takeCoverage = null;

try {
    const v8 = require('node:v8');
    if (typeof v8.takeCoverage === 'function') {
        takeCoverage = () => { try { v8.takeCoverage(); } catch (_) { /* ignore */ } };
    }
} catch (_) {
    /* node too old or v8 module missing — coverage still dumps on exit */
}

function installResponseHook(ServerResponse) {
    const origWriteHead = ServerResponse.prototype.writeHead;

    ServerResponse.prototype.writeHead = function patchedWriteHead(...args) {
        try {
            const req = this.req;
            if (req && req.headers) {
                const raw = req.headers[HEADER_KEY_LC];
                if (raw) {
                    const cleaned = String(raw).replace(SAFE_CHARS, '').slice(0, 127);
                    if (cleaned) {
                        /* setHeader before writeHead is the safe order —
                         * node merges pre-existing headers into the head
                         * output. headersSent is our bail-out guard. */
                        if (!this.headersSent) {
                            this.setHeader(HEADER_NAME, cleaned);
                        }
                    }
                }
            }
        } catch (_) {
            /* never let the hook break the response */
        }
        if (TAKE_COVERAGE_ON_RESPONSE && takeCoverage) {
            try {
                this.once('finish', takeCoverage);
            } catch (_) {
                /* never let the hook break the response */
            }
        }
        return origWriteHead.apply(this, args);
    };
}

installResponseHook(http.ServerResponse);
if (https && https.ServerResponse) {
    installResponseHook(https.ServerResponse);
}

/* SIGUSR2 always flushes coverage. Periodic snapshots are optional because a
 * long final-only campaign can otherwise create thousands of multi-megabyte
 * V8 files that c8 cannot merge within a practical memory budget. */
try {
    if (takeCoverage) {
        process.on('SIGUSR2', takeCoverage);
        const rawInterval = process.env.TRACELIB_COVERAGE_INTERVAL_MS;
        const intervalMs = rawInterval === undefined ? 5000 : Number(rawInterval);
        if (Number.isFinite(intervalMs) && intervalMs > 0) {
            const t = setInterval(() => {
                takeCoverage();
            }, intervalMs);
            if (typeof t.unref === 'function') {
                t.unref();
            }
        }
    }
} catch (_) {
    /* node too old or v8 module missing — coverage still dumps on exit */
}
