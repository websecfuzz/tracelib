<?php
/*
 * native_coverage_compact.php — INCREMENTAL, compacting AST-edge coverage
 * oracle for the request-budget schema.
 *
 * Identical semantics to php-common/native_coverage_report.php (union of
 * webFuzz AST edge labels across every per-request map.* file, divided by
 * instr.meta's edge count), but it runs on the HOST against the bind-mounted
 * instr directory and is INCREMENTAL: it folds each map file into a
 * persistent cumulative edge set and then normally DELETES the consumed file,
 * so the directory never accumulates the hundreds of thousands of tiny files an
 * unlimited crawl would otherwise leave — keeping every sample O(new files)
 * instead of O(all files). Set TRACELIB_INSTR_DELETE_MAPS=0 to retain map files
 * and track consumed filenames in .processed.maps; this is used when per-request
 * feedback export needs the individual maps after campaign sampling.
 *
 * Safety: map files modified within MTIME_SKIP_SECONDS are left untouched so
 * an in-flight request's partially-written map is never consumed. The
 * cumulative set is written atomically (temp + rename). A single sampler runs
 * at a time (the campaign's stats loop is sequential), so there is no
 * concurrent writer to the cumulative file.
 *
 * Env:
 *   TRACELIB_INSTR_META   path to instr.meta (for the edge denominator)
 *   TRACELIB_INSTR_DIR    directory holding the map.* files (host side)
 *   TRACELIB_INSTR_DELETE_MAPS  1 deletes consumed maps, 0 retains them
 *
 * Output (parsed by the campaign with the same regex as the v1 oracle):
 *   native_coverage_compact: consumed=<c> remaining=<r> <hit> / <total> edges covered (<pct>%)
 */

const MTIME_SKIP_SECONDS = 3;

$meta = getenv('TRACELIB_INSTR_META');
if (!is_string($meta) || $meta === '') {
    $meta = '/var/www/html/instr.meta';
}
$instr_dir = getenv('TRACELIB_INSTR_DIR');
if (!is_string($instr_dir) || $instr_dir === '') {
    $instr_dir = '/var/instr';
}
$cumfile = rtrim($instr_dir, '/') . '/.cumulative.edges';
$delete_maps = getenv('TRACELIB_INSTR_DELETE_MAPS');
$delete_maps = !is_string($delete_maps) || $delete_maps === '' || $delete_maps !== '0';
$processed_file = rtrim($instr_dir, '/') . '/.processed.maps';

/* Denominator: total instrumentable edges. */
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

/* Load the persistent cumulative edge set. */
$edges = [];
if (is_file($cumfile)) {
    $fp = @fopen($cumfile, 'r');
    if ($fp) {
        while (($line = fgets($fp)) !== false) {
            $line = rtrim($line, "\r\n");
            if ($line !== '') {
                $edges[$line] = true;
            }
        }
        fclose($fp);
    }
}

/* In retain mode, remember settled map files that were already folded in. */
$processed = [];
if (!$delete_maps && is_file($processed_file)) {
    $fp = @fopen($processed_file, 'r');
    if ($fp) {
        while (($line = fgets($fp)) !== false) {
            $line = rtrim($line, "\r\n");
            if ($line !== '') {
                $processed[$line] = true;
            }
        }
        fclose($fp);
    }
}

/* Fold in every settled map file, optionally deleting it afterward. */
$now       = time();
$consumed  = 0;
$remaining = 0;
$files = glob($instr_dir . '/map.*');
if ($files !== false) {
    foreach ($files as $f) {
        $base = basename($f);
        if (!$delete_maps && isset($processed[$base])) {
            continue;
        }
        $mt = @filemtime($f);
        if ($mt !== false && ($now - $mt) < MTIME_SKIP_SECONDS) {
            $remaining++;            // in-flight; leave for the next round
            continue;
        }
        $fp = @fopen($f, 'r');
        if (!$fp) {
            $remaining++;
            continue;
        }
        while (($line = fgets($fp)) !== false) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $dash = strrpos($line, '-');
            $key  = ($dash === false) ? $line : substr($line, 0, $dash);
            if ($key !== '') {
                $edges[$key] = true;
            }
        }
        fclose($fp);
        if ($delete_maps) {
            @unlink($f);
        } else {
            $processed[$base] = true;
        }
        $consumed++;
    }
}

/* Persist the cumulative set atomically. */
$tmp = $cumfile . '.tmp';
$out = @fopen($tmp, 'w');
if ($out) {
    foreach (array_keys($edges) as $k) {
        fwrite($out, $k . "\n");
    }
    fclose($out);
    @rename($tmp, $cumfile);
}

if (!$delete_maps) {
    $tmp = $processed_file . '.tmp';
    $out = @fopen($tmp, 'w');
    if ($out) {
        foreach (array_keys($processed) as $k) {
            fwrite($out, $k . "\n");
        }
        fclose($out);
        @rename($tmp, $processed_file);
    }
}

$hit = count($edges);
$pct = $edge_count > 0 ? (100.0 * $hit / $edge_count) : 0.0;

printf(
    "native_coverage_compact: consumed=%d remaining=%d %d / %d edges covered (%.4f%%)\n",
    $consumed, $remaining, $hit, $edge_count, $pct
);
