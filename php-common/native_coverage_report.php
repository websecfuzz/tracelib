<?php
/*
 * native_coverage_report.php — AST-edge coverage collector.
 *
 * Mode-INDEPENDENT coverage oracle for PHP targets in the
 * run_campaign_all.sh experiment. Unlike coverage_report.php (which
 * summarises PCOV *lines*), this unions webFuzz's AST *edge* labels
 * across every per-request map file the instrumentor wrote to
 * /var/instr, and divides by the total edge count from instr.meta.
 *
 * The result is the same quantity webFuzz's native feedback mode
 * reports as "Total Coverage Score" — but recovered passively from the
 * map files, so it is identical across the tracelib / native / blackbox
 * feedback modes (every mode runs the AST-instrumented image; only the
 * fuzzing-feedback path differs). That is what makes the cross-mode
 * coverage comparison apple-to-apple.
 *
 * Per-request map files persist because php-common/pcov_hook.php
 * synthesizes a unique X-REQUEST-ID per request in every mode, and the
 * patched EdgeVisitor writes map.<id> keyed on it (see
 * webfuzz-patches/EdgeVisitor.php). Unioning all map.* files therefore
 * yields cumulative edge coverage.
 *
 * Invoked inside the container by run_campaign_all.sh:
 *   docker compose exec -T -e TRACELIB_INSTR_META=<path> <svc> \
 *       php /tracelib-support/native_coverage_report.php
 *
 * Output line (parsed host-side by the same shape as the PCOV/go/python
 * reports):
 *   native_coverage_report: <N> map file(s), <hit> / <total> edges covered (<pct>%)
 */

$meta = getenv('TRACELIB_INSTR_META');
if (!is_string($meta) || $meta === '') {
    $meta = '/var/www/html/instr.meta';
}
$instr_dir = getenv('TRACELIB_INSTR_DIR_C');
if (!is_string($instr_dir) || $instr_dir === '') {
    $instr_dir = '/var/instr';
}

/* Denominator: total instrumentable edges. webFuzz uses edge-count for
 * Policy.EDGE; fall back to basic-block-count. */
$edge_count = 0;
if (is_file($meta)) {
    $m = json_decode((string)@file_get_contents($meta), true);
    if (is_array($m)) {
        if (isset($m['edge-count'])) {
            $edge_count = (int)$m['edge-count'];
        } elseif (isset($m['basic-block-count'])) {
            $edge_count = (int)$m['basic-block-count'];
        }
    }
}

/* Union of edge labels across every per-request map file. */
$edges  = [];
$nfiles = 0;
$files  = glob($instr_dir . '/map.*');
if ($files !== false) {
    foreach ($files as $f) {
        $fp = @fopen($f, 'r');
        if (!$fp) {
            continue;
        }
        $nfiles++;
        while (($line = fgets($fp)) !== false) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            /* Each line is "<edge_key>-<hit_count>"; the key is the part
             * before the LAST dash (hit_count never contains one). */
            $dash = strrpos($line, '-');
            $key  = ($dash === false) ? $line : substr($line, 0, $dash);
            if ($key !== '') {
                $edges[$key] = true;
            }
        }
        fclose($fp);
    }
}

$hit = count($edges);
$pct = $edge_count > 0 ? (100.0 * $hit / $edge_count) : 0.0;

printf(
    "native_coverage_report: %d map file(s), %d / %d edges covered (%.4f%%)\n",
    $nfiles, $hit, $edge_count, $pct
);
