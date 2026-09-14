<?php
/*
 * auto_prepend_file hook that runs before every PHP request.
 *
 *   1. Echoes the configured request-id header (default X-REQUEST-ID) back
 *      on the response so that TraceLib — which scans write/writev syscalls
 *      for that header — can demultiplex coverage per request.
 *   2. Starts PCOV coverage collection. On shutdown it appends a single
 *      JSONL record to /coverage/coverage.jsonl summarising which PHP files
 *      and which *lines* were executed during the request, plus each file's
 *      total executable-line count so the aggregator can compute percentages.
 *
 * The header name is taken from $_ENV['TRACELIB_HEADER'] or the
 * TRACELIB_HEADER ini_set equivalent; defaults to X-REQUEST-ID.
 *
 * Skip CLI: auto_prepend_file fires for every PHP invocation, including
 * setup scripts (wp-cli `core install`, hotcrp's `batch/createdb.php`,
 * etc.). Those CLI runs load the entire app bootstrap and emit huge
 * coverage records with `req=_anon`. Once that baseline lands in
 * coverage.jsonl, per-request HTTP coverage barely moves the union and
 * the live fuzz traffic looks "stuck" at whatever percentage the setup
 * scripts happened to cover.
 */
if (PHP_SAPI === 'cli') {
    return;
}

$tl_header = getenv('TRACELIB_HEADER');
if (!is_string($tl_header) || $tl_header === '') {
    $tl_header = 'X-REQUEST-ID';
}
/* PHP exposes request headers as HTTP_<UPPER_UNDERSCORED_NAME>. */
$tl_server_key = 'HTTP_' . strtoupper(str_replace('-', '_', $tl_header));

/* webFuzz uses different headers by feedback mode:
 *   tracelib  -> X-REQUEST-ID (per-request unique uuid hex)
 *   native    -> REQ-ID       (= worker self.id, CONSTANT across the
 *                              whole campaign with -w 1)
 *   blackbox  -> REQ-ID       (same constant)
 * We only read X-REQUEST-ID-style headers here. HTTP_REQ_ID is NEVER
 * consulted: it would collapse every per-request PCOV record onto a
 * single key and ruin downstream per-request joins (RQ2 analysis).
 * If no X-REQUEST-ID is supplied, we synthesize one further down. */
$tl_candidate_keys = [$tl_server_key];
if (!in_array('HTTP_X_REQUEST_ID', $tl_candidate_keys, true)) {
    $tl_candidate_keys[] = 'HTTP_X_REQUEST_ID';
}

$tl_clean = null;
foreach ($tl_candidate_keys as $tl_try_key) {
    if (!empty($_SERVER[$tl_try_key])) {
        $raw = (string)$_SERVER[$tl_try_key];
        $candidate = preg_replace('/[^A-Za-z0-9_-]/', '', substr($raw, 0, 127));
        if ($candidate !== '' && $candidate !== null) {
            $tl_clean = $candidate;
            if (!headers_sent()) {
                header($tl_header . ': ' . $tl_clean);
            }
            break;
        }
    }
}

/* If neither header carried a usable id, synthesize one for this
 * request and inject it into $_SERVER['HTTP_X_REQUEST_ID']. This
 * matters in native mode: webFuzz only sends REQ-ID (= worker self.id,
 * constant for the entire campaign with -w 1), and the AST
 * instrumentor's stub keys its per-request map file on
 * $_SERVER['HTTP_REQ_ID'] — so without a synthesized id every request
 * would write to the same map.<worker_id> file and overwrite previous
 * data. Injecting HTTP_X_REQUEST_ID early gives both this hook and
 * EdgeVisitor a shared, unique per-request id; downstream RQ2 analysis
 * can then join them by id. We do NOT overwrite an id that webFuzz
 * already supplied (tracelib mode is unaffected). */
if ($tl_clean === null) {
    try {
        $synth = 'synth-' . bin2hex(random_bytes(8));
    } catch (\Throwable $e) {
        $synth = 'synth-' . dechex(mt_rand(0, PHP_INT_MAX)) . dechex(mt_rand(0, PHP_INT_MAX));
    }
    $tl_clean = $synth;
    $_SERVER['HTTP_X_REQUEST_ID'] = $synth;
    if (!headers_sent()) {
        header($tl_header . ': ' . $tl_clean);
    }
}

if (function_exists('\\pcov\\start')) {
    \pcov\start();

    $tl_shutdown_id = $tl_clean ?: '_anon';
    /* Capture request metadata up-front so the shutdown handler can use
     * it without touching $_SERVER. Some apps (phpBB) install runtime
     * hardening that turns later $_SERVER reads into fatal errors. */
    $tl_request_uri    = $_SERVER['REQUEST_URI'] ?? '';
    $tl_request_method = $_SERVER['REQUEST_METHOD'] ?? '';
    register_shutdown_function(function () use ($tl_shutdown_id, $tl_request_uri, $tl_request_method) {
        try {
            if (!function_exists('\\pcov\\collect')) {
                return;
            }
            /* \pcov\collect() returns: file => (line_number => value).
             * In PCOV >= 1.0, value is 1 (executed) or -1 (executable but
             * not hit). Older builds only return hit lines. Handle both. */
            $coverage = \pcov\collect();
            /* When PCOV is loaded but disabled (pcov.enabled=0 — the case
             * in the AST-edge campaign, eval/assets/nopcov.ini), collect()
             * returns null/empty. Nothing to record; bail before the
             * foreach to avoid a "foreach() argument must be of type
             * array" warning on every request. */
            if (!is_array($coverage)) {
                return;
            }

            /* Document root may vary by app; strip whatever we can so the
             * keys stay readable. These are just prefix strips — harmless
             * if they don't match. */
            $strip_prefixes = ['/var/www/html/', '/app/', '/srv/'];

            $compact = [];
            foreach ($coverage as $file => $lines) {
                if (!is_array($lines)) {
                    continue;
                }
                $hit = [];
                $exec = 0;
                foreach ($lines as $ln => $v) {
                    $exec++;
                    if ((int)$v > 0) {
                        $hit[] = (int)$ln;
                    }
                }
                $rel = $file;
                foreach ($strip_prefixes as $p) {
                    if (strpos($rel, $p) === 0) {
                        $rel = substr($rel, strlen($p));
                        break;
                    }
                }
                $compact[$rel] = ['h' => $hit, 'e' => $exec];
            }

            $record = [
                'ts'      => microtime(true),
                /* The PHP-FPM/Apache worker handling this request.
                 * PCOV accumulates hit data within a worker, so the
                 * `covered` field below is cumulative-since-worker-boot.
                 * Per-request line sets must be recovered downstream by
                 * differencing consecutive records that share the same
                 * pid (see eval/rq2_analyze.py). */
                'pid'     => function_exists('posix_getpid') ? posix_getpid() : getmypid(),
                'req'     => $tl_shutdown_id,
                'url'     => $tl_request_uri,
                'method'  => $tl_request_method,
                'status'  => function_exists('http_response_code')
                              ? http_response_code()
                              : null,
                'covered' => $compact,
            ];

            $dir = '/coverage';
            if (!is_dir($dir)) {
                @mkdir($dir, 0777, true);
            }
            $line = json_encode($record) . "\n";
            $fp = @fopen($dir . '/coverage.jsonl', 'a');
            if ($fp) {
                @flock($fp, LOCK_EX);
                @fwrite($fp, $line);
                @flock($fp, LOCK_UN);
                @fclose($fp);
            }
        } catch (\Throwable $e) {
            /* Best-effort — never let coverage crashes propagate. */
        }
    });
}
